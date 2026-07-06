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
use std::os::fd::{AsFd, OwnedFd};
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
    /// A dup of the single-daemon flock fd the CLI already holds
    /// (`commands::daemon::run_daemonized`), wired in via
    /// [`Daemon::with_lock`] so a later Live Handoff can transfer the
    /// exact same open file description to the next daemon generation
    /// (P6 review E5). `None` for library/embedding callers of
    /// [`Daemon::bind`] that never took the lock, in which case a
    /// handoff simply carries no lock fd.
    lock: Option<OwnedFd>,
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
        Ok(Daemon {
            listener,
            config,
            lock: None,
        })
    }

    /// Wires the already-held single-daemon flock fd into this daemon so
    /// a later Live Handoff can transfer the same open file description
    /// to the next generation (P6 review E5). The CLI
    /// (`commands::daemon::run_daemonized`) opens and flocks the lock
    /// file itself before binding, leaks that guard for the process's
    /// life, and hands a dup down here; the daemon never re-opens or
    /// re-locks (flock is exclusive per open file description, so a
    /// second lock on a fresh fd would deadlock against the CLI's own
    /// hold).
    pub fn with_lock(mut self, lock: OwnedFd) -> Daemon {
        self.lock = Some(lock);
        self
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
        install_handoff_env(
            &shared,
            &self.config.runtime_dir,
            &self.listener,
            self.lock.as_ref(),
        )?;

        let socket = self.socket_path();
        start_accepting(&shared, self.listener);
        block_until_idle(shared, socket)
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
    // P6 review E5: the wire contract carries the single-daemon lock fd
    // too (order pinned by `offer_handoff`: sessions, then the control
    // listener, then the lock fd last), so a real handoff is one fd per
    // session plus two. This receiver adopts that lock fd as its own
    // hold below rather than re-acquiring the lock separately; see R3's
    // test in this module's `#[cfg(test)]` block.
    if fds.len() != manifest.sessions.len() + 2 {
        return Err(DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "handoff offered {} sessions but {} fds (expected one per session plus the \
                 control listener plus the single-daemon lock fd)",
                manifest.sessions.len(),
                fds.len()
            ),
        )));
    }
    // Adopt the transferred single-daemon lock fd as this process's own
    // hold: it shares the old daemon's open file description, so simply
    // keeping it open means this generation already holds the exclusive
    // flock, with no re-acquire race against a lock the old daemon
    // cannot release until after it has been acked (P6 review E5). It is
    // duped into the handoff env below (so the next generation can
    // transfer it again) and then leaked so the hold lasts this
    // process's whole life, the same discipline the daemonized CLI path
    // uses (`commands::daemon::run_daemonized`).
    let lock_fd = fds.pop().expect("length checked above");
    let listener_fd = fds.pop().expect("length checked above");
    let listener = UnixListener::from(listener_fd);

    let shared = Arc::new(Shared::new(
        config.state_dir.clone(),
        config.history_enabled,
    ));
    shared.lock_state().ledger = ledger::load(&config.state_dir);

    // Adopt the whole manifest into a local staging vec before touching
    // the live registry or the ledger (P6 review H8): a failure partway
    // through must never leave a half-populated `sessions` map or a
    // ledger persisted under a daemon generation that then dies. On
    // error the staged entries drop here and this process `_exit`s (see
    // `cli::commands::daemon`), promptly and well within the old
    // daemon's HANDOFF_ACK_TIMEOUT before it resumes.
    //
    // Known bounded residual: `adopt_session` starts each session thread
    // reading its inherited PTY (and, for a history-enabled session,
    // appending to its `<id>.raw`) immediately, on its pre-release
    // contract that the adopt/H7 unit tests rely on. So every session
    // adopted *before* a later failure has already begun draining its
    // (duplicated) PTY master, consuming bytes from the shared PTY that
    // the old daemon's own paused copy will never see once it resumes,
    // and possibly interleaving appends into the same history file. The
    // exposure is therefore not a fixed few bytes of a single session:
    // it scales with how many sessions were adopted before the one that
    // failed, since each of them starts reading straight away. It still
    // never splits the registry or the on-disk ledger, because staging
    // defers both until the whole manifest succeeds. Fully preventing
    // the lost/interleaved reads would require deferring PTY consumption
    // past the ack, which the pre-release contract does not currently
    // allow.
    let mut adopted: Vec<state::SessionEntry> = Vec::with_capacity(manifest.sessions.len());
    for (entry, master_fd) in manifest.sessions.into_iter().zip(fds) {
        let id = entry.id.clone();
        let entry = handoff::adopt_session(&shared, entry, master_fd).map_err(|msg| {
            DaemonError::Io(std::io::Error::other(format!(
                "adopting session {id:?} failed: {msg}"
            )))
        })?;
        adopted.push(entry);
    }
    // Whole manifest adopted: register every session together and
    // persist once. The start gate is already released by adopt_session,
    // and no client can race this (accepting starts below).
    {
        let mut state = shared.lock_state();
        for entry in adopted {
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }
        state.touch();
        shared.persist_ledger(&state);
    }
    // Arm PrepareHandoff on this generation too, so the next upgrade
    // can hand off again, and carry the adopted lock fd forward so that
    // handoff can transfer the same open file description onward.
    install_handoff_env(&shared, &config.runtime_dir, &listener, Some(&lock_fd))?;

    // Start serving the transferred socket, then ack (P6 review H5 /
    // E#4). The ack is the old daemon's unconditional point of no
    // return: it `_exit`s on receipt. Accepting first means that by the
    // time the old daemon exits, this process is already accepting on
    // the transferred listener (no window with nobody serving it), so
    // the ack is genuinely the last thing that can go wrong before it is
    // committed. This generation already holds the single-daemon lock
    // via the transferred fd (adopted above), so there is no separate
    // lock takeover to sequence here (P6 review E5). If this process
    // instead dies or errors before the ack, the old daemon never
    // exits: it resumes on its ack timeout and keeps every session.
    //
    // Nothing above this ack touched shared on-disk state beyond the
    // ledger snapshot, which the old daemon would rewrite identically on
    // resume, so an error path here leaves the old daemon's world intact.
    start_accepting(&shared, listener);

    // The transferred lock fd is this process's single-daemon hold (same
    // open file description as the old daemon's): leak it so the hold
    // lasts this process's whole life, exactly as the daemonized CLI
    // path does. No re-acquire is needed or attempted -- the old daemon
    // cannot release its flock until the ack below makes it exit, so a
    // re-acquire loop could only ever wait out its own bound and serve
    // lock-less (P6 review E5).
    std::mem::forget(lock_fd);

    {
        use std::io::Write;
        let mut writer: &UnixStream = &stream;
        writer.write_all(&[handoff::HANDOFF_ACK])?;
    }
    drop(stream);

    let socket = config.runtime_dir.join(SOCKET_FILE);
    block_until_idle(shared, socket)
}

/// Arms `ControlMsg::PrepareHandoff` (Live Handoff, EXPERIMENTAL) with
/// what only a serving entry point knows: the runtime dir the handoff
/// endpoint belongs in, and a dup of the control listener to pass on.
fn install_handoff_env(
    shared: &Arc<Shared>,
    runtime_dir: &Path,
    listener: &UnixListener,
    lock: Option<&OwnedFd>,
) -> Result<(), DaemonError> {
    let dup = listener.as_fd().try_clone_to_owned()?;
    // A dup of the single-daemon lock fd this serving generation holds,
    // so `offer_handoff` can transfer the same open file description to
    // the next generation (P6 review E5). `None` wherever this
    // generation holds no lock fd (library callers of `Daemon::bind`
    // that never took the lock).
    let lock_dup = match lock {
        Some(fd) => Some(fd.try_clone()?),
        None => None,
    };
    *lock_unpoisoned(&shared.handoff_env) = Some(state::HandoffEnv {
        runtime_dir: runtime_dir.to_path_buf(),
        listener: dup,
        lock: lock_dup,
    });
    Ok(())
}

/// Spawns the accept loop for `listener` on a background thread. Split
/// from `block_until_idle` (they were one `serve` function) so the
/// handoff receiver can begin accepting on the transferred socket
/// *before* it acks the old daemon into exiting (P6 review H5): the old
/// daemon's post-ack exit then never leaves a window with the
/// transferred socket bound but unserved. `Daemon::run_until_idle` calls
/// this and `block_until_idle` back to back, preserving its old
/// behavior exactly.
fn start_accepting(shared: &Arc<Shared>, listener: UnixListener) {
    let shared = Arc::clone(shared);
    thread::spawn(move || accept_loop(listener, shared));
}

/// Blocks until the daemon is idle (zero sessions, zero clients) for
/// `IDLE_LINGER`, then flushes the persister and removes the socket
/// file. The accept loop spawned by `start_accepting` keeps running on
/// its own thread until this process exits.
fn block_until_idle(shared: Arc<Shared>, socket: PathBuf) -> Result<(), DaemonError> {
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

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::os::fd::{AsFd, AsRawFd};

    use handoff::{encode_manifest, HandoffManifest};

    use super::*;

    /// E4 ordering (P6 review, originally H5, superseded by E5):
    /// `run_handoff_receiver` writes `HANDOFF_ACK` -- the old daemon's
    /// unconditional point of no return (`crate::handoff`'s module doc)
    /// -- only *after* it has started accepting on the transferred
    /// control listener, so the old daemon's post-ack `_exit` never
    /// leaves that socket bound but unserved. E5 changed why the ack is
    /// safe to send: the receiver now holds the single-daemon lock via
    /// the transferred fd (the same open file description as the old
    /// daemon's) instead of racing to re-acquire it, so the ack no
    /// longer waits on any lock takeover at all, even when a previous
    /// holder is slow to release. Both halves are pinned here.
    ///
    /// Proven without spinning up two real daemon processes: this test
    /// plays the "old daemon" offering role itself (an empty manifest,
    /// no sessions to keep this test simple; the ordering is about the
    /// listener/lock tail, not adoption content) against a real
    /// `run_handoff_receiver`. It holds the single-daemon lock file
    /// exclusively for the whole test (a maximally slow-releasing
    /// previous holder) and transfers THAT SAME fd as the handoff's
    /// lock fd, exactly as a real `offer_handoff` does. Because the
    /// receiver adopts that fd rather than re-acquiring the lock, the
    /// ack arrives near-instant despite this test never releasing its
    /// hold; the superseded contract (ack gated on a separate acquire
    /// that could only succeed after a slow holder released) would
    /// instead have made the receiver spin out its old takeover bound
    /// and ack lock-less. A follow-up Hello round-trip on the
    /// transferred control socket then confirms the receiver was
    /// already serving it when it acked (the E4 ordering the original
    /// H5 guarded).
    #[test]
    fn handoff_receiver_acks_promptly_and_serves_the_transferred_listener() {
        use proto::{
            decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter,
            PROTOCOL_VERSION,
        };

        let runtime_tmp = tempfile::tempdir().expect("scratch runtime dir");
        let state_tmp = tempfile::tempdir().expect("scratch state dir");
        let runtime_dir = runtime_tmp.path().to_path_buf();
        std::fs::create_dir_all(&runtime_dir).expect("create scratch runtime dir");

        // Hold the single-daemon lock exclusively for the whole test: a
        // maximally slow-releasing previous holder. Never dropped before
        // the assertions below.
        let lock_path = runtime_dir.join(LOCK_FILE);
        let lock_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)
            .expect("open scratch lock file");
        let held_lock =
            nix::fcntl::Flock::lock(lock_file, nix::fcntl::FlockArg::LockExclusiveNonblock)
                .expect("test should be able to pre-acquire the scratch lock file");

        // A real bound listener stands in for the transferred control
        // listener: run_handoff_receiver only ever wraps whatever fd it
        // is handed, it never inspects its origin.
        let control_socket = runtime_dir.join("control-stand-in.sock");
        let control_listener = std::os::unix::net::UnixListener::bind(&control_socket)
            .expect("bind stand-in control listener");

        // The dedicated handoff endpoint run_handoff_receiver connects
        // to, played by this test as the offering ("old daemon") side.
        let handoff_socket = runtime_dir.join("handoff-stand-in.sock");
        let handoff_listener = std::os::unix::net::UnixListener::bind(&handoff_socket)
            .expect("bind stand-in handoff listener");

        let config = DaemonConfig {
            runtime_dir: runtime_dir.clone(),
            state_dir: state_tmp.path().to_path_buf(),
            history_enabled: false,
        };

        let receiver_thread = std::thread::spawn(move || {
            // The subject under test, entirely unmodified. Its eventual
            // `block_until_idle()` call blocks until idle (up to 30s with
            // no sessions/clients); this thread is intentionally left
            // detached rather than joined; the process ends at the end of
            // the whole test binary run.
            let _ = run_handoff_receiver(config, &handoff_socket);
        });

        let (offerer_stream, _) = handoff_listener
            .accept()
            .expect("accept the receiver's connection to the handoff endpoint");
        let manifest = HandoffManifest { sessions: vec![] };
        let sidecar = encode_manifest(&manifest).expect("encode an empty manifest");
        let listener_fd = control_listener
            .as_fd()
            .try_clone_to_owned()
            .expect("dup the stand-in control listener");
        // The E5 design: transfer the SAME open file description this
        // test holds the exclusive flock on (order: listener, then lock
        // last, matching run_handoff_receiver's two trailing pops).
        let lock_fd = held_lock
            .as_fd()
            .try_clone_to_owned()
            .expect("dup the held lock fd for transfer");
        fdpass::send_fds(
            &offerer_stream,
            &sidecar,
            &[listener_fd.as_raw_fd(), lock_fd.as_raw_fd()],
        )
        .expect("send the manifest, control listener fd, and lock fd to the receiver");

        // Near-instant ack despite this test still holding the lock: the
        // receiver adopted it via the transferred fd and never
        // re-acquires. The superseded contract would have spun its old
        // takeover bound (seconds) before acking here.
        const ACK_BOUND: Duration = Duration::from_secs(1);
        let start = std::time::Instant::now();
        offerer_stream
            .set_read_timeout(Some(ACK_BOUND))
            .expect("set ack read timeout");
        let mut ack_byte = [0u8; 1];
        (&offerer_stream).read_exact(&mut ack_byte).expect(
            "the receiver should ack within 1s because it holds the single-daemon lock \
             via the transferred fd (same open file description as this test's \
             still-held `held_lock`) and never re-acquires a lock the old daemon cannot \
             release until after the ack (P6 review E5)",
        );
        let ack_arrived_after = start.elapsed();
        assert!(
            ack_arrived_after < ACK_BOUND,
            "ack arrived after {ack_arrived_after:?}, at or beyond the {ACK_BOUND:?} bound"
        );
        assert_eq!(ack_byte[0], handoff::HANDOFF_ACK, "unexpected ack byte");

        // E4 ordering: the ack came after start_accepting, so the
        // transferred control listener is already being served. A fresh
        // client's Hello round-trip on it must succeed.
        let client = UnixStream::connect(&control_socket)
            .expect("connect to the transferred control socket the receiver took over");
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("set control round-trip read timeout");
        let hello = encode_control(&ControlMsg::Hello {
            version: PROTOCOL_VERSION,
        })
        .expect("encode Hello");
        let mut writer = FrameWriter::new(
            client
                .try_clone()
                .expect("clone the control stream for writing"),
        );
        writer
            .write_frame(FrameType::Control, &hello)
            .expect("write Hello to the transferred control socket");
        let mut reader = FrameReader::new(client);
        let frame = reader.read_frame().expect(
            "the receiver must answer a Hello on the transferred control listener, proving \
             it began accepting (start_accepting) before it acked -- the E4 ordering the \
             original H5 test guarded (P6 review E5 supersession)",
        );
        let reply = decode_control(&frame.payload).expect("decode the Hello reply");
        assert!(
            matches!(reply, ControlMsg::HelloOk { version } if version == PROTOCOL_VERSION),
            "expected HelloOk from the transferred control listener, got {reply:?}"
        );

        drop(held_lock);
        let _ = receiver_thread; // intentionally left running; see above.
    }

    /// R3 (P6 review E5, RED): a handoff receiver must hold the
    /// single-daemon lock via the transferred lock fd (same open file
    /// description as the old daemon's), never by separately
    /// re-acquiring it through `acquire_daemon_lock`. E5's bug: the
    /// old daemon cannot release its own flock until *after* it
    /// receives the ack (module doc's point of no return), so
    /// `acquire_daemon_lock`'s pre-ack retry loop is trying to acquire
    /// a lock that structurally cannot be freed yet -- every real
    /// handoff today burns the full `LOCK_TAKEOVER_WAIT` (5s) and then
    /// acks anyway, serving lock-less.
    ///
    /// This test plays the "old daemon" side itself (empty manifest,
    /// no sessions -- R3 is about the lock, not adoption content) and,
    /// critically, sends the SAME fd it holds an exclusive flock on as
    /// the lock fd in the handoff payload, exactly as a fixed
    /// `offer_handoff` would (the whole point of E5's fix: the lock
    /// travels through the same `SCM_RIGHTS` batch as the listener).
    /// It never releases that lock during the read below. If
    /// `run_handoff_receiver` correctly adopted the transferred fd as
    /// its own hold (sharing that open file description), it would
    /// already hold the lock the instant it received the fds and
    /// could ack near-instantly, regardless of this test's own copy
    /// staying open. Today it instead discards the transferred lock
    /// fd (see the `let _lock_fd = ...` in `run_handoff_receiver`) and
    /// calls `acquire_daemon_lock`, whose retry loop cannot succeed
    /// while this test's copy of the SAME open file description stays
    /// locked -- so the ack does not arrive within the short bound
    /// below.
    #[test]
    fn run_handoff_receiver_holds_the_lock_via_the_transferred_fd_without_reacquiring() {
        let runtime_tmp = tempfile::tempdir().expect("scratch runtime dir");
        let state_tmp = tempfile::tempdir().expect("scratch state dir");
        let runtime_dir = runtime_tmp.path().to_path_buf();
        std::fs::create_dir_all(&runtime_dir).expect("create scratch runtime dir");

        let lock_path = runtime_dir.join(LOCK_FILE);
        let lock_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)
            .expect("open scratch lock file");
        // Never dropped before this test's key assertion below: stands
        // in for the old daemon, which structurally cannot release its
        // own flock until after the ack this test is waiting for.
        let held_lock =
            nix::fcntl::Flock::lock(lock_file, nix::fcntl::FlockArg::LockExclusiveNonblock)
                .expect("test should be able to pre-acquire the scratch lock file");

        let control_listener =
            std::os::unix::net::UnixListener::bind(runtime_dir.join("control-stand-in.sock"))
                .expect("bind stand-in control listener");
        let handoff_socket = runtime_dir.join("handoff-stand-in.sock");
        let handoff_listener = std::os::unix::net::UnixListener::bind(&handoff_socket)
            .expect("bind stand-in handoff listener");

        let config = DaemonConfig {
            runtime_dir: runtime_dir.clone(),
            state_dir: state_tmp.path().to_path_buf(),
            history_enabled: false,
        };

        let receiver_thread = std::thread::spawn(move || {
            let _ = run_handoff_receiver(config, &handoff_socket);
        });

        let (offerer_stream, _) = handoff_listener
            .accept()
            .expect("accept the receiver's connection to the handoff endpoint");
        let manifest = HandoffManifest { sessions: vec![] };
        let sidecar = encode_manifest(&manifest).expect("encode an empty manifest");
        let listener_fd = control_listener
            .as_fd()
            .try_clone_to_owned()
            .expect("dup the stand-in control listener");
        // The fixed-design part: the SAME open file description
        // `held_lock` holds the exclusive flock on, duped and sent
        // alongside the listener (order: listener, then lock last,
        // matching `run_handoff_receiver`'s two trailing pops).
        let lock_fd = held_lock
            .as_fd()
            .try_clone_to_owned()
            .expect("dup the held lock fd for transfer");
        fdpass::send_fds(
            &offerer_stream,
            &sidecar,
            &[listener_fd.as_raw_fd(), lock_fd.as_raw_fd()],
        )
        .expect("send the manifest, control listener fd, and lock fd to the receiver");

        const ACK_BOUND: Duration = Duration::from_millis(300);
        let start = std::time::Instant::now();
        offerer_stream
            .set_read_timeout(Some(ACK_BOUND))
            .expect("set ack read timeout");
        let mut ack_byte = [0u8; 1];
        (&offerer_stream).read_exact(&mut ack_byte).expect(
            "the receiver should ack within 300ms because it already holds the \
             single-daemon lock via the transferred fd (same open file description as \
             this test's still-held `held_lock`) and must never need to independently \
             re-acquire a lock the old daemon cannot release until after the ack (P6 \
             review E5): today it discards the transferred lock fd and retries \
             acquire_daemon_lock instead, which cannot succeed while held_lock stays \
             open, so the ack takes up to LOCK_TAKEOVER_WAIT (5s) instead of arriving \
             promptly",
        );
        let ack_arrived_after = start.elapsed();
        assert!(
            ack_arrived_after < ACK_BOUND,
            "ack arrived after {ack_arrived_after:?}, at or beyond the {ACK_BOUND:?} \
             bound"
        );

        // Full contract: the receiver's hold must outlive this test's
        // own references. Release them exactly the way a real old daemon
        // does at the point of no return -- by CLOSING them without ever
        // unlocking (it `_exit`s, which closes its fds but never calls
        // flock `LOCK_UN`). Dropping the `Flock` guard here would instead
        // run its `LOCK_UN` on the shared open file description and
        // release the single lock the receiver shares (flock locks live
        // on the open file description, not the fd, so `LOCK_UN` via any
        // one dup frees it for every dup); `fdpass`'s R1 test pins that
        // close-not-unlock distinction. With both of this test's fds
        // closed but the receiver's transferred dup still open, a fresh
        // exclusive flock must still fail.
        let held_raw = held_lock.as_raw_fd();
        std::mem::forget(held_lock);
        // SAFETY: `held_raw` is this test's own still-open fd (nothing
        // else has closed it), closed here without unlocking so only the
        // receiver's transferred dup keeps the open file description
        // (and its lock) alive.
        assert_eq!(
            unsafe { libc::close(held_raw) },
            0,
            "closing this test's original lock fd should succeed"
        );
        drop(lock_fd);
        let fresh = std::fs::OpenOptions::new()
            .write(true)
            .open(&lock_path)
            .expect("open a fresh fd on the same lock file");
        let fresh_result =
            nix::fcntl::Flock::lock(fresh, nix::fcntl::FlockArg::LockExclusiveNonblock);
        assert!(
            fresh_result.is_err(),
            "a fresh exclusive flock attempt should still fail after this test closes its \
             own lock fds without unlocking, proving the receiver holds the lock via its \
             transferred dup of the same open file description alone (P6 review E5); see \
             fdpass's R1 test for the close-not-unlock semantics"
        );

        let _ = receiver_thread; // intentionally left running; see H5's test above.
    }
}
