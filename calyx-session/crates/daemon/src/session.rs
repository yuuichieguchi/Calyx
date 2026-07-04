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
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use nix::pty::Winsize;
use proto::{encode_control, ControlMsg, FrameType, SessionEvent, SessionSpec, SessionState};

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
}

/// Request channel into a session thread, woken via a self-pipe so the
/// thread can block in `poll` on the PTY and still react to requests.
pub(crate) struct SessionMailbox {
    requests: Mutex<VecDeque<SessionRequest>>,
    pub(crate) wake_tx: OwnedFd,
}

impl SessionMailbox {
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
    fn new() -> Arc<SessionInput> {
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
            if libc::ioctl(0, libc::TIOCSCTTY as libc::c_ulong, 0) < 0 {
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

    // macOS has no pipe2, so CLOEXEC is applied after the fact; the
    // (tiny) fork window in between is accepted on this platform.
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
    let mailbox = Arc::new(SessionMailbox {
        requests: Mutex::new(VecDeque::new()),
        wake_tx,
    });

    let created_at_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    // The vt::Terminal can only be created on the session thread
    // (!Send); wait for that to succeed before reporting the session
    // as created, so a terminal failure never yields a half-alive
    // session.
    let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
    let (start_tx, start_rx) = mpsc::sync_channel::<()>(1);
    {
        let shared = Arc::clone(shared);
        let id = spec.id.clone();
        let mailbox = Arc::clone(&mailbox);
        let input = Arc::clone(&input);
        let master = pty.master;
        thread::Builder::new()
            .name(format!("session-{id}"))
            .spawn(move || {
                session_thread(SessionThread {
                    shared,
                    id,
                    master,
                    wake_rx,
                    mailbox,
                    input,
                    child,
                    cols,
                    rows,
                    ready_tx,
                    start_rx,
                })
            })
            .map_err(|e| format!("spawn session thread: {e}"))?;
    }
    match ready_rx.recv() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return Err(format!("terminal init failed: {e}")),
        Err(_) => return Err("session thread died during startup".to_string()),
    }

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

struct SessionThread {
    shared: Arc<Shared>,
    id: String,
    master: OwnedFd,
    wake_rx: OwnedFd,
    mailbox: Arc<SessionMailbox>,
    input: Arc<SessionInput>,
    child: Child,
    cols: u16,
    rows: u16,
    ready_tx: mpsc::SyncSender<Result<(), String>>,
    start_rx: mpsc::Receiver<()>,
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
    } = ctx;
    let master_raw = master.as_raw_fd();

    let mut terminal = match vt::Terminal::new(cols, rows, SCROLLBACK_BYTES) {
        Ok(t) => t,
        Err(e) => {
            let _ = ready_tx.send(Err(e.to_string()));
            let _ = child.kill();
            let _ = child.wait();
            return;
        }
    };
    let _ = ready_tx.send(Ok(()));

    // Start gate: wait for the registration decision. A closed channel
    // (entry dropped without release: create-race loser, failed
    // caller) means "proceed anyway" — the loop then just reaps the
    // already-killed child and the identity check below keeps its
    // teardown away from any same-id successor's registry entry.
    let _ = start_rx.recv();

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
                        libc::ioctl(master_raw, libc::TIOCSWINSZ as libc::c_ulong, &winsize)
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
                }
                SessionRequest::Pump => {}
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
    // 2. Reap the child (this is what frees the pid).
    // 3. Record the exit code in the ledger (this is what `Kill` waits
    //    for before `KillOk`, making its `kill -0` probe determinate).
    // 4. Drain the mailbox one final time: an Attach could only have
    //    been enqueued while the entry was still present (conn.rs
    //    sends under the registry lock), so admitting stragglers here
    //    closes the "attached into silence" race.
    // 5. Deliver Replay (for stragglers) + Exited to every client and
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

    let exit_code = match child.wait() {
        Ok(status) => status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
        Err(e) => {
            eprintln!("calyx-sessiond: waitpid failed for {id}: {e}");
            -1
        }
    };

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
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf()));
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
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf()));
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
