//! calyx-session daemon: a per-user background process that owns PTY
//! sessions and lets any number of `calyx-session attach` clients
//! (re)connect to them over a Unix socket.
//!
//! Contract summary (the integration tests in `tests/` are the source
//! of truth):
//!
//! - **Bind**: `runtime_dir/sessiond.sock`, dir mode `0700`, socket mode
//!   `0600`. Every accepted connection is checked with
//!   [`peer::verify_peer_uid`] before any protocol bytes are trusted.
//! - **Sessions**: each is a PTY (`openpty` + `fork` + `setsid` +
//!   `TIOCSCTTY` + `execvp`), with `CALYX_SESSION_ID=<id>` injected into
//!   the child's environment. All PTY output is fed into a `vt::Terminal`
//!   (P1) so a newly attaching client can be caught up.
//! - **Attach**: sends one `Replay` frame (from `Terminal::render_replay`)
//!   immediately after `AttachOk`, then mirrors all further PTY output as
//!   `Output` frames. `Input` frames from any attached client go to the
//!   PTY; multiple clients may be attached to one session at once (all
//!   receive `Output`, all their `Input` is merged).
//! - **Resize**: `Resize` sets both the PTY's `TIOCSWINSZ` and the
//!   `vt::Terminal`'s size; last write from any attached client wins.
//! - **Backpressure**: a client whose outbound queue exceeds 1 MiB is
//!   disconnected (that client only; the session and other clients are
//!   unaffected).
//! - **Exit**: when a session's child process exits, every attached
//!   client receives `ControlMsg::Event(SessionEvent::Exited { .. })`
//!   and the session is removed from the registry.
//! - **Ledger**: `state_dir/sessions.json`, mode `0600`, written
//!   atomically (temp file + rename), updated on every registry change.
//! - **Idempotent create**: `Attach { id, create: Some(spec), .. }`
//!   against an `id` that already exists attaches to the existing
//!   session rather than spawning a second process for the same id.
//! - **History (opt-in)**: off by default. With
//!   `DaemonConfig::history_enabled` (CLI: `daemon --persist-history`),
//!   or after `ControlMsg::SetHistoryEnabled { enabled: true }`, every
//!   session *created while the flag is on* appends its raw PTY output
//!   to `state_dir/history/<id>.raw` (dir mode `0700`, file mode
//!   `0600`, two-generation rotation), deletes those files again on its
//!   own teardown, and seeds a recreated session's terminal from
//!   whatever a daemon crash left behind. The flag is read once per
//!   session at creation, so mid-lifetime toggles never affect
//!   already-running sessions. Full contract: `src/history.rs`.

mod config;
mod conn;
mod error;
mod fdpass;
mod handoff;
mod history;
mod ledger;
mod outq;
pub mod peer;
mod session;
mod state;

use std::fs;
use std::os::fd::AsFd;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub use config::DaemonConfig;
pub use error::DaemonError;

/// File names inside `DaemonConfig::runtime_dir`, shared with the CLI.
pub const SOCKET_FILE: &str = "sessiond.sock";
pub const LOCK_FILE: &str = "sessiond.lock";
/// The dedicated Live Handoff endpoint (EXPERIMENTAL; see `handoff`'s
/// module doc), bound on demand by `ControlMsg::PrepareHandoff` and
/// removed again when the attempt ends either way.
pub const HANDOFF_SOCKET_FILE: &str = "handoff.sock";

use outq::lock_unpoisoned;
use state::Shared;

/// Bound on the receiver side of a handoff waiting for the old
/// daemon's manifest and fds after connecting.
const HANDOFF_RECEIVE_TIMEOUT: Duration = Duration::from_secs(10);

/// Bound on the receiver retrying the single-daemon flock takeover
/// after acking (the old daemon releases it by exiting).
const LOCK_TAKEOVER_WAIT: Duration = Duration::from_secs(5);

/// How long the daemon lingers with zero sessions and zero clients
/// before `run_until_idle` returns. Also covers the window right after
/// startup, so short gaps between sequential CLI invocations never
/// bounce the daemon.
const IDLE_LINGER: Duration = Duration::from_secs(30);

/// A bound-but-not-yet-run daemon. See the module-level doc for the
/// full contract; see [`Daemon::run_until_idle`] for the entry point
/// that actually serves connections.
pub struct Daemon {
    listener: UnixListener,
    config: DaemonConfig,
}

impl Daemon {
    /// Binds the session socket. Creates `config.runtime_dir` (mode
    /// `0700`) and `config.state_dir` (mode `0700`) if they don't
    /// already exist, removes a stale socket file left over from a
    /// crashed previous instance, binds a `UnixListener` at
    /// `config.runtime_dir/sessiond.sock`, and chmods the socket file to
    /// `0600`.
    pub fn bind(config: DaemonConfig) -> Result<Daemon, DaemonError> {
        create_private_dir(&config.runtime_dir)?;
        create_private_dir(&config.state_dir)?;

        let socket = config.runtime_dir.join(SOCKET_FILE);
        match fs::remove_file(&socket) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(DaemonError::Io(e)),
        }
        let listener = UnixListener::bind(&socket)?;
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
        Ok(Daemon { listener, config })
    }

    /// The path this daemon is (or, pre-`bind`, would be) listening on:
    /// `config.runtime_dir/sessiond.sock`.
    pub fn socket_path(&self) -> PathBuf {
        self.config.runtime_dir.join(SOCKET_FILE)
    }

    /// Serves connections until there are zero sessions and zero
    /// connected clients, then returns. This is the daemon's whole
    /// reason to exist as a background process rather than a one-shot
    /// command: it must dispatch `ControlMsg` requests (see `proto`),
    /// spawn/attach/resize/kill PTY sessions, fan output out to all of a
    /// session's attached clients, persist the ledger on every registry
    /// change, and verify each accepted connection's peer uid via
    /// [`peer::verify_peer_uid`] before trusting anything it sends.
    pub fn run_until_idle(self) -> Result<(), DaemonError> {
        let shared = Arc::new(Shared::new(
            self.config.state_dir.clone(),
            self.config.history_enabled,
        ));
        shared.lock_state().ledger = ledger::load(&self.config.state_dir);
        install_handoff_env(&shared, &self.config.runtime_dir, &self.listener)?;

        let socket = self.socket_path();
        serve(shared, self.listener, socket)
    }
}

/// EXPERIMENTAL Live Handoff, receiver side (see `handoff`'s module
/// doc for the whole contract): connects to a preparing daemon's
/// handoff endpoint (`ControlMsg::PrepareHandoff`'s reply carries its
/// path), receives the manifest and fds, adopts every offered session,
/// takes over the transferred control listener, acks, and serves until
/// idle exactly like `Daemon::run_until_idle`.
///
/// Any error before the ack leaves the old daemon fully in charge (it
/// resumes on ack timeout); this process just exits and its
/// half-adopted session threads die with it, their PTY fds being
/// duplicates the old daemon still holds.
pub fn run_handoff_receiver(
    config: DaemonConfig,
    handoff_socket: &Path,
) -> Result<(), DaemonError> {
    create_private_dir(&config.runtime_dir)?;
    create_private_dir(&config.state_dir)?;

    let stream = UnixStream::connect(handoff_socket)?;
    // Mutual credential gate: the offering side uid-checks this
    // connection; this side refuses to adopt from a different uid too.
    peer::verify_peer_uid(&stream)?;
    stream.set_read_timeout(Some(HANDOFF_RECEIVE_TIMEOUT))?;

    let (sidecar, mut fds) = fdpass::recv_fds(&stream, handoff::MAX_HANDOFF_FDS)?;
    let manifest = handoff::decode_manifest(&sidecar)?;
    if fds.len() != manifest.sessions.len() + 1 {
        return Err(DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "handoff offered {} sessions but {} fds (expected one per session plus the \
                 control listener)",
                manifest.sessions.len(),
                fds.len()
            ),
        )));
    }
    let listener_fd = fds.pop().expect("length checked above");
    let listener = UnixListener::from(listener_fd);

    let shared = Arc::new(Shared::new(
        config.state_dir.clone(),
        config.history_enabled,
    ));
    shared.lock_state().ledger = ledger::load(&config.state_dir);

    for (entry, master_fd) in manifest.sessions.into_iter().zip(fds) {
        let id = entry.id.clone();
        let entry = handoff::adopt_session(&shared, entry, master_fd).map_err(|msg| {
            DaemonError::Io(std::io::Error::other(format!(
                "adopting session {id:?} failed: {msg}"
            )))
        })?;
        // Register the way conn.rs's create_session does; the start
        // gate is already released by adopt_session, and no client can
        // race this loop (accepting starts below).
        let mut state = shared.lock_state();
        state.ledger.insert(entry.id.clone(), entry.info());
        state.sessions.insert(entry.id.clone(), entry);
        state.touch();
    }
    {
        let state = shared.lock_state();
        shared.persist_ledger(&state);
    }
    // Arm PrepareHandoff on this generation too, so the next upgrade
    // can hand off again.
    install_handoff_env(&shared, &config.runtime_dir, &listener)?;

    // The ack is the old daemon's point of no return: it exits without
    // teardown on receipt. Everything destructive stays after this
    // write on this side too (nothing above touched shared on-disk
    // state beyond the ledger snapshot, which the old daemon would
    // rewrite identically on resume).
    {
        use std::io::Write;
        let mut writer: &UnixStream = &stream;
        writer.write_all(&[handoff::HANDOFF_ACK])?;
    }
    drop(stream);

    // The old daemon held the single-daemon flock until its exit;
    // claim it now so concurrent plain `daemon` starts keep collapsing
    // into this process.
    acquire_daemon_lock(&config.runtime_dir);

    let socket = config.runtime_dir.join(SOCKET_FILE);
    serve(shared, listener, socket)
}

/// Arms `ControlMsg::PrepareHandoff` (Live Handoff, EXPERIMENTAL) with
/// what only a serving entry point knows: the runtime dir the handoff
/// endpoint belongs in, and a dup of the control listener to pass on.
fn install_handoff_env(
    shared: &Arc<Shared>,
    runtime_dir: &Path,
    listener: &UnixListener,
) -> Result<(), DaemonError> {
    let dup = listener.as_fd().try_clone_to_owned()?;
    *lock_unpoisoned(&shared.handoff_env) = Some(state::HandoffEnv {
        runtime_dir: runtime_dir.to_path_buf(),
        listener: dup,
    });
    Ok(())
}

/// Takes the single-daemon flock after a handoff, retrying briefly
/// because the old daemon only releases it by exiting (which the ack
/// just triggered). Past the handoff's point of no return the adopted
/// sessions outweigh the lock: on persistent failure this logs and
/// serves anyway rather than abandoning them.
fn acquire_daemon_lock(runtime_dir: &Path) {
    let path = runtime_dir.join(LOCK_FILE);
    let deadline = std::time::Instant::now() + LOCK_TAKEOVER_WAIT;
    loop {
        let file = match fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
        {
            Ok(file) => file,
            Err(e) => {
                eprintln!(
                    "calyx-sessiond: opening {} failed, serving without the single-daemon \
                     lock: {e}",
                    path.display()
                );
                return;
            }
        };
        match nix::fcntl::Flock::lock(file, nix::fcntl::FlockArg::LockExclusiveNonblock) {
            Ok(lock) => {
                // Held for this process's whole life, same as the
                // daemonized CLI path.
                std::mem::forget(lock);
                return;
            }
            Err(_) if std::time::Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(20));
            }
            Err((_, e)) => {
                eprintln!(
                    "calyx-sessiond: single-daemon lock not acquired after handoff ({e}); \
                     serving without it"
                );
                return;
            }
        }
    }
}

/// The serving half shared by `Daemon::run_until_idle` and
/// `run_handoff_receiver`: accept loop plus the idle-linger watcher,
/// then persister flush and socket-file cleanup.
fn serve(shared: Arc<Shared>, listener: UnixListener, socket: PathBuf) -> Result<(), DaemonError> {
    {
        let shared = Arc::clone(&shared);
        thread::spawn(move || accept_loop(listener, shared));
    }

    let mut state = shared.lock_state();
    loop {
        let idle = state.sessions.is_empty() && state.total_clients == 0;
        let idle_for = state.last_activity.elapsed();
        if idle && idle_for >= IDLE_LINGER {
            break;
        }
        // Busy: sleep until the condvar signals a state change.
        // Idle: additionally cap the wait at the remaining linger.
        if idle {
            let (guard, _) = shared
                .cond
                .wait_timeout(state, IDLE_LINGER - idle_for)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state = guard;
        } else {
            state = shared
                .cond
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }
    drop(state);

    // Flush any throttled trailing ledger write before returning.
    shared.shutdown_persister();

    // Best-effort: the accept thread still holds the listener, but
    // the caller (CLI daemon process) exits right after this
    // returns, closing it.
    let _ = fs::remove_file(&socket);
    Ok(())
}

fn accept_loop(listener: UnixListener, shared: Arc<Shared>) {
    let mut next_conn_id: u64 = 1;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(_) => continue,
        };
        // Credential gate before a single protocol byte is trusted.
        if peer::verify_peer_uid(&stream).is_err() {
            continue;
        }
        {
            let mut state = shared.lock_state();
            state.total_clients += 1;
            state.touch();
        }
        let conn_id = next_conn_id;
        next_conn_id += 1;
        let shared = Arc::clone(&shared);
        thread::spawn(move || conn::handle_conn(shared, stream, conn_id));
    }
}

/// mkdir -p with mode 0700 for path components this call creates
/// (pre-existing directories keep their permissions).
fn create_private_dir(dir: &Path) -> Result<(), DaemonError> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(dir)?;
    Ok(())
}
