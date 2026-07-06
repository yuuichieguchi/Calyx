//! One PTY session: spawn (openpty + fork/exec via `Command`), and the
//! session thread that owns the master fd, the child, and the
//! `vt::Terminal`.
//!
//! Single-thread ownership of the terminal is load-bearing twice over:
//! `vt::Terminal` is `!Send` (unverified thread affinity, see the vt
//! crate), and serializing feeds with attach handling on one thread is
//! what makes the attach snapshot atomic — a `Replay` frame rendered
//! here can neither miss bytes already fed nor overlap with `Output`
//! frames mirrored afterwards, because both happen on this thread in
//! program order. Client-bound ordering is therefore: `AttachOk`, then
//! one `Replay` snapshot, then only `Output` bytes produced after that
//! snapshot.
//!
//! "The feed path never blocks" is the second invariant: everything
//! the session thread does between two PTY reads — `OutQueue::push`,
//! `SessionInput::submit` (used by the query responder), vt feeds —
//! is non-blocking by construction.

use std::collections::VecDeque;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use nix::pty::Winsize;
use proto::{encode_control, ControlMsg, FrameType, SessionEvent, SessionSpec, SessionState};

use crate::history;
use crate::outq::{lock_unpoisoned, OutQueue};
use crate::state::{SessionEntry, Shared};

/// Scrollback byte budget per session's `vt::Terminal`.
const SCROLLBACK_BYTES: u32 = 8 * 1024 * 1024;

/// How long an attached client's connection stays open after its
/// session's Exited event, so quick follow-ups (a `ListAll` for the
/// exit record, say) still work, while an abandoned connection is
/// still reclaimed promptly (it would otherwise pin `total_clients`
/// and keep the daemon from ever reaching its idle exit).
const EXIT_CLOSE_GRACE: std::time::Duration = std::time::Duration::from_secs(1);

pub(crate) enum SessionRequest {
    /// Register a new attached client. Handled on the session thread:
    /// render replay -> enqueue `Replay` -> start mirroring, all
    /// between two feeds (the snapshot-ordering guarantee).
    Attach { conn_id: u64, queue: Arc<OutQueue> },
    /// Drop a client from the mirror list (detach or disconnect).
    Remove { conn_id: u64 },
    /// Set the PTY and terminal size (last writer wins).
    Resize { cols: u16, rows: u16 },
    /// No-op: wakes the session thread so it re-evaluates pending
    /// input (POLLOUT interest) after a `SessionInput::submit`.
    Pump,
    /// Live Handoff pause (see `crate::handoff`): render a replay
    /// snapshot on this thread (which makes it atomic with the pause),
    /// reply, then park with no further PTY reads until the returned
    /// `PausedSession::resume_tx` fires or is dropped. Only ever sent
    /// by `handoff::offer_handoff`.
    PauseForHandoff {
        reply: mpsc::SyncSender<Result<PausedSession, String>>,
    },
}

/// A session parked for Live Handoff: `SessionRequest::PauseForHandoff`'s
/// successful reply. Dropping `resume_tx` without sending resumes the
/// session thread, so an offerer that dies mid-attempt (early return,
/// panic) can never leave a session parked forever; the handoff success
/// path must therefore `mem::forget` this to keep the old thread parked
/// through the process's `_exit` (see `handoff::offer_handoff`).
pub(crate) struct PausedSession {
    /// `vt::Terminal::render_replay` output at the moment of pausing.
    pub(crate) replay: Vec<u8>,
    /// Terminal geometry in effect at the moment of pausing (tracks
    /// `Resize` requests, not the creation-time size).
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) resume_tx: mpsc::SyncSender<()>,
}

/// Request channel into a session thread, woken via a self-pipe so the
/// thread can block in `poll` on the PTY and still react to requests.
pub(crate) struct SessionMailbox {
    requests: Mutex<VecDeque<SessionRequest>>,
    pub(crate) wake_tx: OwnedFd,
}

impl SessionMailbox {
    pub(crate) fn new(wake_tx: OwnedFd) -> SessionMailbox {
        SessionMailbox {
            requests: Mutex::new(VecDeque::new()),
            wake_tx,
        }
    }

    pub(crate) fn send(&self, request: SessionRequest) {
        lock_unpoisoned(&self.requests).push_back(request);
        // A full pipe already guarantees a pending wakeup, and a closed
        // read end means the session thread is gone and will never look
        // at the mailbox again; both make this write's failure ignorable.
        let _ = nix::unistd::write(self.wake_tx.as_fd(), &[1u8]);
    }
}

/// Upper bound on `SessionInput::pending` (P2 final review, should-fix:
/// currently unenforced — see `submit`). A client sending `Input` to a
/// session whose child never reads its stdin (see the `input_blocking`
/// daemon integration test) can otherwise grow this buffer without
/// bound, since nothing here drains it either. The exact value is an
/// implementation choice; tests reference this constant rather than a
/// hardcoded byte count so changing it doesn't require touching them.
pub(crate) const SESSION_INPUT_MAX_BYTES: usize = 8 * 1024 * 1024;

/// Bytes on their way to the child's stdin (client `Input` frames and
/// query-responder replies), buffered so no producer ever blocks on
/// the PTY. The master fd is `O_NONBLOCK`; writers drain
/// opportunistically and the session thread finishes the job via
/// POLLOUT once the tty input queue has room again.
pub(crate) struct SessionInput {
    pending: Mutex<VecDeque<u8>>,
}

impl SessionInput {
    pub(crate) fn new() -> Arc<SessionInput> {
        Arc::new(SessionInput {
            pending: Mutex::new(VecDeque::new()),
        })
    }

    /// Appends `bytes` and opportunistically drains to `fd` without
    /// ever blocking. Ordering across producers is the mutex's FIFO.
    ///
    /// Returns whether `bytes` was accepted: `false` (leaving
    /// `pending` unchanged) once the undrained backlog would exceed
    /// `SESSION_INPUT_MAX_BYTES` even after a drain attempt, so the
    /// caller can disconnect or drop instead of buffering forever.
    pub(crate) fn submit(&self, fd: &OwnedFd, bytes: &[u8]) -> bool {
        let mut pending = lock_unpoisoned(&self.pending);
        if pending.len() + bytes.len() > SESSION_INPUT_MAX_BYTES {
            // Try to make room first: the tty may have drained since
            // the session thread last pumped.
            drain_nonblocking(&mut pending, fd.as_fd());
            if pending.len() + bytes.len() > SESSION_INPUT_MAX_BYTES {
                return false;
            }
        }
        pending.extend(bytes);
        drain_nonblocking(&mut pending, fd.as_fd());
        true
    }

    /// Drains what the tty will accept; returns whether bytes remain
    /// (i.e. whether the caller should keep POLLOUT interest).
    fn pump(&self, fd: BorrowedFd) -> bool {
        let mut pending = lock_unpoisoned(&self.pending);
        drain_nonblocking(&mut pending, fd);
        !pending.is_empty()
    }

    fn has_pending(&self) -> bool {
        !lock_unpoisoned(&self.pending).is_empty()
    }
}

/// Writes the buffer's contiguous prefix until the (nonblocking) fd
/// stops accepting. EIO/EPIPE mean the child is gone: pending input is
/// meaningless then and is discarded, with teardown already in flight
/// via the session thread's PTY EOF.
fn drain_nonblocking(pending: &mut VecDeque<u8>, fd: BorrowedFd) {
    loop {
        let (front, _) = pending.as_slices();
        if front.is_empty() {
            break;
        }
        match nix::unistd::write(fd, front) {
            Ok(0) => break,
            Ok(n) => {
                pending.drain(..n);
            }
            Err(nix::errno::Errno::EINTR) => continue,
            Err(nix::errno::Errno::EAGAIN) => break,
            Err(_) => {
                pending.clear();
                break;
            }
        }
    }
}

/// The process on the far side of a session's PTY, as seen by this
/// daemon: either a child it forked itself, or a process inherited via
/// Live Handoff (see `crate::handoff`) that some previous daemon
/// generation forked.
pub(crate) enum SessionChild {
    /// Forked by this process: a real `waitpid` status is available.
    Forked(Child),
    /// Adopted via Live Handoff: not this process's child, so no
    /// `waitpid` is possible and exit detection degrades to liveness
    /// polling (the handoff module doc's known limitation).
    Adopted { pid: u32 },
}

/// Upper bound on the adopted-session liveness poll after PTY EOF: the
/// terminal side has already ended at that point, so a process that
/// merely closed its tty and lives on must not stall teardown forever.
const ADOPTED_EXIT_POLL: std::time::Duration = std::time::Duration::from_secs(5);

impl SessionChild {
    /// Best-effort abort when the session thread fails before its main
    /// loop (terminal init). A forked child is this daemon's to kill
    /// and reap; an adopted process is deliberately left untouched:
    /// adoption failure happens before the handoff ack, so the sending
    /// daemon still owns that session and will resume it (see
    /// `crate::handoff`'s point-of-no-return contract).
    fn abort_before_loop(&mut self) {
        match self {
            SessionChild::Forked(child) => {
                let _ = child.kill();
                let _ = child.wait();
            }
            SessionChild::Adopted { .. } => {}
        }
    }

    /// Waits out the child's end and returns the exit code to record
    /// in the ledger.
    fn reap(&mut self, id: &str) -> i32 {
        match self {
            SessionChild::Forked(child) => match child.wait() {
                Ok(status) => status
                    .code()
                    .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
                Err(e) => {
                    eprintln!("calyx-sessiond: waitpid failed for {id}: {e}");
                    -1
                }
            },
            SessionChild::Adopted { pid } => {
                // Known limitation (crate::handoff module doc): this
                // daemon never forked `pid`, so there is no status to
                // collect. Poll liveness until the process is gone or
                // the bound elapses, then record the unknowable exit
                // code as -1, the same value the waitpid-failure path
                // above uses.
                let deadline = std::time::Instant::now() + ADOPTED_EXIT_POLL;
                let pid = nix::unistd::Pid::from_raw(*pid as i32);
                while nix::sys::signal::kill(pid, None).is_ok()
                    && std::time::Instant::now() < deadline
                {
                    thread::sleep(std::time::Duration::from_millis(20));
                }
                -1
            }
        }
    }
}

/// Nonblocking, CLOEXEC self-pipe for a session mailbox. macOS has no
/// `pipe2`, so both flags are applied after the fact; the (tiny) fork
/// window in between is accepted on this platform.
pub(crate) fn make_wake_pipe() -> Result<(OwnedFd, OwnedFd), String> {
    let (wake_rx, wake_tx) = nix::unistd::pipe().map_err(|e| format!("pipe failed: {e}"))?;
    for fd in [&wake_rx, &wake_tx] {
        nix::fcntl::fcntl(
            fd.as_fd(),
            nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .map_err(|e| format!("set wake pipe nonblocking: {e}"))?;
        nix::fcntl::fcntl(
            fd.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )
        .map_err(|e| format!("set wake pipe cloexec: {e}"))?;
    }
    Ok((wake_rx, wake_tx))
}

/// Spawns the session thread for `ctx` and waits for its terminal to
/// initialize. The `vt::Terminal` can only be created on the session
/// thread (`!Send`), so creation failure is only observable through
/// the ready channel; waiting here means no caller ever reports a
/// half-alive session.
pub(crate) fn start_session_thread(
    ctx: SessionThread,
    ready_rx: mpsc::Receiver<Result<(), String>>,
) -> Result<(), String> {
    let name = format!("session-{}", ctx.id);
    thread::Builder::new()
        .name(name)
        .spawn(move || session_thread(ctx))
        .map_err(|e| format!("spawn session thread: {e}"))?;
    match ready_rx.recv() {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(format!("terminal init failed: {e}")),
        Err(_) => Err("session thread died during startup".to_string()),
    }
}

/// Creates the PTY + child process and starts the session thread.
/// Returns the registry entry for it, or an error string suitable for
/// a `ControlMsg::Err` reply.
///
/// The session thread idles at a start gate until the caller decides
/// the entry's fate: `SessionEntry::release_start` (registered, run) or
/// dropping the entry (create-race loser / caller failure, run against
/// a killed child). Either way the thread only reaches its teardown —
/// which removes the registry entry *it* belongs to, never a
/// same-id successor's — after the registration decision, closing the
/// insert/remove interleavings that could otherwise leave a zombie
/// entry or delete a racing winner's.
pub(crate) fn spawn_session(
    shared: &Arc<Shared>,
    spec: &SessionSpec,
) -> Result<SessionEntry, String> {
    let cols = spec.cols.max(1);
    let rows = spec.rows.max(1);
    let winsize = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let pty = nix::pty::openpty(Some(&winsize), None::<&nix::sys::termios::Termios>)
        .map_err(|e| format!("openpty failed: {e}"))?;
    // CLOEXEC on the raw openpty fds immediately (macOS openpty gives
    // plain fds): without it, a concurrently-forked *other* session's
    // child inherits this master and pins the PTY open even after this
    // session dies — enough leaked children keep each other's PTYs
    // alive indefinitely and eventually exhaust kern.tty.ptmx_max.
    // (`Stdio` re-dups the slave for the child's stdio, so the child
    // still gets its own ends; and later `try_clone` dups inherit the
    // flag via F_DUPFD_CLOEXEC.) The fork window between openpty and
    // here is accepted: macOS has no atomic O_CLOEXEC openpty.
    for fd in [&pty.master, &pty.slave] {
        nix::fcntl::fcntl(
            fd.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )
        .map_err(|e| format!("set pty cloexec: {e}"))?;
    }
    // Nonblocking master: shared by this fd and its registry dup (one
    // open file description), so neither input writers nor the query
    // responder can ever block the threads they run on.
    nix::fcntl::fcntl(
        pty.master.as_fd(),
        nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
    )
    .map_err(|e| format!("set pty master nonblocking: {e}"))?;

    let argv: Vec<String> = match &spec.argv {
        Some(argv) if !argv.is_empty() => argv.clone(),
        // Contract: no argv means the user's login shell.
        _ => vec![std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())],
    };

    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    if let Some(cwd) = &spec.cwd {
        cmd.current_dir(cwd);
    }
    for (key, value) in &spec.env {
        cmd.env(key, value);
    }
    // After spec.env on purpose: later `env` calls win for the same
    // key, and the session id must not be spoofable via spec.env.
    cmd.env("CALYX_SESSION_ID", &spec.id);
    let stdin_fd = pty.slave.try_clone().map_err(|e| e.to_string())?;
    let stdout_fd = pty.slave.try_clone().map_err(|e| e.to_string())?;
    cmd.stdin(Stdio::from(stdin_fd));
    cmd.stdout(Stdio::from(stdout_fd));
    cmd.stderr(Stdio::from(pty.slave));
    // SAFETY: the pre_exec closure runs in the forked child before
    // exec and only performs async-signal-safe syscalls (setsid,
    // ioctl); the PTY slave is already dup2'd onto fd 0 by `Command`.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // Inferred cast: ioctl's request parameter is c_ulong on
            // macOS/glibc but c_int on musl, so a concrete cast breaks
            // one platform or the other.
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = cmd
        .spawn()
        .map_err(|e| format!("spawn {:?} failed: {e}", argv[0]))?;
    let pid = child.id();

    let master_input = Arc::new(
        pty.master
            .try_clone()
            .map_err(|e| format!("dup pty master failed: {e}"))?,
    );
    let input = SessionInput::new();

    let (wake_rx, wake_tx) = make_wake_pipe()?;
    let mailbox = Arc::new(SessionMailbox::new(wake_tx));

    let created_at_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
    let (start_tx, start_rx) = mpsc::sync_channel::<()>(1);
    // Read once, here at creation: `SetHistoryEnabled` only changes
    // what *later* creations inherit (R6 semantics; see
    // crate::history's module doc).
    let history_enabled = shared.history_enabled.load(Ordering::SeqCst);
    start_session_thread(
        SessionThread {
            shared: Arc::clone(shared),
            id: spec.id.clone(),
            master: pty.master,
            wake_rx,
            mailbox: Arc::clone(&mailbox),
            input: Arc::clone(&input),
            child: SessionChild::Forked(child),
            cols,
            rows,
            ready_tx,
            start_rx,
            state_dir: shared.state_dir.clone(),
            history_enabled,
            seed_replay: Vec::new(),
        },
        ready_rx,
    )?;

    Ok(SessionEntry {
        id: spec.id.clone(),
        name: spec.name.clone(),
        cwd: spec.cwd.clone(),
        created_at_ms,
        pid,
        meta: std::collections::BTreeMap::new(),
        attached_clients: 0,
        mailbox,
        master_input,
        input,
        start_tx,
    })
}

/// Everything a session thread owns, assembled by `spawn_session` (a
/// forked child) or `handoff::adopt_session` (an inherited one) and
/// consumed by `start_session_thread`.
pub(crate) struct SessionThread {
    pub(crate) shared: Arc<Shared>,
    pub(crate) id: String,
    pub(crate) master: OwnedFd,
    pub(crate) wake_rx: OwnedFd,
    pub(crate) mailbox: Arc<SessionMailbox>,
    pub(crate) input: Arc<SessionInput>,
    pub(crate) child: SessionChild,
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) ready_tx: mpsc::SyncSender<Result<(), String>>,
    pub(crate) start_rx: mpsc::Receiver<()>,
    /// `Shared::state_dir`, cloned at spawn so the history paths need
    /// no registry access from this thread.
    pub(crate) state_dir: PathBuf,
    /// The daemon-wide history flag as captured at this session's
    /// creation (see `spawn_session`); later toggles don't reach here.
    /// For an adopted session, "creation" is its original daemon's:
    /// `handoff::adopt_session` derives this from whether the session
    /// was already persisting (its history file survives the handoff).
    pub(crate) history_enabled: bool,
    /// Live Handoff adoption: replay bytes fed into the fresh terminal
    /// before the loop's first PTY read, so the first `Replay` any
    /// attaching client sees already contains the pre-handoff content.
    /// Empty for a forked session.
    pub(crate) seed_replay: Vec<u8>,
}

fn session_thread(ctx: SessionThread) {
    let SessionThread {
        shared,
        id,
        master,
        wake_rx,
        mailbox,
        input,
        mut child,
        cols,
        rows,
        ready_tx,
        start_rx,
        state_dir,
        history_enabled,
        seed_replay,
    } = ctx;
    let master_raw = master.as_raw_fd();
    let adopted = matches!(child, SessionChild::Adopted { .. });
    // Geometry currently in effect, tracked across Resize requests so
    // a handoff pause can report the size its replay was rendered at.
    let mut cur_cols = cols;
    let mut cur_rows = rows;

    let mut terminal = match vt::Terminal::new(cur_cols, cur_rows, SCROLLBACK_BYTES) {
        Ok(t) => t,
        Err(e) => {
            let _ = ready_tx.send(Err(e.to_string()));
            child.abort_before_loop();
            return;
        }
    };
    let _ = ready_tx.send(Ok(()));

    // Start gate: wait for the registration decision. A closed channel
    // (entry dropped without release: create-race loser, failed
    // caller) means "proceed anyway" — the loop then just reaps the
    // already-killed child and the identity check below keeps its
    // teardown away from any same-id successor's registry entry.
    // `registered` additionally keeps an unregistered thread's hands
    // off the history files: a create-race loser must never seed
    // from, write to, or later delete files a same-id winner owns.
    let registered = start_rx.recv().is_ok();

    // Live Handoff adoption: reconstruct the pre-handoff screen and
    // scrollback before the loop's first PTY read, so the first Replay
    // any attaching client receives already contains it. A feed
    // failure degrades to a blank starting terminal (logged), the same
    // way the crash-restore seed below degrades: the live session is
    // worth more than its catch-up content.
    if !seed_replay.is_empty() {
        if let Err(e) = terminal.feed(&seed_replay) {
            eprintln!("calyx-sessiond: seeding handoff replay failed for {id}: {e}");
        }
    }
    drop(seed_replay);

    // Opt-in history persistence (see crate::history's module doc).
    // Failures on this path are logged and degrade to "no history for
    // this session" rather than tearing the session down: at this
    // point the session is already registered and reported created,
    // so there is no error channel back to the requesting client, and
    // a live session is worth more than its history record.
    let mut history: Option<history::HistoryWriter> = None;
    if registered && history_enabled {
        // Seed-once-then-reset: a leftover file means the previous
        // daemon process died before this id's teardown ran. Feed it
        // into the fresh terminal now, before the loop's first PTY
        // feed, so the first Replay rendered for any attaching client
        // already contains the pre-crash scrollback; then delete the
        // files so the live appends below start from a clean slate.
        //
        // Never for an adopted session: its leftover file means
        // continuation, not a crash (the previous generation's exit
        // deliberately skipped teardown), the handoff replay above is
        // the authoritative snapshot of that same content, and the
        // writer opening in append mode below keeps the file's "what
        // this session's PTY produced" meaning intact across the
        // generation change.
        if !adopted {
            match history::read_persisted(&state_dir, &id) {
                Ok(Some(bytes)) => {
                    if let Err(e) = terminal.feed(&bytes) {
                        eprintln!("calyx-sessiond: seeding persisted history failed for {id}: {e}");
                    }
                    if let Err(e) = history::HistoryWriter::remove_all(&state_dir, &id) {
                        eprintln!(
                            "calyx-sessiond: resetting persisted history failed for {id}: {e}"
                        );
                    }
                }
                Ok(None) => {}
                Err(e) => {
                    eprintln!("calyx-sessiond: reading persisted history failed for {id}: {e}");
                }
            }
        }
        match history::HistoryWriter::open(&state_dir, &id, history::DEFAULT_CAP_BYTES) {
            Ok(writer) => history = Some(writer),
            Err(e) => {
                eprintln!(
                    "calyx-sessiond: opening history for {id} failed, running without \
                     history: {e}"
                );
            }
        }
    }

    struct AttachedClient {
        conn_id: u64,
        queue: Arc<OutQueue>,
    }
    let mut clients: Vec<AttachedClient> = Vec::new();
    // One dup for the responder closure's whole lifetime. If it fails,
    // detached queries go unanswered (logged), which degrades better
    // than refusing to run the session.
    let responder_master: Option<Arc<OwnedFd>> = match master.try_clone() {
        Ok(fd) => Some(Arc::new(fd)),
        Err(e) => {
            eprintln!("calyx-sessiond: dup pty master for responder failed for {id}: {e}");
            None
        }
    };
    // A session starts detached, so queries need answering from the
    // start.
    let mut responder_active = false;
    update_responder(
        &mut terminal,
        clients.is_empty(),
        &input,
        responder_master.as_ref(),
        &mut responder_active,
    );

    let mut buf = [0u8; 8192];
    loop {
        // Requests first: an Attach queued before the next chunk of
        // output must snapshot before that chunk is fed.
        let requests: Vec<SessionRequest> = {
            let mut q = lock_unpoisoned(&mailbox.requests);
            q.drain(..).collect()
        };
        for request in requests {
            match request {
                SessionRequest::Attach { conn_id, queue } => {
                    push_replay(&mut terminal, &queue, &id);
                    clients.push(AttachedClient { conn_id, queue });
                }
                SessionRequest::Remove { conn_id } => {
                    // Only stop mirroring: the connection itself stays
                    // usable (a detached client can list, kill, or
                    // re-attach), so its queue is left open.
                    clients.retain(|client| client.conn_id != conn_id);
                }
                SessionRequest::Resize { cols, rows } => {
                    let winsize = Winsize {
                        ws_row: rows.max(1),
                        ws_col: cols.max(1),
                        ws_xpixel: 0,
                        ws_ypixel: 0,
                    };
                    // SAFETY: master_raw is this thread's live PTY fd.
                    let rc = unsafe {
                        // Inferred cast: request is c_ulong on
                        // macOS/glibc, c_int on musl.
                        libc::ioctl(master_raw, libc::TIOCSWINSZ as _, &winsize)
                    };
                    if rc < 0 {
                        eprintln!(
                            "calyx-sessiond: TIOCSWINSZ failed for {id}: {}",
                            std::io::Error::last_os_error()
                        );
                    }
                    if let Err(e) = terminal.resize(cols.max(1), rows.max(1)) {
                        eprintln!("calyx-sessiond: vt resize failed for {id}: {e}");
                    }
                    cur_cols = cols.max(1);
                    cur_rows = rows.max(1);
                }
                SessionRequest::Pump => {}
                SessionRequest::PauseForHandoff { reply } => {
                    // Snapshot and park on this thread, in that order:
                    // single-thread ownership is what makes the replay
                    // atomic with the pause (no PTY byte can be fed
                    // between them). See crate::handoff's module doc.
                    match terminal.render_replay() {
                        Ok(replay) => {
                            let (resume_tx, resume_rx) = mpsc::sync_channel::<()>(1);
                            let paused = PausedSession {
                                replay,
                                cols: cur_cols,
                                rows: cur_rows,
                                resume_tx,
                            };
                            if reply.send(Ok(paused)).is_ok() {
                                // Parked: no PTY reads until the
                                // offerer's verdict. An explicit send
                                // and a dropped channel both mean
                                // "resume"; only the old process's
                                // post-ack `_exit` leaves this parked
                                // for good (see PausedSession's doc).
                                let _ = resume_rx.recv();
                            }
                        }
                        Err(e) => {
                            let _ =
                                reply.send(Err(format!("render_replay for handoff failed: {e}")));
                        }
                    }
                }
            }
        }
        update_responder(
            &mut terminal,
            clients.is_empty(),
            &input,
            responder_master.as_ref(),
            &mut responder_active,
        );

        let mut master_events = PollFlags::POLLIN;
        if input.has_pending() {
            master_events |= PollFlags::POLLOUT;
        }
        let mut poll_fds = [
            PollFd::new(master.as_fd(), master_events),
            PollFd::new(wake_rx.as_fd(), PollFlags::POLLIN),
        ];
        match poll(&mut poll_fds, PollTimeout::NONE) {
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => {
                eprintln!("calyx-sessiond: poll failed for {id}: {e}");
                break;
            }
        }

        let master_revents = poll_fds[0].revents().unwrap_or(PollFlags::empty());
        let master_readable =
            master_revents.intersects(PollFlags::POLLIN | PollFlags::POLLHUP | PollFlags::POLLERR);
        let master_writable = master_revents.intersects(PollFlags::POLLOUT);
        let wake_ready = poll_fds[1]
            .revents()
            .map(|r| r.intersects(PollFlags::POLLIN))
            .unwrap_or(false);

        if wake_ready {
            // Drain however many wakeup bytes accumulated; requests
            // themselves are picked up at the top of the loop.
            let mut drain = [0u8; 64];
            while let Ok(n) = nix::unistd::read(wake_rx.as_fd(), &mut drain) {
                if n < drain.len() {
                    break;
                }
            }
        }

        if master_writable {
            input.pump(master.as_fd());
        }

        if master_readable {
            match nix::unistd::read(master.as_fd(), &mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = &buf[..n];
                    // This feed must never block: OutQueue::push is
                    // non-blocking by construction, the responder path
                    // is SessionInput::submit (nonblocking fd), and
                    // vt::feed itself is pure computation.
                    if let Err(e) = terminal.feed(chunk) {
                        // Keep mirroring raw output even if state
                        // tracking degraded; replay quality suffers,
                        // live clients shouldn't.
                        eprintln!("calyx-sessiond: vt feed failed for {id}: {e}");
                    }
                    // Append before mirroring, so a client that has
                    // observed some output can rely on those bytes
                    // already being on disk. Plain buffered file I/O
                    // (no fsync), a deliberate exception to this
                    // thread's never-blocks rule, accepted as the cost
                    // of opting in to history. On failure: log once
                    // and stop persisting for this session only; the
                    // session itself keeps running (history is
                    // best-effort by design, see crate::history).
                    if let Some(writer) = history.as_mut() {
                        if let Err(e) = writer.append(chunk) {
                            eprintln!(
                                "calyx-sessiond: history append failed for {id}, stopping \
                                 history for this session: {e}"
                            );
                            history = None;
                        }
                    }
                    let mut overflowed: Vec<u64> = Vec::new();
                    for client in &clients {
                        if !client.queue.push(FrameType::Output, chunk.to_vec()) {
                            overflowed.push(client.conn_id);
                        }
                    }
                    // The overflowed client's socket is shut down by
                    // its writer thread; its conn reader then runs the
                    // usual detach cleanup. Here it only stops being
                    // mirrored to.
                    clients.retain(|client| !overflowed.contains(&client.conn_id));
                }
                Err(nix::errno::Errno::EINTR) | Err(nix::errno::Errno::EAGAIN) => continue,
                // EIO is the normal "child exited" signal on a PTY.
                Err(_) => break,
            }
        }
    }

    // Teardown, in a deliberate order:
    //
    // 1. Remove the registry entry — but only if it is *ours*
    //    (create-race losers must not delete a same-id winner's).
    //    Removal precedes the reap so `Kill` can rely on "entry
    //    present => child not yet reaped => pid not reused".
    // 2. Delete this session's on-disk history, when it was ours and
    //    history was on: history exists to survive a daemon crash,
    //    not a session's own end (kill and natural exit both land
    //    here; this is the single teardown point). Before step 4's
    //    ledger flip on purpose, so `KillOk` (gated on that flip)
    //    implies the files are already gone.
    // 3. Reap the child (this is what frees the pid).
    // 4. Record the exit code in the ledger (this is what `Kill` waits
    //    for before `KillOk`, making its `kill -0` probe determinate).
    // 5. Drain the mailbox one final time: an Attach could only have
    //    been enqueued while the entry was still present (conn.rs
    //    sends under the registry lock), so admitting stragglers here
    //    closes the "attached into silence" race.
    // 6. Deliver Replay (for stragglers) + Exited to every client and
    //    finish their queues so their connections close promptly.
    let mine = {
        let mut state = shared.lock_state();
        let mine = state
            .sessions
            .get(&id)
            .is_some_and(|entry| Arc::ptr_eq(&entry.mailbox, &mailbox));
        if mine {
            state.sessions.remove(&id);
            state.touch();
        }
        shared.cond.notify_all();
        mine
    };

    // Step 2: close the writer's fd before unlinking (not required on
    // Unix, just tidy), then delete both generations. `mine` implies
    // `registered`, so a create-race loser never gets here with files
    // a winner owns; the check on `history_enabled` (not on the
    // writer, which an append error may have dropped) keeps the
    // cleanup running even when persisting stopped mid-session, and
    // keeps a history-off session from ever touching the paths.
    drop(history);
    if mine && history_enabled {
        if let Err(e) = history::HistoryWriter::remove_all(&state_dir, &id) {
            eprintln!("calyx-sessiond: removing history for {id} failed: {e}");
        }
    }

    let exit_code = child.reap(&id);

    if mine {
        let mut state = shared.lock_state();
        if let Some(info) = state.ledger.get_mut(&id) {
            info.state = SessionState::Exited { code: exit_code };
            info.pid = 0;
            info.attached_clients = 0;
        }
        state.touch();
        shared.persist_ledger(&state);
        shared.cond.notify_all();
    }

    for request in lock_unpoisoned(&mailbox.requests).drain(..) {
        match request {
            SessionRequest::Attach { conn_id, queue } => {
                push_replay(&mut terminal, &queue, &id);
                clients.push(AttachedClient { conn_id, queue });
            }
            SessionRequest::Remove { conn_id } => {
                clients.retain(|client| client.conn_id != conn_id);
            }
            SessionRequest::Resize { .. } | SessionRequest::Pump => {}
            SessionRequest::PauseForHandoff { reply } => {
                // Exit raced the handoff attempt: report it so the
                // offerer fails the whole attempt (and resumes the
                // sessions that did pause) instead of waiting out its
                // reply timeout.
                let _ = reply.send(Err(format!("session {id:?} exited during handoff pause")));
            }
        }
    }

    if let Ok(event) = encode_control(&ControlMsg::Event(SessionEvent::Exited {
        id: id.clone(),
        code: exit_code,
    })) {
        let queues: Vec<Arc<OutQueue>> = clients
            .iter()
            .map(|client| {
                client.queue.push(FrameType::Control, event.clone());
                Arc::clone(&client.queue)
            })
            .collect();
        // Close each connection after a grace window rather than
        // immediately: the queue (and the connection's reader) stays
        // live long enough for a follow-up request to complete, then
        // finishing the queue drains it and shuts the socket down.
        if !queues.is_empty() {
            thread::spawn(move || {
                thread::sleep(EXIT_CLOSE_GRACE);
                for queue in queues {
                    queue.finish();
                }
            });
        }
    }
}

/// Renders and queues one Replay frame, exempt from the backpressure
/// cap (see `OutQueue::push_replay`): a fresh attach must receive its
/// snapshot whole even when it exceeds the per-client OUTPUT budget.
/// A render failure still sends the (empty) frame: the protocol
/// promises Replay-before-Output, and an empty payload degrades to
/// "no catch-up" rather than a protocol violation.
fn push_replay(terminal: &mut vt::Terminal, queue: &Arc<OutQueue>, id: &str) {
    match terminal.render_replay() {
        Ok(replay) => {
            queue.push_replay(replay);
        }
        Err(e) => {
            eprintln!("calyx-sessiond: render_replay failed for {id}: {e}");
            queue.push_replay(Vec::new());
        }
    }
}

/// Keeps the detached-query responder registered exactly while no
/// client is attached: attached clients' real terminals answer queries
/// themselves, and double answers confuse applications.
fn update_responder(
    terminal: &mut vt::Terminal,
    detached: bool,
    input: &Arc<SessionInput>,
    master: Option<&Arc<OwnedFd>>,
    active: &mut bool,
) {
    let want = detached && master.is_some();
    if want == *active {
        return;
    }
    if want {
        let input = Arc::clone(input);
        let master = Arc::clone(master.expect("checked by `want` above"));
        terminal.set_responder(move |bytes| {
            // Same nonblocking path as client input: the responder
            // runs inside `feed`, which must never block. A refusal
            // (input backlog at its cap) drops the reply: the backlog
            // means the child isn't reading its own tty, so it would
            // never see the answer anyway, and query replies are
            // best-effort by nature.
            let _ = input.submit(&master, bytes);
        });
    } else {
        terminal.clear_responder();
    }
    *active = want;
}

#[cfg(test)]
mod tests {
    use std::os::fd::{AsRawFd, BorrowedFd};

    use super::*;

    /// Regression test (P2 review bug #4): the PTY master fd kept alive
    /// in the registry (`SessionEntry::master_input`) must be
    /// `FD_CLOEXEC`. Without it, every subsequently-forked child (a
    /// *different* session's shell) inherits this session's PTY master,
    /// breaking the isolation between sessions. Exercised as a
    /// daemon-internal unit test (rather than an external process
    /// inspecting its own fd table) since the portable way to enumerate
    /// a live child's open fds — `/proc/self/fd` — doesn't exist on
    /// macOS.
    #[test]
    fn spawned_session_master_input_fd_has_cloexec_set() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let spec = SessionSpec {
            id: "01J-p2-cloexec-unit-test".to_string(),
            name: None,
            cwd: None,
            argv: Some(vec!["/bin/cat".to_string()]),
            env: vec![],
            cols: 80,
            rows: 24,
        };

        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        let fd = entry.master_input.as_raw_fd();
        // SAFETY: `fd` is kept open by `entry.master_input` for the
        // duration of this borrow.
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        let flags = nix::fcntl::fcntl(borrowed, nix::fcntl::FcntlArg::F_GETFD)
            .expect("fcntl F_GETFD on the master_input fd");
        let fd_flags = nix::fcntl::FdFlag::from_bits_truncate(flags);

        // Best-effort teardown before asserting, so a failure here
        // doesn't leak this test's child process.
        let _ = nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(entry.pid as i32),
            nix::sys::signal::Signal::SIGKILL,
        );

        assert!(
            fd_flags.contains(nix::fcntl::FdFlag::FD_CLOEXEC),
            "the retained PTY master fd (master_input) must have FD_CLOEXEC set, \
             or it leaks into every subsequently-forked child of a different \
             session; fcntl(F_GETFD) returned {fd_flags:?}"
        );
    }

    /// Regression test (P2 review bug #4, second fd): the mailbox
    /// wake-pipe's write end (`SessionMailbox::wake_tx`) is *also* kept
    /// alive for the session's whole lifetime, so it needs the same
    /// `FD_CLOEXEC` treatment as `master_input`. Unlike `openpty` (see
    /// the sibling test above, which already passes — `nix`'s wrapper
    /// apparently defaults to `CLOEXEC`), `nix::unistd::pipe()` is the
    /// plain `pipe(2)` binding with no such default, and nothing here
    /// sets `FD_CLOEXEC` on it afterward (only `O_NONBLOCK`, a
    /// different fd-flag category via `F_SETFL`, is set).
    #[test]
    fn spawned_session_mailbox_wake_tx_fd_has_cloexec_set() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let spec = SessionSpec {
            id: "01J-p2-cloexec-unit-test-2".to_string(),
            name: None,
            cwd: None,
            argv: Some(vec!["/bin/cat".to_string()]),
            env: vec![],
            cols: 80,
            rows: 24,
        };

        let entry = spawn_session(&shared, &spec).expect("spawn_session should succeed");
        let fd = entry.mailbox.wake_tx.as_raw_fd();
        // SAFETY: `fd` is kept open by `entry.mailbox.wake_tx` for the
        // duration of this borrow.
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        let flags = nix::fcntl::fcntl(borrowed, nix::fcntl::FcntlArg::F_GETFD)
            .expect("fcntl F_GETFD on the mailbox wake_tx fd");
        let fd_flags = nix::fcntl::FdFlag::from_bits_truncate(flags);

        let _ = nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(entry.pid as i32),
            nix::sys::signal::Signal::SIGKILL,
        );

        assert!(
            fd_flags.contains(nix::fcntl::FdFlag::FD_CLOEXEC),
            "the mailbox's wake_tx fd must have FD_CLOEXEC set, or it leaks into \
             every subsequently-forked child of a different session; \
             fcntl(F_GETFD) returned {fd_flags:?}"
        );
    }

    /// Regression test (P2 final review, should-fix): `SessionInput`
    /// currently buffers unboundedly (see `SessionInput::submit`'s doc
    /// comment). A pipe whose write end is never drained (nothing
    /// reads the other end) stands in for "a child that never reads
    /// its stdin": once the pipe's own (small) kernel buffer fills,
    /// every subsequent `submit` call's bytes accumulate entirely in
    /// `pending`, so this reliably exercises unbounded growth without
    /// needing a real session/PTY.
    #[test]
    fn submit_refuses_further_input_once_pending_exceeds_the_cap() {
        let input = SessionInput::new();
        let (_read_end, write_end) =
            nix::unistd::pipe().expect("create a scratch pipe for the never-draining fd");
        nix::fcntl::fcntl(
            write_end.as_fd(),
            nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .expect("set the scratch pipe's write end nonblocking");

        let chunk = vec![0u8; 65536];
        let attempts_needed_to_exceed_cap = SESSION_INPUT_MAX_BYTES / chunk.len() + 4;

        let mut refused = false;
        for _ in 0..attempts_needed_to_exceed_cap {
            if !input.submit(&write_end, &chunk) {
                refused = true;
                break;
            }
        }

        assert!(
            refused,
            "submit must refuse further input once the undrained backlog would \
             exceed SESSION_INPUT_MAX_BYTES ({SESSION_INPUT_MAX_BYTES} bytes); \
             currently it always accepts, so pending grows without bound when \
             nothing drains it (e.g. a child that never reads its stdin)"
        );
    }
}
