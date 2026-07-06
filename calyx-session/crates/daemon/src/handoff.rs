//! Live Handoff (EXPERIMENTAL, P6): migrates a running daemon to a
//! new daemon binary without killing any session.
//!
//! **Contract.** `calyx-session upgrade` spawns a new daemon process,
//! which connects back to the running ("old") daemon's dedicated
//! handoff endpoint (a raw Unix socket, separate from the control
//! socket `sessiond.sock`: the control channel's length-prefixed CBOR
//! framing, `proto::frame`, has no ancillary-data carrier, and this
//! module deliberately does not extend it to sometimes carry fds). The
//! old daemon then:
//!
//! 1. Pauses every live session (stops its session thread from reading
//!    its PTY master, without touching the child or any on-disk
//!    state) and captures a [`HandoffManifest`] describing each one:
//!    identity/metadata for the ledger, the terminal geometry, and a
//!    [`vt::Terminal::render_replay`] snapshot captured on that
//!    session's own thread at the moment of pausing (single-thread
//!    ownership makes this snapshot atomic with respect to the pause:
//!    no PTY bytes can be fed to the terminal between the snapshot and
//!    the pause taking effect).
//! 2. Sends the encoded manifest plus every session's PTY master fd
//!    (then its own listener fd, then the single-daemon lock fd) to the
//!    new daemon via `crate::fdpass`, session fd order matching
//!    `HandoffManifest::sessions` order. The lock fd travels so the new
//!    daemon holds the same open file description the old one locked,
//!    with no re-acquire race (P6 review E5).
//! 3. Waits (bounded) for the new daemon's ack that it has adopted
//!    every session and started accepting on the transferred listener.
//!
//! **Point of no return.** Before that ack arrives, nothing
//! destructive has happened: `SCM_RIGHTS` duplicates a file
//! description rather than moving it, so the old daemon still holds
//! its own copies of every fd it sent, and "pausing" a session thread
//! never touches its child, its history files, or the ledger. If the
//! new daemon dies or times out before acking, the old daemon simply
//! resumes every paused session and keeps serving exactly as before
//! (see [`offer_handoff`] and R5's test). Only the received ack moves
//! the old daemon past that point: it exits immediately afterward
//! (skipping `Daemon::run_until_idle`'s normal teardown entirely, the
//! same way this crate's existing daemonization path already uses
//! `libc::_exit` to skip unwinding -- see `crate` root doc and
//! `cli::commands::daemon`), so no session's normal per-session
//! teardown (`session.rs`'s history-delete / ledger-Exited / reap
//! sequence) ever runs on the old side. See [`detach_for_handoff`] and
//! R4's test for the narrower, unit-tested half of that guarantee.
//!
//! **Client impact.** Attached clients are not individually migrated:
//! the old daemon's process exit closes every one of its connections,
//! exactly like an ordinary daemon crash from a client's perspective.
//! Reconnecting (already-existing client machinery, out of scope
//! here) lands on the new daemon's control socket and gets a fresh
//! `Replay` from the now-adopted session, which already contains the
//! pre-handoff scrollback (see [`adopt_session`] and R3's test).
//!
//! **Known limitation (experimental).** An adopted session's process
//! was never forked by the daemon that now owns its PTY master fd, so
//! that daemon is not its parent and cannot `waitpid` it for a real
//! exit code. Exit detection for an adopted session therefore has to
//! degrade to polling liveness (e.g. `kill(pid, 0)`) after PTY EOF,
//! with the recorded exit code necessarily unknown. This is inherent
//! to any same-machine PTY-fd handoff that does not also re-parent the
//! child (e.g. via a subreaper), and is called out here rather than
//! hidden: it is one of the reasons this whole feature ships
//! experimental.

use std::collections::BTreeMap;
use std::io::Read;
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{mpsc, Arc};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use proto::SessionState;

use crate::error::DaemonError;
use crate::fdpass;
use crate::history;
use crate::outq::{lock_unpoisoned, OutQueue};
use crate::session::{
    make_wake_pipe, start_session_thread, PauseError, PausedSession, SessionChild, SessionInput,
    SessionMailbox, SessionRequest, SessionThread,
};
use crate::state::{SessionEntry, Shared};

/// The single byte the receiving daemon writes back on the handoff
/// stream once every session is adopted and the transferred listener
/// is armed: the old daemon's point of no return (module doc).
pub(crate) const HANDOFF_ACK: u8 = 0x06;

/// Upper bound on fds in one handoff (every session's PTY master plus
/// the control listener and the single-daemon lock fd), used to size
/// the receiver's `SCM_RIGHTS` control buffer. This is a self-imposed protocol cap, not a kernel
/// limit: it is deliberately *not* Linux's per-message `SCM_MAX_FD`
/// (253), because this daemon targets macOS, which has no such fixed
/// per-message constant. The value is chosen to stay comfortably under
/// a typical macOS default `RLIMIT_NOFILE` soft limit of 256 (leaving
/// headroom for the daemon's own sockets, pipes, and history files) and
/// to keep the receiver's `CMSG_SPACE` allocation bounded. A daemon
/// with more live sessions than this simply cannot hand off
/// (EXPERIMENTAL limitation).
pub(crate) const MAX_HANDOFF_FDS: usize = 253;

/// How long `offer_handoff` waits for each session thread to
/// acknowledge its pause: bounded so a wedged (or already-exited)
/// session thread fails the attempt instead of hanging the daemon.
const PAUSE_REPLY_TIMEOUT: Duration = Duration::from_secs(5);

/// Bounds the manifest/fd send in `offer_handoff` (P6 review H6). A
/// receiver that connects and then stalls without draining its end
/// would otherwise block the `SCM_RIGHTS` send forever, freezing every
/// already-paused session; on this bound tripping, the send fails and
/// every paused session is resumed. This is `SO_SNDTIMEO`, so it bounds
/// how long a single blocking write waits for buffer space, never the
/// whole transfer: a receiver that keeps draining never trips it,
/// however large the manifest, while one that has not accepted a single
/// byte for this long is wedged. One second is a generous "the receiver
/// is a fresh local daemon that has gone unresponsive" threshold (a
/// healthy `recv_fds` drains in milliseconds).
const HANDOFF_SEND_TIMEOUT: Duration = Duration::from_secs(1);

/// How long the handoff host waits for the spawned receiver to connect
/// to the dedicated endpoint before giving up and resuming service.
const ACCEPT_TIMEOUT_MS: u16 = 10_000;

/// How long `offer_handoff` waits for the receiver's ack (the bound on
/// the whole adopt-everything phase on the other side).
pub(crate) const HANDOFF_ACK_TIMEOUT: Duration = Duration::from_secs(10);

/// Everything the receiving daemon needs to adopt one session it did
/// not itself create. Does not carry the PTY master fd itself: fds
/// travel out-of-band via `crate::fdpass`'s `SCM_RIGHTS` plumbing, in
/// the same order as [`HandoffManifest::sessions`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct HandoffManifest {
    pub(crate) sessions: Vec<HandoffSessionEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct HandoffSessionEntry {
    pub(crate) id: String,
    pub(crate) name: Option<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) created_at_ms: u64,
    pub(crate) pid: u32,
    pub(crate) meta: BTreeMap<String, String>,
    /// The terminal geometry in effect at the moment of pausing (not
    /// necessarily what the session was *created* with: a client may
    /// have resized it since; see `session.rs`'s `Resize` handling).
    /// A freshly constructed `vt::Terminal` must use this exact size,
    /// or `replay` (rendered at this size) will not reconstruct
    /// correctly.
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    /// `vt::Terminal::render_replay()`'s output, captured on this
    /// session's own thread immediately before the handoff pause (see
    /// the module doc): feeding it into a freshly created, same-sized
    /// `vt::Terminal` reconstructs this session's pre-handoff screen,
    /// scrollback, modes, and cursor.
    pub(crate) replay: Vec<u8>,
}

/// Encodes a [`HandoffManifest`] to CBOR bytes suitable for
/// `crate::fdpass::send_fds`'s sidecar parameter. Mirrors
/// `proto::encode_control`'s style; kept separate from `proto` because
/// this manifest is an internal daemon-to-daemon concern, never sent
/// to an ordinary client.
pub(crate) fn encode_manifest(manifest: &HandoffManifest) -> Result<Vec<u8>, DaemonError> {
    let mut buf = Vec::new();
    ciborium::into_writer(manifest, &mut buf).map_err(|e| {
        DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            e.to_string(),
        ))
    })?;
    Ok(buf)
}

/// Decodes bytes produced by [`encode_manifest`] back into a
/// [`HandoffManifest`]. Must return `Err`, never panic, on malformed
/// input: like every other daemon-facing wire payload, this crosses a
/// process boundary a buggy or crashed peer controls.
pub(crate) fn decode_manifest(bytes: &[u8]) -> Result<HandoffManifest, DaemonError> {
    ciborium::from_reader(bytes).map_err(|e| {
        DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            e.to_string(),
        ))
    })
}

/// Reconstructs a session's registry entry and starts its session
/// thread from a handoff manifest entry and its already-received PTY
/// master fd (`crate::fdpass::recv_fds`'s output), instead of forking a
/// new child: the process at `entry.pid` belongs to the daemon
/// generation that sent the handoff, not this one. Mirrors
/// `crate::session::spawn_session`'s registration contract (same
/// return type, same start-gate discipline) so a caller registers the
/// result into `Shared::sessions`/`ledger` identically to a freshly
/// spawned session; unlike `spawn_session`, the very first thing the
/// fresh `vt::Terminal` does is `feed(&entry.replay)`, before the
/// session's main read loop ever touches `master_fd`, so the first
/// `Replay` any attaching client receives already contains the
/// pre-handoff content.
///
/// See the module doc's "Known limitation" for why an adopted
/// session's eventual exit code cannot be a real `waitpid` status.
pub(crate) fn adopt_session(
    shared: &Arc<Shared>,
    entry: HandoffSessionEntry,
    master_fd: OwnedFd,
) -> Result<SessionEntry, String> {
    let HandoffSessionEntry {
        id,
        name,
        cwd,
        created_at_ms,
        pid,
        meta,
        cols,
        rows,
        replay,
    } = entry;

    // Mirror spawn_session's fd discipline. CLOEXEC is an fd flag and
    // does not travel with an SCM_RIGHTS transfer (fdpass::recv_fds
    // already restores it; re-asserted here because this function's
    // contract must not depend on which channel delivered the fd).
    // O_NONBLOCK lives on the shared open file description and
    // normally does travel, but the session loop's never-blocks
    // invariant rests on it, so it too is asserted rather than assumed.
    nix::fcntl::fcntl(
        master_fd.as_fd(),
        nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
    )
    .map_err(|e| format!("set adopted pty cloexec: {e}"))?;
    nix::fcntl::fcntl(
        master_fd.as_fd(),
        nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
    )
    .map_err(|e| format!("set adopted pty master nonblocking: {e}"))?;

    let master_input = Arc::new(
        master_fd
            .try_clone()
            .map_err(|e| format!("dup adopted pty master failed: {e}"))?,
    );
    let input = SessionInput::new();
    let (wake_rx, wake_tx) = make_wake_pipe()?;
    let mailbox = Arc::new(SessionMailbox::new(wake_tx));

    let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
    let (start_tx, start_rx) = mpsc::sync_channel::<()>(1);
    // Pre-release the start gate: adoption has no create race to
    // arbitrate (the receiver adopts everything before serving a
    // single client), and this function's contract is that the
    // returned entry is live without a further release_start call.
    // A later, redundant release_start is still harmless (it fills
    // the just-emptied buffer).
    let _ = start_tx.send(());

    // History continuation, not the receiver's daemon-wide default:
    // see history::has_persisted. The thread never crash-seeds for an
    // adopted session (`replay` below is the authoritative snapshot).
    let history_enabled = history::has_persisted(&shared.state_dir, &id);

    start_session_thread(
        SessionThread {
            shared: Arc::clone(shared),
            id: id.clone(),
            master: master_fd,
            wake_rx,
            mailbox: Arc::clone(&mailbox),
            input: Arc::clone(&input),
            child: SessionChild::Adopted { pid },
            cols: cols.max(1),
            rows: rows.max(1),
            ready_tx,
            start_rx,
            state_dir: shared.state_dir.clone(),
            history_enabled,
            seed_replay: replay,
        },
        ready_rx,
    )?;

    Ok(SessionEntry {
        id,
        name,
        cwd,
        created_at_ms,
        pid,
        meta,
        attached_clients: 0,
        mailbox,
        master_input,
        input,
        start_tx,
    })
}

/// Removes `id` from the live registry for a handoff, returning the
/// removed entry so the caller (`offer_handoff`) can render its
/// replay, extract its PTY fd, and place it into a [`HandoffManifest`].
///
/// Unlike the session thread's own teardown (`session.rs`'s exit path,
/// steps 1-6 in its doc comment), this must NOT delete the session's
/// history files, must NOT signal its child, and must NOT flip its
/// ledger entry to `Exited`: the session is not ending, only moving to
/// a different daemon process. See R4's test for the exact assertions.
pub(crate) fn detach_for_handoff(shared: &Arc<Shared>, id: &str) -> Option<SessionEntry> {
    let mut state = shared.lock_state();
    // Only the registry entry moves: the ledger keeps saying Running
    // (true: the child lives on), the child gets no signal, and the
    // history files stay for the next generation to continue. The
    // session thread's own eventual teardown is disarmed by its
    // identity check (session.rs step 1: the entry it would remove is
    // no longer its own), which also keeps its history-delete and
    // ledger-flip steps (gated on that same check) from running.
    let entry = state.sessions.remove(id)?;
    state.touch();
    Some(entry)
}

/// Attempts a full handoff to whatever new daemon process is connected
/// as `peer` (having already reached this old daemon's dedicated
/// handoff endpoint): pauses every live session, sends the manifest and
/// fds, and waits up to `timeout` for the receiver's ack.
///
/// Returns `Err` on any failure before that ack -- including the
/// receiver dying immediately after connecting -- and in that case
/// leaves every session exactly as it was (resumed, still registered,
/// still `Running`): see the module doc's "Point of no return" and
/// R5's test. Only `Ok(())` means the old daemon has crossed that
/// point and must exit without running its normal teardown (the
/// caller, not this function, performs that exit: see the module doc).
pub(crate) fn offer_handoff(
    shared: &Arc<Shared>,
    peer: &UnixStream,
    timeout: Duration,
) -> Result<(), String> {
    // Detach and pause every live session. Both halves are reversible
    // (re-insert; resume) until the ack lands.
    let ids: Vec<String> = shared.lock_state().sessions.keys().cloned().collect();

    // Fail fast before pausing/rendering anything (P6 review H9): the
    // receiver's SCM_RIGHTS buffer is sized for MAX_HANDOFF_FDS (one fd
    // per session plus the control listener and the single-daemon lock
    // fd), and an over-count is only caught at recv time otherwise,
    // after a full pause/render/resume cycle has already been wasted.
    // `+ 2` for the listener and lock fd is an upper bound (a unit-test
    // context with no installed handoff env sends fewer), which only
    // ever makes this check stricter, never laxer.
    if ids.len() + 2 > MAX_HANDOFF_FDS {
        return Err(format!(
            "cannot hand off {} live sessions: exceeds the {}-fd-per-handoff limit \
             (one PTY master per session plus the control listener and the \
             single-daemon lock fd)",
            ids.len(),
            MAX_HANDOFF_FDS
        ));
    }

    let mut candidates: Vec<HandoffCandidate> = Vec::new();
    for id in ids {
        let Some(entry) = detach_for_handoff(shared, &id) else {
            // Exited concurrently: nothing left to move for this id.
            continue;
        };
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        entry
            .mailbox
            .send(SessionRequest::PauseForHandoff { reply: reply_tx });
        match reply_rx.recv_timeout(PAUSE_REPLY_TIMEOUT) {
            Ok(Ok(paused)) => candidates.push(HandoffCandidate { entry, paused }),
            Ok(Err(PauseError::ExitedDuringPause)) => {
                // The child exited during the pause window; this entry's
                // thread is tearing down and there is nothing left to
                // migrate. Record the terminal state (never a restored
                // zombie: its thread is already gone -- P6 review H3),
                // resume the sessions that did pause, and fail.
                finalize_exited(shared, entry);
                resume_all(shared, candidates);
                return Err(format!("session {id:?} exited during the handoff pause"));
            }
            Ok(Err(PauseError::RenderFailed(e))) => {
                // The thread replied a render failure and keeps running,
                // so it only needs re-inserting.
                restore_entry(shared, entry);
                resume_all(shared, candidates);
                return Err(format!("pausing session {id:?} failed: {e}"));
            }
            Err(_) => {
                // The thread never replied within the bound. Its stale
                // pause request can no longer park it: the reply sender
                // is dropped here, and the session thread only parks
                // after a successful reply send. `restore_entry` decides
                // between reinserting a still-live (wedged) thread and
                // finalizing one that already exited (H3).
                restore_entry(shared, entry);
                resume_all(shared, candidates);
                return Err(format!(
                    "session {id:?} did not acknowledge the handoff pause within \
                     {PAUSE_REPLY_TIMEOUT:?}"
                ));
            }
        }
    }

    // Manifest and fds in matching order (module doc contract): the
    // control listener and then the single-daemon lock fd travel after
    // every session's PTY master, so the receiver can take over
    // accepting with no unbind/rebind gap and already hold the lock via
    // the transferred fd. Both are absent only where no serving handoff
    // env was installed (unit-test contexts).
    let mut sessions = Vec::with_capacity(candidates.len());
    let mut fds: Vec<RawFd> = Vec::with_capacity(candidates.len() + 2);
    for candidate in &mut candidates {
        sessions.push(HandoffSessionEntry {
            id: candidate.entry.id.clone(),
            name: candidate.entry.name.clone(),
            cwd: candidate.entry.cwd.clone(),
            created_at_ms: candidate.entry.created_at_ms,
            pid: candidate.entry.pid,
            meta: candidate.entry.meta.clone(),
            cols: candidate.paused.cols,
            rows: candidate.paused.rows,
            // Taken, not cloned: a failure past this point resumes the
            // session without needing the replay again.
            replay: std::mem::take(&mut candidate.paused.replay),
        });
        fds.push(candidate.entry.master_input.as_raw_fd());
    }
    let listener_dup: Option<OwnedFd> = {
        let env = lock_unpoisoned(&shared.handoff_env);
        match env.as_ref() {
            Some(env) => match env.listener.try_clone() {
                Ok(fd) => Some(fd),
                Err(e) => {
                    resume_all(shared, candidates);
                    return Err(format!("dup control listener for handoff failed: {e}"));
                }
            },
            None => None,
        }
    };
    if let Some(fd) = &listener_dup {
        fds.push(fd.as_raw_fd());
    }
    // The single-daemon lock fd travels last (P6 review E5), after the
    // listener, so the receiver already holds the exact open file
    // description the old daemon locked and never has to re-acquire a
    // lock the old daemon cannot release until after the ack. Absent
    // only where this generation holds no lock fd (library callers of
    // `Daemon::bind`, unit-test contexts).
    let lock_dup: Option<OwnedFd> = {
        let env = lock_unpoisoned(&shared.handoff_env);
        match env.as_ref() {
            Some(env) => match &env.lock {
                Some(lock) => match lock.try_clone() {
                    Ok(fd) => Some(fd),
                    Err(e) => {
                        resume_all(shared, candidates);
                        return Err(format!("dup single-daemon lock for handoff failed: {e}"));
                    }
                },
                None => None,
            },
            None => None,
        }
    };
    if let Some(fd) = &lock_dup {
        fds.push(fd.as_raw_fd());
    }

    let manifest = HandoffManifest { sessions };
    let sidecar = match encode_manifest(&manifest) {
        Ok(bytes) => bytes,
        Err(e) => {
            resume_all(shared, candidates);
            return Err(format!("encoding handoff manifest failed: {e}"));
        }
    };
    // Bound the send (P6 review H6): without a write timeout a receiver
    // that connects and then stalls without draining freezes this
    // sendmsg forever, leaving every paused session parked indefinitely.
    // On the bound tripping, `send_fds` returns an error and the resume
    // path below runs, exactly as for any other send failure.
    if let Err(e) = peer.set_write_timeout(Some(HANDOFF_SEND_TIMEOUT)) {
        resume_all(shared, candidates);
        return Err(format!("setting handoff send timeout failed: {e}"));
    }
    if let Err(e) = fdpass::send_fds(peer, &sidecar, &fds) {
        resume_all(shared, candidates);
        return Err(format!("sending handoff manifest and fds failed: {e}"));
    }

    // Bounded ack wait: everything before this is reversible, receipt
    // is the point of no return (module doc).
    if let Err(e) = peer.set_read_timeout(Some(timeout)) {
        resume_all(shared, candidates);
        return Err(format!("setting handoff ack timeout failed: {e}"));
    }
    let mut ack = [0u8; 1];
    let mut reader: &UnixStream = peer;
    if let Err(e) = reader.read_exact(&mut ack) {
        resume_all(shared, candidates);
        return Err(format!("no handoff ack within {timeout:?}: {e}"));
    }
    if ack[0] != HANDOFF_ACK {
        resume_all(shared, candidates);
        return Err(format!("unexpected handoff ack byte {:#04x}", ack[0]));
    }

    // Past the point of no return: the receiver owns every session.
    // Dropping the candidates would drop their resume channels, which
    // resumes the parked threads (PausedSession's safety default) and
    // would let them race the new daemon for PTY bytes in the instant
    // before the caller's `_exit`; leaking them keeps the old threads
    // parked until the process ends.
    std::mem::forget(candidates);
    Ok(())
}

struct HandoffCandidate {
    entry: SessionEntry,
    paused: PausedSession,
}

/// Failure-path half of `detach_for_handoff`: puts a (non-parked) entry
/// back into the live registry, unless its session thread has already
/// exited.
///
/// A session whose child died during the pause window (before it could
/// park) has a thread that ran its own teardown and returned, dropping
/// its clone of the mailbox `Arc` and leaving this detached entry as the
/// sole owner. Reinserting it then would publish a live-looking zombie
/// backed by a dead thread: every future `Attach` would hang and every
/// `Kill` would time out, needing a daemon restart to clear (P6 review
/// H3 / E#2). Detect that here by the mailbox's strong count -- the entry
/// and its thread are the only two possible holders while it is detached
/// (it is out of the registry, so no request path can hold a transient
/// clone) -- and record the terminal state instead of reinserting.
///
/// A count above one means the thread is still alive (wedged, or it
/// replied a render failure and kept running); reinserting is correct,
/// and if it does exit later, its own teardown finds this reinserted
/// entry by mailbox identity and cleans it up.
fn restore_entry(shared: &Arc<Shared>, entry: SessionEntry) {
    if Arc::strong_count(&entry.mailbox) == 1 {
        finalize_exited(shared, entry);
        return;
    }
    let mut state = shared.lock_state();
    state.sessions.insert(entry.id.clone(), entry);
    state.touch();
    shared.cond.notify_all();
}

/// Records the terminal state for a handoff-detached session whose
/// thread has already exited (its child died during the pause window):
/// flip its ledger record to `Exited` and drop the entry, never
/// republishing a dead-thread zombie into the live registry (P6 review
/// H3). The exit code is unknowable here -- a detached entry's own
/// teardown skips the ledger flip (its `mine` check finds the entry
/// already gone), so it reaped the child and discarded the code -- so
/// -1, the same sentinel `SessionChild::reap` uses when no status is
/// available.
fn finalize_exited(shared: &Arc<Shared>, entry: SessionEntry) {
    // Delete this session's on-disk history, the same as the normal
    // confirmed-exit teardown in `session.rs` (P6 fix-batch sweep S2):
    // history exists to survive a daemon crash, not a session's own end,
    // and this path ends the session. `remove_all` is a no-op when
    // nothing is persisted, so it is unconditional; a failure is
    // logged, not propagated, exactly as teardown does.
    if let Err(e) = history::HistoryWriter::remove_all(&shared.state_dir, &entry.id) {
        eprintln!(
            "calyx-sessiond: removing history for {} failed: {e}",
            entry.id
        );
    }
    let mut state = shared.lock_state();
    state.sessions.remove(&entry.id);
    if let Some(info) = state.ledger.get_mut(&entry.id) {
        info.state = SessionState::Exited { code: -1 };
        info.pid = 0;
        info.attached_clients = 0;
    }
    state.touch();
    shared.persist_ledger(&state);
    shared.cond.notify_all();
}

/// Opportunistic reconciliation for a dead-thread adopted "ghost" (P6
/// fix-batch sweep S1). An adopted session whose process outlived its
/// post-EOF liveness poll (`SessionChild::reap` returned `None`) keeps
/// its registry entry and its `Running` ledger record so a later `Kill`
/// can still reach the real process; but its session thread has already
/// returned, so nothing on that path will ever notice the process
/// eventually dying. `Kill` and `List` (conn.rs) call this to finish
/// the job.
///
/// If `id`'s still-registered entry belongs to a returned thread (its
/// mailbox is the sole remaining holder, the same dead-thread test
/// `restore_entry` uses) and its `pid` is now confirmed gone
/// (`kill(pid, 0)` fails with `ESRCH`), this deletes its history, flips
/// the ledger to `Exited { code: -1 }` (the unknowable-exit sentinel
/// `finalize_exited` and `reap` also use), drops the entry, and returns
/// `true`. It leaves a live session (thread still running, so its
/// mailbox has more than one holder) or a still-alive process untouched
/// and returns `false`: only a genuine ghost is ever finalized, so this
/// never races a live session's own teardown.
///
/// Everything runs under the one registry lock (the liveness probe and
/// the history unlink are both cheap and non-blocking): that keeps a
/// same-id create and any concurrent reconciler from interleaving, so
/// the removal always targets exactly the ghost that was probed.
pub(crate) fn reconcile_adopted_ghost(shared: &Arc<Shared>, id: &str) -> bool {
    let mut state = shared.lock_state();
    let Some(entry) = state.sessions.get(id) else {
        return false;
    };
    // A live session's thread still holds a mailbox clone; only a
    // returned-thread ghost is a candidate.
    if Arc::strong_count(&entry.mailbox) != 1 {
        return false;
    }
    let pid = nix::unistd::Pid::from_raw(entry.pid as i32);
    // Still alive: it stays a registered, killable ghost.
    if nix::sys::signal::kill(pid, None).is_ok() {
        return false;
    }
    // Confirmed gone: same terminal bookkeeping as `finalize_exited`,
    // minus the code (unknowable for an adopted process; see the module
    // doc's known limitation).
    if let Err(e) = history::HistoryWriter::remove_all(&shared.state_dir, id) {
        eprintln!("calyx-sessiond: removing history for {id} failed: {e}");
    }
    state.sessions.remove(id);
    if let Some(info) = state.ledger.get_mut(id) {
        info.state = SessionState::Exited { code: -1 };
        info.pid = 0;
        info.attached_clients = 0;
    }
    state.touch();
    shared.persist_ledger(&state);
    shared.cond.notify_all();
    true
}

/// Failure path: wakes every parked session thread and re-registers
/// its entry, leaving the daemon serving exactly as before the attempt
/// (R5's contract).
fn resume_all(shared: &Arc<Shared>, candidates: Vec<HandoffCandidate>) {
    let mut state = shared.lock_state();
    for candidate in candidates {
        let _ = candidate.paused.resume_tx.send(());
        state
            .sessions
            .insert(candidate.entry.id.clone(), candidate.entry);
    }
    state.touch();
    shared.cond.notify_all();
}

/// Hosts one handoff attempt end to end, on its own thread (spawned by
/// `conn::Conn::prepare_handoff`): waits (bounded) for the receiver to
/// connect to the dedicated endpoint, uid-checks it like any control
/// connection, and runs [`offer_handoff`]. On success this never
/// returns: per the module doc the old daemon exits immediately,
/// skipping all teardown, via `_exit` (the crate's established pattern
/// for exiting without unwinding). On any failure it reports a
/// `handoff-failed` error on the requesting client's queue, re-arms
/// `Shared::handoff_in_progress`, and returns with the daemon serving
/// exactly as before.
pub(crate) fn host_handoff(
    shared: Arc<Shared>,
    listener: UnixListener,
    socket_path: std::path::PathBuf,
    requester: Arc<OutQueue>,
) {
    let result = accept_and_offer(&shared, &listener);
    // Served its purpose either way: the endpoint is single-use.
    let _ = std::fs::remove_file(&socket_path);
    match result {
        Ok(()) => {
            // Point of no return crossed. sessiond.sock stays on disk
            // on purpose: the transferred listener keeps serving it.
            // SAFETY: process exit without unwinding, the same way the
            // daemonized CLI path ends (see cli::commands::daemon).
            unsafe { libc::_exit(0) }
        }
        Err(e) => {
            eprintln!("calyx-sessiond: handoff failed, continuing to serve: {e}");
            if let Ok(payload) = proto::encode_control(&proto::ControlMsg::Err {
                code: "handoff-failed".to_string(),
                msg: e,
            }) {
                requester.push(proto::FrameType::Control, payload);
            }
            shared
                .handoff_in_progress
                .store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }
}

fn accept_and_offer(shared: &Arc<Shared>, listener: &UnixListener) -> Result<(), String> {
    use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
    // UnixListener has no native accept timeout; poll first so a
    // receiver that never connects (spawn failure, wrong path) leaves
    // the daemon serving instead of pinning this thread forever.
    let mut poll_fds = [PollFd::new(listener.as_fd(), PollFlags::POLLIN)];
    loop {
        match poll(&mut poll_fds, PollTimeout::from(ACCEPT_TIMEOUT_MS)) {
            Ok(0) => {
                return Err(format!(
                    "no handoff receiver connected within {ACCEPT_TIMEOUT_MS}ms"
                ))
            }
            Ok(_) => break,
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => return Err(format!("poll on handoff listener failed: {e}")),
        }
    }
    let (stream, _) = listener
        .accept()
        .map_err(|e| format!("accept on handoff listener failed: {e}"))?;
    // Same credential gate as the control socket's accept loop.
    crate::peer::verify_peer_uid(&stream).map_err(|e| format!("handoff peer rejected: {e}"))?;
    offer_handoff(shared, &stream, HANDOFF_ACK_TIMEOUT)
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;

    use proto::{FrameReader, FrameType, SessionSpec, SessionState};

    use super::*;
    use crate::outq::{writer_loop, OutQueue};
    use crate::session::{spawn_session, SessionRequest};
    use crate::state::HandoffEnv;

    fn cat_spec(id: &str) -> SessionSpec {
        SessionSpec {
            id: id.to_string(),
            name: None,
            cwd: None,
            argv: Some(vec!["/bin/cat".to_string()]),
            env: vec![],
            cols: 80,
            rows: 24,
        }
    }

    /// Kills the process group on drop, including on an early return via
    /// panic (e.g. today's `unimplemented!()` stubs): without this, a
    /// spawned `/bin/cat` donor would otherwise outlive a test that
    /// panics before reaching its own explicit cleanup.
    struct KillOnDrop(u32);

    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(self.0 as i32),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
    }

    /// R2 (P6 RED3): `HandoffManifest` must round-trip through CBOR
    /// byte-for-byte, including binary (non-UTF8) replay bytes -- a
    /// text-based format like JSON would choke on or mangle these
    /// without an escape scheme -- plus `meta` and `created_at_ms`.
    #[test]
    fn handoff_manifest_round_trips_through_cbor_including_binary_replay_and_meta() {
        let mut meta = BTreeMap::new();
        meta.insert("agent".to_string(), "claude".to_string());
        meta.insert("cwd-kind".to_string(), "worktree".to_string());

        let manifest = HandoffManifest {
            sessions: vec![HandoffSessionEntry {
                id: "01J-p6-manifest-roundtrip".to_string(),
                name: Some("build".to_string()),
                cwd: Some("/tmp/project".to_string()),
                created_at_ms: 1_732_000_000_123,
                pid: 4242,
                meta,
                cols: 132,
                rows: 43,
                // A raw CSI clear-screen sequence plus out-of-range
                // bytes: deliberately not valid UTF-8.
                replay: vec![0x1b, b'[', b'2', b'J', 0xFF, 0x00, 0x7F],
            }],
        };

        let encoded = encode_manifest(&manifest).expect("encode_manifest should succeed");
        let decoded = decode_manifest(&encoded).expect("decode_manifest should succeed");

        assert_eq!(
            decoded, manifest,
            "HandoffManifest must round-trip through CBOR byte-for-byte, including binary \
             replay bytes, meta, and created_at_ms"
        );
    }

    /// R3 (P6 RED3): a receiver constructing a session from a manifest
    /// entry plus an already-received PTY fd must yield the same pid,
    /// a `Replay` to a newly attaching client containing the
    /// pre-handoff content, and live PTY IO afterward.
    #[test]
    fn adopt_session_preserves_pid_replays_pre_handoff_content_and_stays_live() {
        // Replay content built independently of any running session
        // (mirrors history.rs's own crash-restore seeding test): a
        // fresh terminal fed a known marker, then rendered to the
        // exact bytes `adopt_session` must feed into its own fresh
        // terminal to reproduce it.
        let mut donor_terminal = vt::Terminal::new(80, 24, 8 * 1024 * 1024)
            .expect("create scratch terminal for replay bytes");
        donor_terminal
            .feed(b"PRE_HANDOFF_MARKER\r\n")
            .expect("feed marker into scratch terminal");
        let replay_bytes = donor_terminal
            .render_replay()
            .expect("render_replay on scratch terminal");

        // A real PTY + child, so `adopt_session` gets a real fd and a
        // real pid to preserve -- obtained via the already-tested
        // `spawn_session` rather than duplicating its
        // openpty/fork/exec setup here.
        let donor_tmp = tempfile::tempdir().expect("scratch state dir for donor");
        let donor_shared = Arc::new(Shared::new(donor_tmp.path().to_path_buf(), false));
        let donor_spec = cat_spec("01J-p6-handoff-adopt-donor");
        let donor =
            spawn_session(&donor_shared, &donor_spec).expect("spawn_session should succeed");
        // Deliberately never released from its start gate: the donor's
        // own session thread must not read this PTY, standing in for
        // the real contract's sending daemon, which pauses a session
        // before its fd travels (module doc step 1). Releasing it
        // would add a second reader on the same open file description,
        // and the kernel hands each PTY output chunk to exactly one of
        // the racing readers, so the live-IO assertion below would
        // fail whenever the donor thread won (GREEN3 fix: the original
        // RED setup called `donor.release_start()` here and flaked).
        let donor_pid = donor.pid;
        let _kill_donor_on_drop = KillOnDrop(donor_pid);
        let inherited_master = donor.master_input.as_ref().try_clone().expect(
            "duplicate the donor's PTY master fd (stands in for an SCM_RIGHTS-received fd)",
        );

        let manifest_entry = HandoffSessionEntry {
            id: "01J-p6-handoff-adopt-test".to_string(),
            name: None,
            cwd: None,
            created_at_ms: donor.created_at_ms,
            pid: donor_pid,
            meta: BTreeMap::new(),
            cols: 80,
            rows: 24,
            replay: replay_bytes,
        };

        let receiver_tmp = tempfile::tempdir().expect("scratch state dir for receiver");
        let receiver_shared = Arc::new(Shared::new(receiver_tmp.path().to_path_buf(), false));

        let adopted = adopt_session(&receiver_shared, manifest_entry, inherited_master).expect(
            "adopt_session should construct a running session from a manifest entry + \
             inherited fd",
        );

        assert_eq!(
            adopted.pid, donor_pid,
            "an adopted session must keep the original process's pid"
        );

        let mailbox = Arc::clone(&adopted.mailbox);
        let master_input = Arc::clone(&adopted.master_input);
        let input = Arc::clone(&adopted.input);

        // Attach a client the same way conn.rs does: a real OutQueue
        // backed by a real UnixStream pair and the crate's own
        // writer_loop, so the frames this test reads are exactly what
        // a real client socket would receive.
        let (client_side, server_side) = UnixStream::pair().expect("create scratch stream pair");
        client_side
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .expect("set read timeout on the client side");
        let queue = OutQueue::new();
        {
            let queue = Arc::clone(&queue);
            std::thread::spawn(move || writer_loop(queue, server_side));
        }
        mailbox.send(SessionRequest::Attach { conn_id: 1, queue });

        let mut reader = FrameReader::new(
            client_side
                .try_clone()
                .expect("clone client stream for reader"),
        );
        let replay_frame = reader.read_frame().expect("read the Replay frame");
        assert_eq!(
            replay_frame.frame_type,
            FrameType::Replay,
            "the first frame after adopting and attaching must be a Replay frame"
        );
        assert!(
            String::from_utf8_lossy(&replay_frame.payload).contains("PRE_HANDOFF_MARKER"),
            "the Replay frame for a client attaching after adoption must contain the \
             pre-handoff content, got: {:?}",
            String::from_utf8_lossy(&replay_frame.payload)
        );

        // Live PTY IO: submit input the same way conn.rs's
        // forward_input does, and expect it to flow through to the
        // still-running real `cat` child and back out as Output.
        input.submit(&master_input, b"LIVE_AFTER_HANDOFF\n");
        mailbox.send(SessionRequest::Pump);
        loop {
            let frame = reader
                .read_frame()
                .expect("read frame while waiting for live post-handoff output");
            if frame.frame_type == FrameType::Output
                && String::from_utf8_lossy(&frame.payload).contains("LIVE_AFTER_HANDOFF")
            {
                break;
            }
        }
    }

    /// R4 (P6 RED3): handoff-exit must not run any of the normal
    /// per-session teardown side effects (`session.rs`'s exit path):
    /// no history-file deletion, no signaling the child, no ledger
    /// flip to `Exited`.
    #[test]
    fn detach_for_handoff_does_not_delete_history_signal_child_or_flip_ledger_to_exited() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        // History enabled, so there is a history file whose survival is
        // actually meaningful to assert on.
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), true));
        let id = "01J-p6-handoff-suppress-test";
        let spec = cat_spec(id);
        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        let _kill_on_drop = KillOnDrop(pid);

        // Register into the registry + ledger the way conn.rs's
        // create_session does, so detach_for_handoff has a real,
        // fully-registered entry to act on.
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        let history_path = tmp.path().join("history").join(format!("{id}.raw"));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while !history_path.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            history_path.exists(),
            "history file should exist before the handoff-exit under test"
        );

        let removed = detach_for_handoff(&shared, id);
        assert!(
            removed.is_some(),
            "detach_for_handoff should return the removed live entry"
        );

        assert!(
            history_path.exists(),
            "handoff-exit must not delete this session's history file"
        );

        let alive = nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None);
        assert!(
            alive.is_ok(),
            "handoff-exit must not signal (SIGKILL or otherwise) the child, kill(pid, 0) \
             returned {alive:?}"
        );

        let ledger_state = shared.lock_state().ledger.get(id).map(|info| info.state);
        assert_eq!(
            ledger_state,
            Some(SessionState::Running),
            "handoff-exit must not flip the ledger entry to Exited"
        );
    }

    /// R5 (P6 RED3): the point of no return is the receiver's ack, not
    /// the start of the handoff attempt. A receiver that disappears
    /// before ever acking must leave the old daemon fully functional:
    /// the session stays registered and `Running`.
    #[test]
    fn offer_handoff_resumes_normal_service_when_the_receiver_never_acks() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let id = "01J-p6-handoff-noack-test";
        let spec = cat_spec(id);
        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        let _kill_on_drop = KillOnDrop(pid);
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        // A "receiver" that accepts the handoff connection but closes
        // it immediately without ever completing the manifest/fd
        // exchange or sending an ack -- standing in for a new-daemon
        // process that crashed right after connecting.
        let (offerer_side, receiver_side) = UnixStream::pair().expect("create scratch socketpair");
        drop(receiver_side);

        let result = offer_handoff(&shared, &offerer_side, Duration::from_millis(500));
        assert!(
            result.is_err(),
            "offer_handoff must report failure when the receiver never acks, got {result:?}"
        );

        let state = shared.lock_state();
        assert!(
            state.sessions.contains_key(id),
            "a failed handoff attempt must leave the session attachable on the old daemon"
        );
        assert_eq!(
            state.ledger.get(id).map(|info| info.state),
            Some(SessionState::Running),
            "a failed handoff attempt must not have changed the session's ledger state"
        );
    }

    /// H3 (P6 review, handoff.rs:334 / E#2): if a session's child
    /// exits during the handoff pause window (the poll cycle that
    /// notices PTY EOF can race the very `PauseForHandoff` request
    /// that just detached it), `offer_handoff`'s failure path must not
    /// reinsert a zombie: a `SessionEntry` whose session thread has
    /// already torn down, present in the live registry, with the
    /// ledger still saying `Running`. That entry would hang every
    /// future `Attach` and time out every future `Kill` (5s), needing a
    /// daemon restart to clear.
    ///
    /// Reproduced deterministically (not via a poll-cycle timing race)
    /// by killing the real child after detaching, letting the session
    /// thread's own teardown fully complete, and only then sending a
    /// `PauseForHandoff`: `offer_handoff`'s real failure path treats
    /// both an `Err` reply (caught by the thread's final mailbox
    /// drain) and a timeout (thread already fully exited, no reply
    /// ever) identically by calling `restore_entry`, so either
    /// sub-case reproduces the same bug without needing to win a
    /// nanosecond-scale race.
    #[test]
    fn restore_entry_after_child_exits_during_pause_never_reinserts_a_zombie() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let id = "01J-p6-h3-zombie-restore-test";
        let spec = cat_spec(id);
        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        // Step 1 of a real offer_handoff attempt: detach for handoff.
        let detached = detach_for_handoff(&shared, id)
            .expect("detach_for_handoff should return the live entry");

        // The finding's interleaving: the child exits (EOF) in the
        // same window the pause request is in flight. Killing the
        // real child directly and waiting for it to be fully reaped
        // reaches the identical post-condition (the session thread's
        // teardown has run, its `mine` check saw the entry already
        // gone, and it has reaped the child) without depending on a
        // specific poll-cycle timing.
        nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(pid as i32),
            nix::sys::signal::Signal::SIGKILL,
        )
        .expect("killpg the real donor child");

        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_ok()
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_err(),
            "the killed donor child should be reaped within 3s (test setup precondition); \
             kill(pid, 0) still succeeded"
        );
        // Headroom for the session thread's own final mailbox drain /
        // thread exit to complete right after the reap.
        std::thread::sleep(Duration::from_millis(150));

        // Step 2 of a real offer_handoff attempt: send the pause
        // request to the now-detached (and by now dead-threaded) entry,
        // exactly like offer_handoff's own loop does.
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        detached
            .mailbox
            .send(SessionRequest::PauseForHandoff { reply: reply_tx });
        // `PausedSession` (the `Ok(Ok(_))` payload) has no `Debug` impl
        // (it carries live channel/replay state, not meant for
        // printing); describe the outcome instead of the raw value.
        let pause_result: String = match reply_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Ok(_paused)) => "Ok(Ok(paused))".to_string(),
            Ok(Err(e)) => format!("Ok(Err({e:?}))"),
            Err(e) => format!("Err({e:?})"),
        };

        // Step 3: offer_handoff's real failure path for either arm (an
        // `Err` reply, or a timeout because the thread already fully
        // exited) is to call restore_entry unconditionally.
        restore_entry(&shared, detached);

        let state = shared.lock_state();
        let in_registry = state.sessions.contains_key(id);
        let ledger_state = state.ledger.get(id).map(|info| info.state);
        drop(state);

        let cleanly_gone_or_exited =
            !in_registry && matches!(ledger_state, Some(SessionState::Exited { .. }));
        assert!(
            cleanly_gone_or_exited,
            "a session whose child exited during the handoff pause window must end up \
             cleanly gone from the live registry with an Exited ledger record after a \
             failed pause/restore, never a live-looking zombie entry backed by an \
             already-dead session thread (in_registry={in_registry}, \
             ledger_state={ledger_state:?}, pause_result={pause_result:?})"
        );
    }

    /// P6 fix-batch sweep S2 (`finalize_exited`, handoff.rs:570): H3's
    /// fix flips the ledger to `Exited` for a session whose thread
    /// already tore down during the handoff pause window, but never
    /// deletes that session's on-disk history -- unlike the normal
    /// confirmed-exit teardown path in `session.rs`, which deletes
    /// history before flipping the ledger. `Shared` already exposes
    /// `state_dir`, so `finalize_exited` has everything it needs to do
    /// the same; a history-enabled session finalized this way must not
    /// leak `state_dir/history/<id>.raw` forever (the module doc's
    /// "history survives a daemon crash, not a session's own end"
    /// invariant).
    ///
    /// Reproduced exactly like the H3 test above (real child killed,
    /// its own teardown fully completes, then a stale
    /// `PauseForHandoff` drives `restore_entry` into its
    /// `finalize_exited` branch), with history enabled and a real
    /// on-disk history file present first so its removal is actually
    /// meaningful to assert on.
    #[test]
    fn finalize_exited_removes_history_files_for_a_history_enabled_session() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), true));
        let id = "01J-p6-s2-finalize-exited-history-test";
        let spec = cat_spec(id);
        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        let history_path = tmp.path().join("history").join(format!("{id}.raw"));
        let seed_deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !history_path.exists() && std::time::Instant::now() < seed_deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            history_path.exists(),
            "history file should exist before the finalize_exited path under test"
        );

        // Step 1 of a real offer_handoff attempt: detach for handoff.
        let detached = detach_for_handoff(&shared, id)
            .expect("detach_for_handoff should return the live entry");

        // Same deterministic reproduction as the H3 test above: kill
        // the real child and wait for it to be fully reaped, so the
        // session thread's own teardown (including its history
        // writer's fd close) completes before the stale pause request
        // arrives.
        nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(pid as i32),
            nix::sys::signal::Signal::SIGKILL,
        )
        .expect("killpg the real donor child");

        let reap_deadline = std::time::Instant::now() + Duration::from_secs(3);
        while nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_ok()
            && std::time::Instant::now() < reap_deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_err(),
            "the killed donor child should be reaped within 3s (test setup precondition); \
             kill(pid, 0) still succeeded"
        );
        // Headroom for the session thread's own final mailbox drain /
        // thread exit to complete right after the reap.
        std::thread::sleep(Duration::from_millis(150));

        // Step 2: send the pause request to the now-detached,
        // dead-threaded entry, exactly like offer_handoff's own loop.
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        detached
            .mailbox
            .send(SessionRequest::PauseForHandoff { reply: reply_tx });
        let _ = reply_rx.recv_timeout(Duration::from_secs(2));

        // Step 3: offer_handoff's real failure path -- restore_entry --
        // detects the dead thread (mailbox strong_count == 1) and
        // calls finalize_exited, the function under test.
        restore_entry(&shared, detached);

        let ledger_state = shared.lock_state().ledger.get(id).map(|info| info.state);
        assert!(
            matches!(ledger_state, Some(SessionState::Exited { .. })),
            "finalize_exited must flip the ledger to Exited, got {ledger_state:?}"
        );
        assert!(
            !history_path.exists(),
            "finalize_exited must delete this history-enabled session's on-disk history \
             files (state_dir/history/{id}.raw), the same as the normal teardown path's \
             confirmed-exit branch does; the file is still present at {history_path:?}"
        );
    }

    /// H6 (P6 review, handoff.rs:403 / C+D#4): `offer_handoff` sends
    /// the manifest and fds with no write timeout at all (a read
    /// timeout is only set afterward, for the ack wait). A receiver
    /// that connects and then stalls (never drains its end) must not
    /// freeze `offer_handoff` -- and therefore every paused session --
    /// indefinitely: the send must be bounded, and on that bound
    /// tripping, every paused session must be resumed.
    ///
    /// The peer here is a real, still-connected `UnixStream` that
    /// simply never reads: standing in for a wedged receiver, not a
    /// closed one (a closed peer already fails fast via EPIPE, a
    /// different and already-handled case). To force a real kernel write
    /// to block against it reliably, the offerer socket's send buffer
    /// and the peer socket's receive buffer are both shrunk (via
    /// `SO_SNDBUF`/`SO_RCVBUF`) below the manifest size, so the send
    /// cannot be fully queued with nobody draining the other end. This
    /// is deliberately independent of the replay's own size: a live
    /// `cat` session on this platform's default (canonical-mode) PTY
    /// truncates newline-free input to `MAX_CANON`, so a session's
    /// `render_replay` here is only a couple of KiB, comfortably under
    /// the default 8 KiB AF_UNIX buffer -- shrinking the buffers is the
    /// robust way to guarantee the blocking send this test needs.
    #[test]
    fn offer_handoff_bounds_the_fd_send_with_a_write_timeout_and_resumes_on_stall() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let id = "01J-p6-h6-write-timeout-test";
        let spec = cat_spec(id);
        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        let _kill_on_drop = KillOnDrop(pid);
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        let (offerer_side, peer_side) = UnixStream::pair().expect("create scratch socketpair");
        // peer_side is intentionally never read from and kept open for
        // the whole attempt below (a stalled, not closed, receiver).
        //
        // Shrink both buffers well under the manifest size so the very
        // first manifest write blocks with nobody draining, regardless
        // of how small a real cat session's replay is on this platform
        // (see the doc comment). setsockopt is the only way to reach
        // SO_SNDBUF/SO_RCVBUF from a std UnixStream.
        fn shrink_buf(stream: &UnixStream, opt: libc::c_int) {
            let val: libc::c_int = 256;
            // SAFETY: a plain setsockopt with a valid fd, level, option,
            // and a correctly sized c_int argument.
            let rc = unsafe {
                libc::setsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    opt,
                    &val as *const libc::c_int as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
            assert_eq!(
                rc, 0,
                "setsockopt to shrink the scratch socket buffer should succeed"
            );
        }
        shrink_buf(&offerer_side, libc::SO_SNDBUF);
        shrink_buf(&peer_side, libc::SO_RCVBUF);

        let (result_tx, result_rx) = mpsc::channel();
        let shared_for_thread = Arc::clone(&shared);
        std::thread::spawn(move || {
            let result = offer_handoff(&shared_for_thread, &offerer_side, Duration::from_secs(30));
            let _ = result_tx.send(result);
        });

        match result_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(result) => {
                assert!(
                    result.is_err(),
                    "offer_handoff must report failure when the peer never reads its \
                     manifest/fd send, got {result:?}"
                );
            }
            Err(_) => panic!(
                "offer_handoff did not return within 3s against a peer that connects but \
                 never reads: send_fds has no write timeout, so a stalled/wedged receiver \
                 freezes every paused session indefinitely (H6)"
            ),
        }

        let state = shared.lock_state();
        assert!(
            state.sessions.contains_key(id),
            "a stalled handoff send must resume the paused session back into the live \
             registry (resume_all), not leave it parked forever"
        );
        drop(state);
        drop(peer_side);
    }

    /// H7 (P6 review, session.rs:244 / A#? + C+D#3): an adopted
    /// session's `reap` cannot `waitpid` its process (it was never this
    /// daemon's own child), so it degrades to polling `kill(pid, 0)`
    /// for up to the adopted-exit liveness-poll bound after PTY EOF.
    /// Today it returns the same `-1` exit code whether the process is
    /// confirmed gone (`ESRCH`) or merely still alive when the poll
    /// bound elapses -- and the caller unconditionally flips the
    /// ledger to `Exited` and (earlier still, unconditionally on
    /// `mine && history_enabled`, *before* `reap` is even called)
    /// deletes the session's history. A process that only detached
    /// from its PTY without exiting must not lose its Running record
    /// or its history this way: there would be no way left to kill or
    /// reattach it.
    ///
    /// Deterministic by construction, no PTY involved at all:
    ///
    /// - The "master" fd `adopt_session` is handed is one end of a
    ///   plain `pipe()`, not a PTY. `adopt_session`/the session
    ///   thread's read loop are fd-type-agnostic (plain `fcntl` +
    ///   `poll` + `read`; PTY-only operations like `TIOCSWINSZ` only
    ///   fire on a `Resize` request, never sent here), so this reaches
    ///   the exact same code path a real adopted session would. It
    ///   sidesteps the platform-specific PTY hangup quirk entirely (a
    ///   session leader closing its own tty-referencing fds does *not*
    ///   generate a master-side EOF while it stays alive on this
    ///   platform -- verified empirically while developing this test):
    ///   closing this test's own write end of the pipe generates a
    ///   real, instant `Ok(0)` EOF on the read side, deterministically,
    ///   with no session-leader/controlling-terminal semantics
    ///   involved.
    /// - The manifest's `pid` is a separate sentinel process (`sleep
    ///   30`, confirmed alive throughout) wholly unrelated to the
    ///   pipe -- exactly mirroring the real bug surface
    ///   (`SessionChild::Adopted`'s `reap` only ever has a bare `pid`
    ///   value to poll, with no way to verify it still names the
    ///   process that actually owned the terminal; the module doc's
    ///   "known limitation").
    /// - `session::set_adopted_exit_poll_for_test` shrinks the 5s
    ///   liveness-poll bound to 50ms for this test only (guard-scoped,
    ///   restored on drop), so the whole test runs in well under a
    ///   second instead of needing to sleep past a real 5s bound.
    #[test]
    fn adopted_reap_does_not_flip_ledger_or_delete_history_when_still_alive_at_poll_timeout() {
        let _poll_override =
            crate::session::set_adopted_exit_poll_for_test(Duration::from_millis(50));

        let mut donor_terminal = vt::Terminal::new(80, 24, 8 * 1024 * 1024)
            .expect("create scratch terminal for replay bytes");
        donor_terminal
            .feed(b"H7_PRE_ADOPT_MARKER\r\n")
            .expect("feed marker into scratch terminal");
        let replay_bytes = donor_terminal
            .render_replay()
            .expect("render_replay on scratch terminal");

        // Stands in for the SCM_RIGHTS-received PTY master fd: only
        // its read end travels into adopt_session; this test keeps the
        // write end so it can produce EOF (via a plain close) at a
        // moment of its own choosing, deterministically.
        let (master_read, master_write) =
            nix::unistd::pipe().expect("create scratch pipe standing in for the PTY master fd");
        // CLOEXEC on both ends immediately, mirroring spawn_session's
        // own openpty fds: without it, a *different* test's
        // concurrently-forked child (this test binary runs tests in
        // parallel by default) can inherit master_write and keep it
        // open in a process this test knows nothing about, so this
        // test's own close of its write end would never actually drop
        // the pipe's last reference and EOF would never arrive.
        for fd in [&master_read, &master_write] {
            nix::fcntl::fcntl(
                fd.as_fd(),
                nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
            )
            .expect("set scratch pipe fd cloexec");
        }

        // A sentinel process wholly unrelated to the pipe, confirmed
        // alive for the whole test: stands in for the manifest's `pid`
        // field (see the doc comment above).
        let mut sentinel = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sentinel process");
        let sentinel_pid = sentinel.id();

        let manifest_entry = HandoffSessionEntry {
            id: "01J-p6-h7-adopt-test".to_string(),
            name: None,
            cwd: None,
            created_at_ms: 0,
            pid: sentinel_pid,
            meta: BTreeMap::new(),
            cols: 80,
            rows: 24,
            replay: replay_bytes,
        };

        let receiver_tmp = tempfile::tempdir().expect("scratch state dir for receiver");
        // History enabled for this id (a file already present, as a
        // real Live Handoff continuation would find), so history
        // deletion is actually meaningful to assert on: adopt_session
        // derives history_enabled from history::has_persisted.
        let history_dir = receiver_tmp.path().join("history");
        std::fs::create_dir_all(&history_dir).expect("create scratch history dir");
        let history_path = history_dir.join(format!("{}.raw", manifest_entry.id));
        std::fs::write(&history_path, b"pre-handoff-history-bytes\n")
            .expect("seed a pre-existing history file for the adopted id");

        let receiver_shared = Arc::new(Shared::new(receiver_tmp.path().to_path_buf(), false));

        let id = manifest_entry.id.clone();
        let adopted = adopt_session(&receiver_shared, manifest_entry, master_read).expect(
            "adopt_session should construct a running session from a manifest entry + \
             inherited fd",
        );
        {
            let mut state = receiver_shared.lock_state();
            state.ledger.insert(adopted.id.clone(), adopted.info());
            state.sessions.insert(adopted.id.clone(), adopted);
        }

        // Produce a real, instant EOF on the adopted thread's read
        // side: this is the only thing that starts its teardown.
        drop(master_write);

        // Bounded wait comfortably longer than the overridden 50ms
        // poll bound, for the whole teardown (EOF -> history delete ->
        // reap's now-short poll -> ledger flip) to run to completion.
        std::thread::sleep(Duration::from_millis(500));

        // Test-setup precondition: the sentinel (the manifest's `pid`)
        // must still be genuinely alive right now (it is sleeping for
        // up to 30s total), so this really exercises the "poll timed
        // out while still alive" branch, not a coincidental real exit.
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(sentinel_pid as i32), None).is_ok(),
            "the sentinel process must still be alive when the ledger/history are checked \
             (test setup precondition)"
        );

        let ledger_state = receiver_shared
            .lock_state()
            .ledger
            .get(&id)
            .map(|info| info.state);
        let history_still_present = history_path.exists();

        let _ = sentinel.kill();
        let _ = sentinel.wait();

        assert!(
            !matches!(ledger_state, Some(SessionState::Exited { .. })),
            "an adopted session must not be flipped to Exited when its process is \
             confirmed still alive after the adopted-exit liveness-poll bound elapses \
             (kill(pid, 0) still succeeds), got ledger state {ledger_state:?}"
        );
        assert!(
            history_still_present,
            "an adopted session's history file must not be deleted when its process is \
             confirmed still alive after the adopted-exit liveness-poll bound elapses"
        );
    }

    /// P6 fix-batch sweep S1, part (a) -- the most severe defect the H7
    /// fix introduced (session.rs:963, teardown's "Teardown, in a
    /// deliberate order" comment, step 1): H7 (the test directly above)
    /// only stopped `reap == None` from *lying* about a still-alive
    /// adopted process (flipping the ledger to `Exited` and deleting
    /// its history); it did not stop the registry-entry removal one
    /// step *earlier* in that same teardown, which runs unconditionally
    /// -- before `reap` is even called, regardless of what it later
    /// returns. The combination is a permanent, unreachable ghost:
    /// `state.sessions` no longer has the entry (so `Kill`, which only
    /// consults that map, reports no-such-session outside a handoff
    /// window and can never signal the real process again) while the
    /// ledger stays `Running` forever (so `ls` reports it as live, and
    /// nothing short of a daemon restart clears it -- there is no gc,
    /// and nothing ever re-polls this pid again once this thread's
    /// function returns).
    ///
    /// Contract pinned here (the "stronger" S1 option, chosen so `Kill`
    /// stays meaningful without a new `SessionState` variant): a
    /// still-alive-at-the-poll-bound adopted session's registry entry
    /// must *survive* teardown. See the sibling test below for the
    /// other half of the contract (the process is later reconciled to
    /// `Exited` once it actually dies, rather than sitting registered
    /// forever with no way to notice that death).
    ///
    /// Setup mirrors the H7 test directly above (pipe-as-master-fd
    /// trick for a deterministic instant EOF, a `sleep 30` sentinel
    /// process standing in for the manifest's `pid`, and the
    /// 50ms-poll-bound test override) -- see that test's doc comment
    /// for why each of those is deterministic and platform-safe.
    #[test]
    fn adopted_reap_timeout_ghost_stays_registered_instead_of_becoming_an_unreachable_running_entry(
    ) {
        let _poll_override =
            crate::session::set_adopted_exit_poll_for_test(Duration::from_millis(50));

        let (master_read, master_write) =
            nix::unistd::pipe().expect("create scratch pipe standing in for the PTY master fd");
        for fd in [&master_read, &master_write] {
            nix::fcntl::fcntl(
                fd.as_fd(),
                nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
            )
            .expect("set scratch pipe fd cloexec");
        }

        let mut sentinel = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sentinel process");
        let sentinel_pid = sentinel.id();

        let manifest_entry = HandoffSessionEntry {
            id: "01J-p6-s1-ghost-registered-test".to_string(),
            name: None,
            cwd: None,
            created_at_ms: 0,
            pid: sentinel_pid,
            meta: BTreeMap::new(),
            cols: 80,
            rows: 24,
            replay: vec![],
        };

        let receiver_tmp = tempfile::tempdir().expect("scratch state dir for receiver");
        let receiver_shared = Arc::new(Shared::new(receiver_tmp.path().to_path_buf(), false));

        let id = manifest_entry.id.clone();
        let adopted = adopt_session(&receiver_shared, manifest_entry, master_read).expect(
            "adopt_session should construct a running session from a manifest entry + \
             inherited fd",
        );
        {
            let mut state = receiver_shared.lock_state();
            state.ledger.insert(adopted.id.clone(), adopted.info());
            state.sessions.insert(adopted.id.clone(), adopted);
        }

        // Real, instant EOF on the adopted thread's read side: the
        // only thing that starts its teardown.
        drop(master_write);

        // Comfortably longer than the overridden 50ms poll bound, for
        // the whole teardown (EOF -> reap's short poll -> post-reap
        // handling) to run to completion.
        std::thread::sleep(Duration::from_millis(500));

        // Test-setup precondition: the sentinel must still be
        // genuinely alive right now, so this really exercises "poll
        // timed out while still alive", not a coincidental real exit.
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(sentinel_pid as i32), None).is_ok(),
            "the sentinel process must still be alive when the registry is checked (test \
             setup precondition)"
        );

        let (still_registered, ledger_state) = {
            let state = receiver_shared.lock_state();
            (
                state.sessions.contains_key(&id),
                state.ledger.get(&id).map(|info| info.state),
            )
        };

        let _ = sentinel.kill();
        let _ = sentinel.wait();

        assert!(
            still_registered,
            "an adopted session still alive at its liveness-poll bound must keep its \
             registry entry (state.sessions) through teardown, so a later Kill can still \
             reach the real process; teardown currently removes the entry unconditionally \
             before reap even runs, leaving an unreachable Running ghost \
             (still_registered=false, ledger_state={ledger_state:?})"
        );
    }

    /// P6 fix-batch sweep S1, part (b): the other half of the contract
    /// pinned by the test directly above. Keeping the registry entry
    /// registered is not enough on its own -- nothing currently ever
    /// re-checks an adopted-and-still-alive pid again once its session
    /// thread's function returns, so without a reconciliation path a
    /// "kept" ghost would simply stay `Running` forever too, just a
    /// *registered* one instead of an unregistered one. A still-alive
    /// adopted session that later actually exits must reach a clean
    /// `Exited` state (history removed if enabled, ledger flipped,
    /// registry entry removed) -- not remain stuck.
    ///
    /// This calls `reconcile_adopted_ghost` directly and
    /// deterministically (a single re-poll pass) rather than sleeping
    /// past some assumed background-loop interval, because that
    /// interval is an implementation detail this test must not guess
    /// at. **`reconcile_adopted_ghost` does not exist yet** -- this is
    /// a deliberate compile-time RED for the reconciliation half of S1,
    /// which needs new production machinery (part (a) above is a
    /// pure runtime assertion and needs none). Proposed contract for
    /// `GREEN`, mirroring `session.rs` teardown's own confirmed-exit
    /// branch and `finalize_exited`'s -1 sentinel:
    ///
    /// `pub(crate) fn reconcile_adopted_ghost(shared: &Arc<Shared>, id: &str) -> bool`
    ///
    /// Looks up a still-registered entry for `id`, and if its `pid` is
    /// now confirmed gone (`kill(pid, 0)` returns `ESRCH`): deletes its
    /// history (if any is persisted for `id`), flips its ledger record
    /// to `Exited { code: -1 }`, removes the registry entry, and
    /// returns `true`. Returns `false` if there is nothing to do
    /// (missing, or still alive). Intended to be driven by whatever the
    /// implementer chooses -- a periodic background pass, or an
    /// opportunistic check the next time `Kill`/`List` touches this id
    /// -- this test does not assume which.
    #[test]
    fn adopted_reap_timeout_ghost_is_reconciled_to_exited_once_the_process_actually_dies() {
        let _poll_override =
            crate::session::set_adopted_exit_poll_for_test(Duration::from_millis(50));

        let (master_read, master_write) =
            nix::unistd::pipe().expect("create scratch pipe standing in for the PTY master fd");
        for fd in [&master_read, &master_write] {
            nix::fcntl::fcntl(
                fd.as_fd(),
                nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
            )
            .expect("set scratch pipe fd cloexec");
        }

        let mut sentinel = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sentinel process");
        let sentinel_pid = sentinel.id();

        let manifest_entry = HandoffSessionEntry {
            id: "01J-p6-s1-ghost-reconcile-test".to_string(),
            name: None,
            cwd: None,
            created_at_ms: 0,
            pid: sentinel_pid,
            meta: BTreeMap::new(),
            cols: 80,
            rows: 24,
            replay: vec![],
        };

        let receiver_tmp = tempfile::tempdir().expect("scratch state dir for receiver");
        // History enabled + pre-seeded, so its removal on eventual
        // reconciliation is actually meaningful to assert on (mirrors
        // the H7 test's own history setup).
        let history_dir = receiver_tmp.path().join("history");
        std::fs::create_dir_all(&history_dir).expect("create scratch history dir");
        let history_path = history_dir.join(format!("{}.raw", manifest_entry.id));
        std::fs::write(&history_path, b"pre-handoff-history-bytes\n")
            .expect("seed a pre-existing history file for the adopted id");

        let receiver_shared = Arc::new(Shared::new(receiver_tmp.path().to_path_buf(), false));

        let id = manifest_entry.id.clone();
        let adopted = adopt_session(&receiver_shared, manifest_entry, master_read).expect(
            "adopt_session should construct a running session from a manifest entry + \
             inherited fd",
        );
        {
            let mut state = receiver_shared.lock_state();
            state.ledger.insert(adopted.id.clone(), adopted.info());
            state.sessions.insert(adopted.id.clone(), adopted);
        }

        drop(master_write);
        std::thread::sleep(Duration::from_millis(500));
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(sentinel_pid as i32), None).is_ok(),
            "the sentinel process must still be alive right after teardown (test setup \
             precondition)"
        );

        // Now make it really exit, and confirm that for real (ESRCH),
        // so this test exercises actual reconciliation, not a
        // coincidence.
        let _ = sentinel.kill();
        let _ = sentinel.wait();
        let dead_deadline = std::time::Instant::now() + Duration::from_secs(3);
        while nix::sys::signal::kill(nix::unistd::Pid::from_raw(sentinel_pid as i32), None).is_ok()
            && std::time::Instant::now() < dead_deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(sentinel_pid as i32), None).is_err(),
            "the sentinel must be confirmed dead before reconciliation is checked (test \
             setup precondition)"
        );

        let finalized = reconcile_adopted_ghost(&receiver_shared, &id);

        assert!(
            finalized,
            "reconcile_adopted_ghost must report that it finalized a still-registered \
             ghost entry whose process is now confirmed dead"
        );
        let (still_registered, ledger_state) = {
            let state = receiver_shared.lock_state();
            (
                state.sessions.contains_key(&id),
                state.ledger.get(&id).map(|info| info.state),
            )
        };
        assert!(
            !still_registered,
            "a reconciled ghost must be removed from the live registry"
        );
        assert!(
            matches!(ledger_state, Some(SessionState::Exited { .. })),
            "a reconciled ghost's ledger record must flip to Exited, got {ledger_state:?}"
        );
        assert!(
            !history_path.exists(),
            "a reconciled ghost's on-disk history must be removed the same way a normal \
             confirmed exit removes it"
        );
    }

    /// P6 review E5, R2: `offer_handoff` must transfer the
    /// single-daemon lock fd through the same `SCM_RIGHTS` batch as
    /// the control listener, so a fixed receiver can adopt it as its
    /// own hold instead of separately re-acquiring one the old daemon
    /// cannot yet release (see `crate::lib`'s own `#[cfg(test)]`
    /// module for R3's receiver-side test, and `crate::fdpass`'s for
    /// R1's empirical flock/`SCM_RIGHTS` check). Wire order is pinned
    /// here: sessions, then the listener, then the lock fd last -- one
    /// fd more than today.
    ///
    /// No live sessions in this manifest (R2 is about the
    /// listener/lock tail, not adoption content): with a `HandoffEnv`
    /// installed carrying both a listener and a lock fd,
    /// `offer_handoff` should send exactly 2 fds. It does not yet read
    /// `HandoffEnv::lock` at all (only `HandoffEnv::listener`), so
    /// today it sends exactly 1.
    #[test]
    fn offer_handoff_sends_the_single_daemon_lock_fd_alongside_the_listener() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));

        let listener_stand_in = UnixListener::bind(tmp.path().join("control-stand-in.sock"))
            .expect("bind stand-in control listener");
        let listener_fd = listener_stand_in
            .as_fd()
            .try_clone_to_owned()
            .expect("dup stand-in control listener");

        let lock_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(tmp.path().join("lock-stand-in"))
            .expect("create scratch lock file stand-in");
        let lock_fd = lock_file
            .as_fd()
            .try_clone_to_owned()
            .expect("dup scratch lock file stand-in");

        *lock_unpoisoned(&shared.handoff_env) = Some(HandoffEnv {
            runtime_dir: tmp.path().to_path_buf(),
            listener: listener_fd,
            lock: Some(lock_fd),
        });

        let (offerer_side, receiver_side) = UnixStream::pair()
            .expect("create scratch socketpair standing in for the handoff channel");

        let shared_for_thread = Arc::clone(&shared);
        let offer_thread = std::thread::spawn(move || {
            // Short ack timeout: this test never sends one back, and
            // R2 only cares about what was sent, not offer_handoff's
            // eventual (here, timeout) return value.
            offer_handoff(
                &shared_for_thread,
                &offerer_side,
                Duration::from_millis(200),
            )
        });

        let (_sidecar, fds) = fdpass::recv_fds(&receiver_side, MAX_HANDOFF_FDS)
            .expect("recv_fds should receive offer_handoff's manifest and fds");

        let _ = offer_thread
            .join()
            .expect("the offer_handoff thread must not panic");

        assert_eq!(
            fds.len(),
            2,
            "offer_handoff with 0 live sessions and a HandoffEnv carrying both a \
             listener and a lock fd should send exactly 2 fds (the listener plus the \
             single-daemon lock fd, P6 review E5); got {} -- offer_handoff does not yet \
             read HandoffEnv::lock at all, only HandoffEnv::listener",
            fds.len()
        );
    }
}
