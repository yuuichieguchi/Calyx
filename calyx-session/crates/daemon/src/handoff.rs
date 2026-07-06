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
//!    (and its own listener fd) to the new daemon via `crate::fdpass`,
//!    fd order matching `HandoffManifest::sessions` order.
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

use crate::error::DaemonError;
use crate::fdpass;
use crate::history;
use crate::outq::{lock_unpoisoned, OutQueue};
use crate::session::{
    make_wake_pipe, start_session_thread, PausedSession, SessionChild, SessionInput,
    SessionMailbox, SessionRequest, SessionThread,
};
use crate::state::{SessionEntry, Shared};

/// The single byte the receiving daemon writes back on the handoff
/// stream once every session is adopted and the transferred listener
/// is armed: the old daemon's point of no return (module doc).
pub(crate) const HANDOFF_ACK: u8 = 0x06;

/// Upper bound on fds in one handoff (sessions + the control
/// listener), used to size the receiver's `SCM_RIGHTS` buffer. 253 is
/// Linux's per-message `SCM_MAX_FD`; staying at it keeps the protocol
/// portable, and a daemon with more live sessions than that simply
/// cannot hand off (EXPERIMENTAL limitation).
pub(crate) const MAX_HANDOFF_FDS: usize = 253;

/// How long `offer_handoff` waits for each session thread to
/// acknowledge its pause: bounded so a wedged (or already-exited)
/// session thread fails the attempt instead of hanging the daemon.
const PAUSE_REPLY_TIMEOUT: Duration = Duration::from_secs(5);

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
            Ok(Err(e)) => {
                // This entry never parked (the thread replied Err
                // instead), so it only needs re-inserting.
                restore_entry(shared, entry);
                resume_all(shared, candidates);
                return Err(format!("pausing session {id:?} failed: {e}"));
            }
            Err(_) => {
                // The thread never replied. Its stale pause request
                // can no longer park it: the reply sender is dropped
                // here, and the session thread only parks after a
                // successful reply send.
                restore_entry(shared, entry);
                resume_all(shared, candidates);
                return Err(format!(
                    "session {id:?} did not acknowledge the handoff pause within \
                     {PAUSE_REPLY_TIMEOUT:?}"
                ));
            }
        }
    }

    // Manifest and fds in matching order (module doc contract); the
    // control listener travels last so the receiver can take over
    // accepting with no unbind/rebind gap. It is absent only where no
    // serving listener was installed (unit-test contexts).
    let mut sessions = Vec::with_capacity(candidates.len());
    let mut fds: Vec<RawFd> = Vec::with_capacity(candidates.len() + 1);
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

    let manifest = HandoffManifest { sessions };
    let sidecar = match encode_manifest(&manifest) {
        Ok(bytes) => bytes,
        Err(e) => {
            resume_all(shared, candidates);
            return Err(format!("encoding handoff manifest failed: {e}"));
        }
    };
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

/// Failure-path half of `detach_for_handoff`: puts a (non-parked)
/// entry back into the live registry.
fn restore_entry(shared: &Arc<Shared>, entry: SessionEntry) {
    let mut state = shared.lock_state();
    state.sessions.insert(entry.id.clone(), entry);
    state.touch();
    shared.cond.notify_all();
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
}
