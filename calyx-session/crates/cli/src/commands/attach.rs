//! `calyx-session attach`: bridges this process's tty to a session.
//!
//! Exit code contract: `0` on a clean session exit (the daemon's
//! `Event(Exited)`), `2` on disconnect/daemon loss.

use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nix::sys::termios::{self, SetArg, Termios};
use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec,
};

use crate::cli::AttachArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{resolve_runtime_dir, resolve_state_dir, socket_path, CommandError};

/// Exit code for "the connection or the daemon went away".
const EXIT_DISCONNECTED: u8 = 2;
/// Bound on auto-start + reconnect attempts.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: AttachArgs,
) -> Result<u8, CommandError> {
    let socket = socket_path(runtime_dir);
    let client = match connect_or_spawn(&socket, runtime_dir, state_dir) {
        Ok(client) => client,
        Err(_) => return Ok(EXIT_DISCONNECTED),
    };

    let (cols, rows) = tty_size().unwrap_or((80, 24));
    let create = args.create.then(|| SessionSpec {
        id: args.id.clone(),
        name: args.name.clone(),
        cwd: args.cwd.clone(),
        argv: (!args.argv.is_empty()).then(|| args.argv.clone()),
        env: vec![],
        cols,
        rows,
    });

    match client.request(&ControlMsg::Attach {
        id: args.id.clone(),
        create,
        cols,
        rows,
    })? {
        ControlMsg::AttachOk { .. } => {}
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    }

    bridge(client.stream)
}

/// Runs the attached bridge until the session exits (0) or the
/// connection is lost (2). The tty raw-mode guard restores the
/// original termios on every path out, including panics (Drop).
fn bridge(stream: UnixStream) -> Result<u8, CommandError> {
    // From here on the stream carries bulk traffic with no
    // request/reply rhythm; reads block until the session ends.
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(None)?;

    let _raw_guard = RawModeGuard::engage();
    let writer = Arc::new(Mutex::new(FrameWriter::new(stream.try_clone()?)));

    // stdin -> Input frames. On stdin EOF the thread just stops: the
    // session keeps running and output keeps flowing.
    {
        let writer = Arc::clone(&writer);
        thread::spawn(move || {
            let mut stdin = std::io::stdin();
            let mut buf = [0u8; 4096];
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let mut w = writer.lock().unwrap_or_else(|p| p.into_inner());
                        if w.write_frame(FrameType::Input, &buf[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }

    // SIGWINCH -> Resize frames; SIGTERM/SIGHUP -> restore the tty and
    // exit 2. Both arrive via the async-signal-safe self-pipe so the
    // handlers themselves stay minimal.
    if let Ok(signal_rx) = install_signal_pipe() {
        let writer = Arc::clone(&writer);
        thread::spawn(move || {
            let mut byte = [0u8; 1];
            loop {
                match nix::unistd::read(&signal_rx, &mut byte) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if byte[0] == b'q' => {
                        // Drop cannot run on a signal-triggered exit;
                        // restore the termios explicitly first.
                        if let Some(saved) = SAVED_TERMIOS
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .take()
                        {
                            let _ = termios::tcsetattr(std::io::stdin(), SetArg::TCSANOW, &saved);
                        }
                        std::process::exit(i32::from(EXIT_DISCONNECTED));
                    }
                    Ok(_) => {
                        if let Some((cols, rows)) = tty_size() {
                            let Ok(payload) = encode_control(&ControlMsg::Resize { cols, rows })
                            else {
                                break;
                            };
                            let mut w = writer.lock().unwrap_or_else(|p| p.into_inner());
                            if w.write_frame(FrameType::Control, &payload).is_err() {
                                break;
                            }
                        }
                    }
                }
            }
        });
    }

    // Main loop: session output (Replay and Output frames) -> stdout;
    // Event(Exited) is the clean-exit signal.
    let mut reader = FrameReader::new(stream);
    let mut stdout = std::io::stdout();
    loop {
        let frame = match reader.read_frame() {
            Ok(frame) => frame,
            // EOF/reset: daemon or connection is gone.
            Err(_) => return Ok(EXIT_DISCONNECTED),
        };
        match frame.frame_type {
            FrameType::Replay | FrameType::Output => {
                if stdout.write_all(&frame.payload).is_err() || stdout.flush().is_err() {
                    return Ok(EXIT_DISCONNECTED);
                }
            }
            FrameType::Control => {
                if let Ok(ControlMsg::Event(proto::SessionEvent::Exited { .. })) =
                    decode_control(&frame.payload)
                {
                    return Ok(0);
                }
            }
            FrameType::Input => {}
        }
    }
}

/// Connects to the daemon, auto-starting it if the socket is dead:
/// take the spawn lock (so concurrent attaches spawn one daemon, not
/// N), start `calyx-session daemon`, and retry with backoff.
fn connect_or_spawn(
    socket: &Path,
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
) -> Result<DaemonClient, CommandError> {
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let mut spawned = false;
    loop {
        match DaemonClient::connect(socket) {
            Ok(client) => return Ok(client),
            Err(e) => {
                if Instant::now() >= deadline {
                    return Err(e);
                }
            }
        }
        if !spawned {
            spawned = true;
            spawn_daemon(runtime_dir, state_dir)?;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn spawn_daemon(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
) -> Result<(), CommandError> {
    let runtime = resolve_runtime_dir(runtime_dir);
    let state = resolve_state_dir(state_dir);
    std::fs::create_dir_all(&runtime)?;

    // The daemon itself holds an exclusive flock on this file for its
    // whole life; failing to take it here means a daemon is already
    // running (or being started by someone else), so just retry the
    // connect loop. The probe lock is released *before* spawning:
    // holding it across the spawn would make the daemonized grandchild
    // lose its own lock attempt and exit as a duplicate.
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(runtime.join(::daemon::LOCK_FILE))?;
    match nix::fcntl::Flock::lock(lock_file, nix::fcntl::FlockArg::LockExclusiveNonblock) {
        Ok(lock) => drop(lock),
        Err(_) => return Ok(()),
    }

    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .arg("--runtime-dir")
        .arg(&runtime)
        .arg("--state-dir")
        .arg(&state)
        .arg("daemon")
        .spawn()?;
    // The `daemon` subcommand double-forks; the direct child exits
    // immediately and must be reaped.
    let _ = child.wait();
    Ok(())
}

/// Restores the terminal's original termios on drop. Engages raw mode
/// only when stdin actually is a tty (under a test harness it isn't,
/// and there is nothing to restore or make raw).
struct RawModeGuard {
    saved: Option<Termios>,
}

impl RawModeGuard {
    fn engage() -> RawModeGuard {
        let stdin = std::io::stdin();
        let Ok(saved) = termios::tcgetattr(&stdin) else {
            return RawModeGuard { saved: None };
        };
        let mut raw = saved.clone();
        termios::cfmakeraw(&mut raw);
        if termios::tcsetattr(&stdin, SetArg::TCSANOW, &raw).is_err() {
            return RawModeGuard { saved: None };
        }
        // Mirror for the signal path (SIGTERM/SIGHUP), which can't
        // reach this guard on the bridge's stack.
        *SAVED_TERMIOS.lock().unwrap_or_else(|p| p.into_inner()) = Some(saved.clone());
        RawModeGuard { saved: Some(saved) }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if let Some(saved) = &self.saved {
            let _ = termios::tcsetattr(std::io::stdin(), SetArg::TCSANOW, saved);
        }
        *SAVED_TERMIOS.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }
}

/// This process's tty size, if stdout (or stdin) is a tty.
pub(crate) fn tty_size() -> Option<(u16, u16)> {
    for fd in [libc::STDOUT_FILENO, libc::STDIN_FILENO] {
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: TIOCGWINSZ only writes the winsize out-param.
        let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ as libc::c_ulong, &mut ws) };
        if rc == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return Some((ws.ws_col, ws.ws_row));
        }
    }
    None
}

/// Write end of the signal self-pipe, read by the signal handlers.
static SIGNAL_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

/// The termios to restore on abnormal termination, mirrored here from
/// `RawModeGuard` so the signal path can restore it without access to
/// the guard on the bridge's stack.
static SAVED_TERMIOS: Mutex<Option<Termios>> = Mutex::new(None);

extern "C" fn on_winch(_signal: libc::c_int) {
    signal_pipe_notify(b'w');
}

extern "C" fn on_terminate(_signal: libc::c_int) {
    signal_pipe_notify(b'q');
}

fn signal_pipe_notify(byte: u8) {
    let fd = SIGNAL_PIPE_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; the fd stays open for
        // the process lifetime once installed.
        unsafe { libc::write(fd, [byte].as_ptr() as *const libc::c_void, 1) };
    }
}

/// Installs the SIGWINCH/SIGTERM/SIGHUP handlers and returns the read
/// end of their shared self-pipe.
fn install_signal_pipe() -> nix::Result<std::os::fd::OwnedFd> {
    let (rx, tx) = nix::unistd::pipe()?;
    nix::fcntl::fcntl(
        &tx,
        nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
    )?;
    SIGNAL_PIPE_WRITE.store(tx.as_raw_fd(), Ordering::Relaxed);
    // The write end must outlive the handlers; it is intentionally
    // leaked (one per process).
    std::mem::forget(tx);
    // SAFETY: installing handlers that only call async-signal-safe
    // write(2) on a pre-opened fd.
    unsafe {
        libc::signal(
            libc::SIGWINCH,
            on_winch as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            on_terminate as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGHUP,
            on_terminate as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
    }
    Ok(rx)
}
