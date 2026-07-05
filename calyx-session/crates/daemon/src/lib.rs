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

mod config;
mod conn;
mod error;
mod ledger;
mod outq;
pub mod peer;
mod session;
mod state;

use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub use config::DaemonConfig;
pub use error::DaemonError;

/// File names inside `DaemonConfig::runtime_dir`, shared with the CLI.
pub const SOCKET_FILE: &str = "sessiond.sock";
pub const LOCK_FILE: &str = "sessiond.lock";

use state::Shared;

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
        let shared = Arc::new(Shared::new(self.config.state_dir.clone()));
        shared.lock_state().ledger = ledger::load(&self.config.state_dir);

        let socket = self.socket_path();
        {
            let shared = Arc::clone(&shared);
            let listener = self.listener;
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
