use std::path::PathBuf;

use daemon::{Daemon, DaemonConfig, LOCK_FILE};
use nix::fcntl::{Flock, FlockArg};

use crate::cli::DaemonArgs;
use crate::commands::{resolve_runtime_dir, resolve_state_dir, CommandError};

/// Runs (or backgrounds) the session daemon. `--foreground` runs
/// `Daemon::bind(..).run_until_idle()` directly on this process; the
/// default path double-forks into a detached background daemon that
/// holds an exclusive flock so concurrent starts collapse to one.
pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: DaemonArgs,
) -> Result<u8, CommandError> {
    let config = DaemonConfig {
        runtime_dir: resolve_runtime_dir(runtime_dir),
        state_dir: resolve_state_dir(state_dir),
    };

    if args.foreground {
        Daemon::bind(config)?.run_until_idle()?;
        return Ok(0);
    }

    // SAFETY: this process is still single-threaded here (nothing has
    // spawned threads before subcommand dispatch), which is the
    // precondition for fork() continuing into arbitrary Rust code in
    // the child.
    let first = unsafe { libc::fork() };
    if first < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if first > 0 {
        // Original process: reap the intermediate child and report
        // success; the daemon (grandchild) runs on detached.
        let mut status: libc::c_int = 0;
        // SAFETY: waiting for the pid fork() just returned.
        unsafe { libc::waitpid(first, &mut status, 0) };
        return Ok(0);
    }

    // Intermediate child: new session, fork again so the daemon can
    // never reacquire a controlling terminal, then exit.
    // SAFETY (this whole block): standard daemonization syscalls on a
    // freshly forked, single-threaded child.
    unsafe {
        if libc::setsid() < 0 {
            libc::_exit(1);
        }
        let second = libc::fork();
        if second < 0 {
            libc::_exit(1);
        }
        if second > 0 {
            libc::_exit(0);
        }
    }

    // Grandchild: the actual daemon. Detach stdio, then serve.
    run_daemonized(config)
}

/// Never returns control to a caller that could double-run main-exit
/// logic: ends in `_exit`.
fn run_daemonized(config: DaemonConfig) -> Result<u8, CommandError> {
    std::fs::create_dir_all(&config.state_dir).ok();
    std::fs::create_dir_all(&config.runtime_dir).ok();

    // stdio -> log file / dev-null: a detached daemon has no terminal.
    if let Ok(log) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(config.state_dir.join("daemon.log"))
    {
        let _ = nix::unistd::dup2_stdout(&log);
        let _ = nix::unistd::dup2_stderr(&log);
    }
    if let Ok(devnull) = std::fs::File::open("/dev/null") {
        let _ = nix::unistd::dup2_stdin(&devnull);
    }

    // Single-daemon lock, held for the daemon's whole life (the guard
    // is deliberately leaked below so it is never unlocked).
    let lock_file = match std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(config.runtime_dir.join(LOCK_FILE))
    {
        Ok(lock_file) => lock_file,
        // SAFETY: _exit in a detached daemon that failed to set up.
        Err(_) => unsafe { libc::_exit(1) },
    };
    let lock = match Flock::lock(lock_file, FlockArg::LockExclusiveNonblock) {
        Ok(lock) => lock,
        // Another daemon already serves this runtime dir.
        // SAFETY: plain _exit.
        Err(_) => unsafe { libc::_exit(0) },
    };
    std::mem::forget(lock);

    let code = match Daemon::bind(config).map(Daemon::run_until_idle) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
            eprintln!("calyx-session daemon: {e}");
            1
        }
    };
    // SAFETY: ends the daemonized process without unwinding into the
    // CLI's main.
    unsafe { libc::_exit(code) };
}
