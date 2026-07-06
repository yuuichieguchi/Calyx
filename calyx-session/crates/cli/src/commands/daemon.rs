use std::path::{Path, PathBuf};

use daemon::{Daemon, DaemonConfig, LOCK_FILE};
use nix::fcntl::{Flock, FlockArg};

use crate::cli::DaemonArgs;
use crate::commands::{resolve_runtime_dir, resolve_state_dir, CommandError};

/// Runs (or backgrounds) the session daemon. `--foreground` runs
/// `Daemon::bind(..).run_until_idle()` directly on this process; the
/// default path double-forks into a detached background daemon that
/// holds an exclusive flock so concurrent starts collapse to one.
///
/// With `--handoff-connect` (EXPERIMENTAL, spawned by `upgrade`) the
/// same foreground/background split applies, but the daemon runs
/// `daemon::run_handoff_receiver` instead of binding its own socket:
/// it inherits the running daemon's listener and sessions. That path
/// takes the single-daemon flock only after its ack (the old daemon
/// holds it until then; see `run_handoff_receiver`).
pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: DaemonArgs,
) -> Result<u8, CommandError> {
    let config = DaemonConfig {
        runtime_dir: resolve_runtime_dir(runtime_dir),
        state_dir: resolve_state_dir(state_dir),
        history_enabled: args.persist_history,
    };

    if let Some(handoff_socket) = args.handoff_connect {
        if args.foreground {
            daemon::run_handoff_receiver(config, &handoff_socket)?;
            return Ok(0);
        }
        if !daemonize()? {
            return Ok(0);
        }
        return run_daemonized_receiver(config, &handoff_socket);
    }

    if args.foreground {
        Daemon::bind(config)?.run_until_idle()?;
        return Ok(0);
    }

    if !daemonize()? {
        return Ok(0);
    }
    run_daemonized(config)
}

/// Double-forks into a detached grandchild (new session in between, so
/// the daemon can never reacquire a controlling terminal). Returns
/// `Ok(false)` in the original process (the daemon runs on detached;
/// the caller just reports success) and `Ok(true)` in the grandchild.
fn daemonize() -> Result<bool, CommandError> {
    // SAFETY: this process is still single-threaded here (nothing has
    // spawned threads before subcommand dispatch), which is the
    // precondition for fork() continuing into arbitrary Rust code in
    // the child.
    let first = unsafe { libc::fork() };
    if first < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if first > 0 {
        // Original process: reap the intermediate child.
        let mut status: libc::c_int = 0;
        // SAFETY: waiting for the pid fork() just returned.
        unsafe { libc::waitpid(first, &mut status, 0) };
        return Ok(false);
    }

    // Intermediate child: new session, fork again, exit.
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
    Ok(true)
}

/// stdio -> log file / dev-null: a detached daemon has no terminal.
fn detach_stdio(config: &DaemonConfig) {
    std::fs::create_dir_all(&config.state_dir).ok();
    std::fs::create_dir_all(&config.runtime_dir).ok();

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
}

/// Live Handoff receiver, daemonized. Never returns control to a
/// caller that could double-run main-exit logic: ends in `_exit`
/// (mirrors `run_daemonized`).
fn run_daemonized_receiver(
    config: DaemonConfig,
    handoff_socket: &Path,
) -> Result<u8, CommandError> {
    detach_stdio(&config);
    let code = match daemon::run_handoff_receiver(config, handoff_socket) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("calyx-session daemon (handoff receiver): {e}");
            1
        }
    };
    // SAFETY: ends the daemonized process without unwinding into the
    // CLI's main.
    unsafe { libc::_exit(code) };
}

/// Never returns control to a caller that could double-run main-exit
/// logic: ends in `_exit`.
fn run_daemonized(config: DaemonConfig) -> Result<u8, CommandError> {
    detach_stdio(&config);

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
