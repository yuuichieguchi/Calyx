//! One accepted client connection: a reader loop dispatching
//! `ControlMsg`s and `Input` frames, paired with a writer thread
//! draining this client's `OutQueue`.

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, SessionSpec,
    PROTOCOL_VERSION,
};

use proto::SessionState;

use crate::outq::{lock_unpoisoned, writer_loop, OutQueue};
use crate::session::{spawn_session, SessionRequest};
use crate::state::Shared;

/// Upper bound on waiting for a killed session's teardown before
/// giving up and reporting failure (SIGKILL cannot be ignored, so in
/// practice this resolves in milliseconds).
const KILL_WAIT: Duration = Duration::from_secs(5);

/// Upper bound on waiting for a mid-teardown session's ledger record
/// (see `attach`'s exited-session path).
const TEARDOWN_WAIT: Duration = Duration::from_secs(5);

/// Caps on `MetaSet` payloads so a client can't balloon the in-memory
/// registry and the on-disk ledger without bound.
const MAX_META_KEY_BYTES: usize = 256;
const MAX_META_VALUE_BYTES: usize = 4096;

pub(crate) fn handle_conn(shared: Arc<Shared>, stream: UnixStream, conn_id: u64) {
    let queue = OutQueue::new();
    let writer_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return finish(&shared, None, conn_id, &queue),
    };
    {
        let queue = Arc::clone(&queue);
        thread::spawn(move || writer_loop(queue, writer_stream));
    }

    let mut conn = Conn {
        shared: Arc::clone(&shared),
        queue: Arc::clone(&queue),
        conn_id,
        hello_done: false,
        attached: None,
        input_drop_logged: false,
    };

    let mut reader = FrameReader::new(stream);
    while let Ok(frame) = reader.read_frame() {
        let keep_going = match frame.frame_type {
            FrameType::Control => match decode_control(&frame.payload) {
                Ok(msg) => conn.dispatch(msg),
                Err(_) => false,
            },
            FrameType::Input => {
                conn.forward_input(&frame.payload);
                true
            }
            // Clients never send these; treat as a protocol violation.
            FrameType::Output | FrameType::Replay => false,
        };
        if !keep_going {
            break;
        }
    }

    finish(&shared, conn.attached.take(), conn_id, &queue);
}

fn finish(shared: &Arc<Shared>, attached: Option<String>, conn_id: u64, queue: &Arc<OutQueue>) {
    if let Some(id) = attached {
        detach(shared, &id, conn_id);
    }
    queue.finish();
    let mut state = shared.lock_state();
    state.total_clients = state.total_clients.saturating_sub(1);
    state.touch();
    shared.cond.notify_all();
}

fn detach(shared: &Arc<Shared>, id: &str, conn_id: u64) {
    let mut state = shared.lock_state();
    if let Some(entry) = state.sessions.get_mut(id) {
        entry.attached_clients = entry.attached_clients.saturating_sub(1);
        let attached = entry.attached_clients;
        entry.mailbox.send(SessionRequest::Remove { conn_id });
        if let Some(info) = state.ledger.get_mut(id) {
            info.attached_clients = attached;
        }
        shared.persist_ledger(&state);
    }
    state.touch();
}

struct Conn {
    shared: Arc<Shared>,
    queue: Arc<OutQueue>,
    conn_id: u64,
    hello_done: bool,
    attached: Option<String>,
    /// Set after the first dropped-input log line, so a flooding
    /// client produces one diagnostic instead of a log storm.
    input_drop_logged: bool,
}

impl Conn {
    /// Handles one control message; returns `false` to close the
    /// connection.
    fn dispatch(&mut self, msg: ControlMsg) -> bool {
        if !self.hello_done {
            return match msg {
                ControlMsg::Hello { version } if version == PROTOCOL_VERSION => {
                    self.hello_done = true;
                    self.reply(&ControlMsg::HelloOk {
                        version: PROTOCOL_VERSION,
                    })
                }
                ControlMsg::Hello { version } => {
                    self.reply(&ControlMsg::HelloErr {
                        reason: format!(
                            "protocol version mismatch: client {version}, daemon {PROTOCOL_VERSION}"
                        ),
                    });
                    false
                }
                _ => false,
            };
        }

        match msg {
            ControlMsg::Hello { .. } => self.reply(&ControlMsg::HelloOk {
                version: PROTOCOL_VERSION,
            }),
            ControlMsg::List => {
                let sessions: Vec<_> = {
                    let state = self.shared.lock_state();
                    state.sessions.values().map(|entry| entry.info()).collect()
                };
                self.reply(&ControlMsg::ListOk { sessions })
            }
            // Unlike `List` (live registry only), `ListAll` reports
            // the persisted view: running *and* exited sessions, the
            // latter with their exit code.
            ControlMsg::ListAll => {
                let sessions: Vec<_> = {
                    let state = self.shared.lock_state();
                    state.ledger.values().cloned().collect()
                };
                self.reply(&ControlMsg::ListAllOk { sessions })
            }
            ControlMsg::New { spec } => match self.create_session(&spec, false) {
                Ok(()) => {
                    let reply = {
                        let state = self.shared.lock_state();
                        match state.sessions.get(&spec.id) {
                            Some(entry) => ControlMsg::NewOk { info: entry.info() },
                            // Exited between registration and here;
                            // report the ledger record.
                            None => match state.ledger.get(&spec.id) {
                                Some(info) => ControlMsg::NewOk { info: info.clone() },
                                None => err_no_session(&spec.id),
                            },
                        }
                    };
                    self.reply(&reply)
                }
                Err(reply) => self.reply(&reply),
            },
            ControlMsg::Attach {
                id,
                create,
                cols,
                rows,
            } => self.attach(id, create, cols, rows),
            ControlMsg::Detach => {
                if let Some(id) = self.attached.take() {
                    detach(&self.shared, &id, self.conn_id);
                }
                true
            }
            ControlMsg::Kill { id } => self.kill(&id),
            ControlMsg::MetaSet { id, key, value } => {
                if key.len() > MAX_META_KEY_BYTES || value.len() > MAX_META_VALUE_BYTES {
                    return self.reply(&ControlMsg::Err {
                        code: "meta-too-large".to_string(),
                        msg: format!(
                            "meta key is capped at {MAX_META_KEY_BYTES} bytes and value at \
                             {MAX_META_VALUE_BYTES} bytes"
                        ),
                    });
                }
                let reply = {
                    let mut state = self.shared.lock_state();
                    match state.sessions.get_mut(&id) {
                        Some(entry) => {
                            entry.meta.insert(key.clone(), value.clone());
                            let meta = entry.meta.clone();
                            if let Some(info) = state.ledger.get_mut(&id) {
                                info.meta = meta.clone();
                            }
                            state.touch();
                            self.shared.persist_ledger(&state);
                            ControlMsg::MetaOk { meta }
                        }
                        None => err_no_session(&id),
                    }
                };
                self.reply(&reply)
            }
            ControlMsg::MetaGet { id } => {
                let reply = {
                    let state = self.shared.lock_state();
                    match state.sessions.get(&id) {
                        Some(entry) => ControlMsg::MetaOk {
                            meta: entry.meta.clone(),
                        },
                        None => err_no_session(&id),
                    }
                };
                self.reply(&reply)
            }
            ControlMsg::Resize { cols, rows } => {
                if let Some(id) = &self.attached {
                    let state = self.shared.lock_state();
                    if let Some(entry) = state.sessions.get(id) {
                        entry.mailbox.send(SessionRequest::Resize { cols, rows });
                    }
                }
                true
            }
            ControlMsg::SetHistoryEnabled { enabled } => {
                // Affects only sessions created after this store:
                // `spawn_session` reads the flag once at creation, so
                // already-running sessions keep the value captured at
                // their own creation (see crates/daemon/src/history.rs).
                // SeqCst so a create that follows this reply on another
                // connection is guaranteed to observe the new value.
                self.shared.history_enabled.store(enabled, Ordering::SeqCst);
                self.reply(&ControlMsg::SetHistoryEnabledOk { enabled })
            }
            ControlMsg::GetHistoryEnabled => {
                // Query half of the toggle above (`SetHistoryEnabled`):
                // read-only, so a `status` can never itself flip the
                // flag. SeqCst to pair with the store above.
                let enabled = self.shared.history_enabled.load(Ordering::SeqCst);
                self.reply(&ControlMsg::HistoryEnabled { enabled })
            }
            ControlMsg::PrepareHandoff => self.prepare_handoff(),
            // Server-to-client messages arriving from a client are a
            // protocol violation.
            ControlMsg::HelloOk { .. }
            | ControlMsg::HelloErr { .. }
            | ControlMsg::ListOk { .. }
            | ControlMsg::ListAllOk { .. }
            | ControlMsg::NewOk { .. }
            | ControlMsg::AttachOk { .. }
            | ControlMsg::KillOk
            | ControlMsg::MetaOk { .. }
            | ControlMsg::SetHistoryEnabledOk { .. }
            | ControlMsg::HistoryEnabled { .. }
            | ControlMsg::PrepareHandoffOk { .. }
            | ControlMsg::Event(_)
            | ControlMsg::Err { .. } => false,
        }
    }

    /// Live Handoff trigger (EXPERIMENTAL; see `crate::handoff`): binds
    /// the dedicated handoff endpoint, replies with its path, and hands
    /// the rest of the attempt (single bounded accept, offer, exit or
    /// resume) to a dedicated host thread so this connection's reader
    /// stays responsive. Single-flight via `Shared::handoff_in_progress`.
    fn prepare_handoff(&mut self) -> bool {
        if self.shared.handoff_in_progress.swap(true, Ordering::SeqCst) {
            return self.reply(&ControlMsg::Err {
                code: "handoff-in-progress".to_string(),
                msg: "another handoff attempt is already pending".to_string(),
            });
        }
        let refuse = |conn: &Conn, code: &str, msg: String| -> bool {
            conn.shared
                .handoff_in_progress
                .store(false, Ordering::SeqCst);
            conn.reply(&ControlMsg::Err {
                code: code.to_string(),
                msg,
            })
        };

        let runtime_dir = {
            let env = lock_unpoisoned(&self.shared.handoff_env);
            env.as_ref().map(|env| env.runtime_dir.clone())
        };
        let Some(runtime_dir) = runtime_dir else {
            return refuse(
                self,
                "handoff-unavailable",
                "this daemon has no serving listener to hand off".to_string(),
            );
        };

        let socket_path = runtime_dir.join(crate::HANDOFF_SOCKET_FILE);
        // A stale endpoint can only be a crashed earlier attempt: the
        // in-progress latch above serializes live ones.
        match std::fs::remove_file(&socket_path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return refuse(
                    self,
                    "handoff-bind-failed",
                    format!("removing stale handoff socket failed: {e}"),
                );
            }
        }
        let listener = match std::os::unix::net::UnixListener::bind(&socket_path) {
            Ok(listener) => listener,
            Err(e) => {
                return refuse(
                    self,
                    "handoff-bind-failed",
                    format!("binding {} failed: {e}", socket_path.display()),
                );
            }
        };
        // Same private mode as the control socket; the uid check at
        // accept time is the real gate, this narrows the surface.
        if let Err(e) =
            std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
        {
            let _ = std::fs::remove_file(&socket_path);
            return refuse(
                self,
                "handoff-bind-failed",
                format!("chmod on handoff socket failed: {e}"),
            );
        }

        // Reply before spawning the host so the Ok frame is queued
        // ahead of any handoff-failed report (per-client FIFO).
        let ok = self.reply(&ControlMsg::PrepareHandoffOk {
            path: socket_path.display().to_string(),
        });
        let shared = Arc::clone(&self.shared);
        let queue = Arc::clone(&self.queue);
        thread::spawn(move || crate::handoff::host_handoff(shared, listener, socket_path, queue));
        ok
    }

    fn attach(&mut self, id: String, create: Option<SessionSpec>, cols: u16, rows: u16) -> bool {
        if self.attached.is_some() {
            return self.reply(&ControlMsg::Err {
                code: "already-attached".to_string(),
                msg: "this connection is already attached to a session".to_string(),
            });
        }

        // Create if missing (idempotent: an existing id short-circuits
        // to a plain attach regardless of `create`).
        if !self.shared.lock_state().sessions.contains_key(&id) {
            match create {
                Some(spec) if spec.id == id => {
                    if let Err(reply) = self.create_session(&spec, true) {
                        return self.reply(&reply);
                    }
                }
                Some(spec) => {
                    return self.reply(&ControlMsg::Err {
                        code: "spec-id-mismatch".to_string(),
                        msg: format!("Attach id {id:?} != create spec id {:?}", spec.id),
                    });
                }
                None => {
                    // No create requested: the id may still name an
                    // already-exited session (attachable via the
                    // exited path below) or be entirely unknown.
                    if !self.shared.lock_state().ledger.contains_key(&id) {
                        return self.reply(&err_no_session(&id));
                    }
                }
            }
        }

        let ok = {
            let mut state = self.shared.lock_state();
            let Some(entry) = state.sessions.get_mut(&id) else {
                // Known id but no live entry: the child already exited
                // (possible essentially instantly for e.g. `sh -c
                // "exit 0"`). Serve the attach from the ledger record:
                // AttachOk, an empty Replay (there is no terminal
                // anymore), then the Exited event — the same frame
                // sequence a client racing an exit would have seen.
                drop(state);
                return self.attach_exited(&id);
            };
            entry.attached_clients += 1;
            let attached = entry.attached_clients;
            let info = entry.info();

            // Client-bound ordering guarantee: AttachOk is queued
            // before the session thread queues Replay (FIFO per
            // client), and the session thread queues Replay before
            // mirroring any further Output (single-threaded session
            // loop).
            //
            // The mailbox sends stay under the registry lock on
            // purpose: the session's exit path removes the entry under
            // this same lock and then runs a final mailbox drain, so
            // an Attach enqueued while the entry was still present is
            // guaranteed to be seen even if the child is already dead.
            let ok = self.reply(&ControlMsg::AttachOk { info });
            // This client's size is the freshest, last-writer-wins.
            entry.mailbox.send(SessionRequest::Resize { cols, rows });
            entry.mailbox.send(SessionRequest::Attach {
                conn_id: self.conn_id,
                queue: Arc::clone(&self.queue),
            });

            if let Some(ledger_info) = state.ledger.get_mut(&id) {
                ledger_info.attached_clients = attached;
            }
            state.touch();
            self.shared.persist_ledger(&state);
            ok
        };
        self.attached = Some(id);
        ok
    }

    /// Creates a session and registers it (idempotent for `for_attach`:
    /// an already-existing id is success). On return the registry
    /// briefly held the entry, though an instantly-exiting child may
    /// have already removed it again — callers re-look it up.
    // The Err side carries the ready-to-send ControlMsg reply; its
    // size is irrelevant on this cold path.
    #[allow(clippy::result_large_err)]
    fn create_session(&self, spec: &SessionSpec, for_attach: bool) -> Result<(), ControlMsg> {
        {
            let state = self.shared.lock_state();
            if state.sessions.contains_key(&spec.id) {
                if for_attach {
                    // Idempotent path: caller proceeds to attach.
                    return Ok(());
                }
                return Err(ControlMsg::Err {
                    code: "exists".to_string(),
                    msg: format!("session {:?} already exists", spec.id),
                });
            }
        }

        // Refuse to fork a brand-new child while a Live Handoff is in
        // progress (P6 review H1/H2; see crate::handoff). `offer_handoff`
        // snapshots the live session ids once up front, so anything
        // forked after that snapshot is never in the manifest and is
        // silently lost (its child, its fd, its ledger entry) the instant
        // the old daemon exits post-ack. The idempotent-attach path above
        // (an already-live id) is unaffected; only a genuine create is
        // gated. Same retryable code PrepareHandoff itself uses, so a
        // client can retry against whichever daemon ends up serving.
        if self.shared.handoff_in_progress.load(Ordering::SeqCst) {
            return Err(ControlMsg::Err {
                code: "handoff-in-progress".to_string(),
                msg: "a live handoff is in progress; retry the create shortly".to_string(),
            });
        }

        // Spawn outside the state lock: fork/exec latency shouldn't
        // stall every other connection. A concurrent create of the
        // same id is resolved below by keeping the first entry. The
        // freshly spawned session thread idles at its start gate until
        // the registration decision lands (see `spawn_session`), so
        // its teardown can never interleave with this registration.
        let entry = spawn_session(&self.shared, spec).map_err(|msg| ControlMsg::Err {
            code: "spawn-failed".to_string(),
            msg,
        })?;

        let mut state = self.shared.lock_state();
        if state.sessions.contains_key(&spec.id) {
            // Lost a create race; kill the duplicate child and use the
            // winner (preserves Attach{create} idempotency even for
            // simultaneous requests). Dropping `entry` (below, without
            // registering it) closes its start gate, and the loser
            // thread's identity check keeps its teardown away from the
            // winner's registry entry.
            let loser_pid = entry.pid;
            drop(state);
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(loser_pid as i32),
                nix::sys::signal::Signal::SIGKILL,
            );
            return Ok(());
        }
        state.ledger.insert(spec.id.clone(), entry.info());
        state.sessions.insert(spec.id.clone(), entry);
        state.touch();
        self.shared.persist_ledger(&state);
        self.shared.cond.notify_all();
        // Release under the lock so "registered but not yet released"
        // is never observable: from the session thread's first
        // instruction onward, its registry entry is in place.
        state.sessions[&spec.id].release_start();
        Ok(())
    }

    fn kill(&mut self, id: &str) -> bool {
        {
            // killpg under the registry lock on purpose: the session
            // thread removes its entry *before* reaping (see the
            // teardown ordering in session.rs), so "entry present"
            // here proves the child is not yet reaped and its pid
            // therefore cannot have been reused by anything else.
            let state = self.shared.lock_state();
            match state.sessions.get(id) {
                Some(entry) => {
                    // The child is a session leader (setsid in
                    // pre_exec), so its process group id is its pid;
                    // killing the group takes down its descendants
                    // too. ESRCH means it beat us to exiting.
                    let _ = nix::sys::signal::killpg(
                        nix::unistd::Pid::from_raw(entry.pid as i32),
                        nix::sys::signal::Signal::SIGKILL,
                    );
                }
                None => {
                    // A session detached for an in-progress Live Handoff
                    // is out of the live registry but still `Running` in
                    // the ledger (handoff module doc): it is paused, not
                    // gone, and will resume on this daemon or migrate to
                    // the new one. Reply retryably rather than silently
                    // swallowing the kill as no-such-session (P6 review
                    // H4 / E#3). Any other missing id is a genuine
                    // no-such-session.
                    if self.shared.handoff_in_progress.load(Ordering::SeqCst)
                        && matches!(
                            state.ledger.get(id).map(|info| info.state),
                            Some(SessionState::Running)
                        )
                    {
                        drop(state);
                        return self.reply(&ControlMsg::Err {
                            code: "handoff-in-progress".to_string(),
                            msg: format!(
                                "session {id:?} is paused for a live handoff; retry the kill \
                                 shortly"
                            ),
                        });
                    }
                    drop(state);
                    return self.reply(&err_no_session(id));
                }
            }
        }

        // KillOk is only sent after the session thread has reaped the
        // child (observable as the ledger flipping to Exited, which
        // happens strictly after the reap) so a `kill -0` probe right
        // after the reply is deterministic.
        let deadline = Instant::now() + KILL_WAIT;
        let mut state = self.shared.lock_state();
        loop {
            let gone = !state.sessions.contains_key(id)
                && state
                    .ledger
                    .get(id)
                    .is_none_or(|info| matches!(info.state, SessionState::Exited { .. }));
            if gone {
                break;
            }
            let now = Instant::now();
            if now >= deadline {
                drop(state);
                return self.reply(&ControlMsg::Err {
                    code: "kill-timeout".to_string(),
                    msg: format!("session {id:?} did not exit within {KILL_WAIT:?}"),
                });
            }
            let (guard, _) = self
                .shared
                .cond
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state = guard;
        }
        drop(state);
        self.reply(&ControlMsg::KillOk)
    }

    /// Serves an `Attach` whose target already exited: AttachOk from
    /// the ledger record, an empty Replay, then the Exited event. The
    /// record may still be mid-teardown (registry entry removed, exit
    /// code not yet recorded); wait out that window on the condvar.
    fn attach_exited(&mut self, id: &str) -> bool {
        let deadline = Instant::now() + TEARDOWN_WAIT;
        let mut state = self.shared.lock_state();
        let (info, code) = loop {
            if let Some(entry) = state.sessions.get_mut(id) {
                // The same id got re-created while we waited; hand
                // back to the normal attach path by reporting a
                // transient error is worse than just failing — but
                // this needs `create` context we no longer have, so
                // report the record we can prove.
                let info = entry.info();
                drop(state);
                return self.reply(&ControlMsg::Err {
                    code: "retry-attach".to_string(),
                    msg: format!(
                        "session {:?} was re-created concurrently; retry the attach",
                        info.id
                    ),
                });
            }
            match state.ledger.get(id) {
                Some(info) => {
                    if let SessionState::Exited { code } = info.state {
                        break (info.clone(), code);
                    }
                }
                None => {
                    drop(state);
                    return self.reply(&err_no_session(id));
                }
            }
            let now = Instant::now();
            if now >= deadline {
                drop(state);
                return self.reply(&err_no_session(id));
            }
            let (guard, _) = self
                .shared
                .cond
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state = guard;
        };
        drop(state);

        let ok = self.reply(&ControlMsg::AttachOk { info });
        self.queue.push_replay(Vec::new());
        if let Ok(event) = proto::encode_control(&ControlMsg::Event(proto::SessionEvent::Exited {
            id: id.to_string(),
            code,
        })) {
            self.queue.push(proto::FrameType::Control, event);
        }
        ok
    }

    /// Forwards an `Input` frame to the attached session. Input beyond
    /// the session's backlog cap is dropped (logged once) rather than
    /// disconnecting the sender: the input-blocking contract requires
    /// the connection's control channel to stay usable even after an
    /// oversized burst at a child that never reads its stdin, and a
    /// wedged child makes the excess input worthless anyway. The
    /// daemon's memory stays bounded by the cap either way.
    fn forward_input(&mut self, payload: &[u8]) {
        if let Some(id) = &self.attached {
            let session = {
                let state = self.shared.lock_state();
                state.sessions.get(id).map(|entry| {
                    (
                        Arc::clone(&entry.input),
                        Arc::clone(&entry.master_input),
                        Arc::clone(&entry.mailbox),
                    )
                })
            };
            if let Some((input, master, mailbox)) = session {
                // Nonblocking: what the tty won't take right now is
                // buffered, and the Pump wake tells the session thread
                // to add POLLOUT interest for the rest.
                if !input.submit(&master, payload) && !self.input_drop_logged {
                    self.input_drop_logged = true;
                    eprintln!(
                        "calyx-sessiond: dropping input for session {id}: backlog cap reached                          (child not reading its stdin)"
                    );
                }
                mailbox.send(SessionRequest::Pump);
            }
        }
    }

    /// Queues a control reply; returns `false` (close the connection)
    /// if this client's queue is already closed or overflowed.
    fn reply(&self, msg: &ControlMsg) -> bool {
        match encode_control(msg) {
            Ok(payload) => self.queue.push(FrameType::Control, payload),
            Err(_) => false,
        }
    }
}

fn err_no_session(id: &str) -> ControlMsg {
    ControlMsg::Err {
        code: "no-such-session".to_string(),
        msg: format!("no session with id {id:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// Kills the process group on drop (mirrors `handoff.rs`'s test
    /// helper of the same shape): without this, a spawned `/bin/cat`
    /// donor would outlive a test that panics on assertion failure,
    /// which every RED test here is expected to do until the
    /// corresponding handoff-window gate exists.
    struct KillOnDrop(u32);

    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(self.0 as i32),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
    }

    /// Builds a real `Conn` wired to a real client-side `UnixStream`
    /// (via the crate's own `writer_loop`, exactly like `handle_conn`
    /// does), so a test can call a private `Conn` method directly and
    /// still observe exactly what a real client socket would receive.
    /// Returns the `Conn` plus a `FrameReader` over the client side.
    fn make_test_conn(shared: &Arc<Shared>, conn_id: u64) -> (Conn, FrameReader<UnixStream>) {
        let (client_side, server_side) = UnixStream::pair().expect("create scratch stream pair");
        client_side
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .expect("set read timeout on the client side");
        let queue = OutQueue::new();
        {
            let queue = Arc::clone(&queue);
            thread::spawn(move || writer_loop(queue, server_side));
        }
        let conn = Conn {
            shared: Arc::clone(shared),
            queue,
            conn_id,
            hello_done: true,
            attached: None,
            input_drop_logged: false,
        };
        let reader = FrameReader::new(
            client_side
                .try_clone()
                .expect("clone client stream for reader"),
        );
        (conn, reader)
    }

    /// H1 (P6 review, conn.rs:368 + handoff.rs:321): while a handoff is
    /// in progress, `ControlMsg::New` (routed through
    /// `Conn::create_session`) must not fork a brand-new child for any
    /// id: the offering side's `offer_handoff` snapshots the live id
    /// list once up front, so anything created after that snapshot is
    /// never in the manifest and is silently lost (its child, fd, and
    /// ledger entry) the instant the old daemon exits post-handoff.
    /// `create_session` currently has no such gate at all.
    #[test]
    fn create_session_is_refused_while_handoff_in_progress() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        shared
            .handoff_in_progress
            .store(true, std::sync::atomic::Ordering::SeqCst);

        let (conn, _reader) = make_test_conn(&shared, 1);
        let id = "01J-p6-h1-create-during-handoff-test";
        let spec = cat_spec(id);

        let result = conn.create_session(&spec, false);

        // Whatever child create_session may have spawned before
        // failing must be cleaned up regardless of which assertion
        // below fails first.
        let leaked_pid = shared.lock_state().sessions.get(id).map(|entry| entry.pid);
        let _kill_on_drop = leaked_pid.map(KillOnDrop);

        match result {
            Err(ControlMsg::Err { code, .. }) => {
                assert_eq!(
                    code, "handoff-in-progress",
                    "create_session should refuse with a retryable handoff-in-progress \
                     error while a handoff is pending, mirroring PrepareHandoff's own \
                     err code, got code {code:?}"
                );
            }
            other => panic!(
                "create_session must return an Err while handoff_in_progress is set \
                 instead of forking a new session, got {other:?}"
            ),
        }

        let state = shared.lock_state();
        assert!(
            !state.sessions.contains_key(id),
            "create_session must not register (or leave registered) a new session while \
             a handoff is in progress: a session created after offer_handoff's id \
             snapshot is never in the manifest and is orphaned when the old daemon exits"
        );
        assert!(
            !state.ledger.contains_key(id),
            "create_session must not add a ledger entry for a session created while a \
             handoff is in progress"
        );
    }

    /// H2 (P6 review, conn.rs:368 + handoff.rs:321, same root cause as
    /// H1): `Attach { id, create: Some(spec) }` against an id that does
    /// not yet exist funnels into the same `create_session` call
    /// (`for_attach = true`). During a pending handoff this must not
    /// silently attach a freshly forked (and therefore unmigrated)
    /// session either.
    #[test]
    fn attach_with_create_is_refused_while_handoff_in_progress() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        shared
            .handoff_in_progress
            .store(true, std::sync::atomic::Ordering::SeqCst);

        let (mut conn, mut reader) = make_test_conn(&shared, 2);
        let id = "01J-p6-h2-attach-create-during-handoff-test";
        let spec = cat_spec(id);

        let keep_going = conn.attach(id.to_string(), Some(spec), 80, 24);

        let leaked_pid = shared.lock_state().sessions.get(id).map(|entry| entry.pid);
        let _kill_on_drop = leaked_pid.map(KillOnDrop);

        assert!(
            keep_going,
            "attach should reply with a normal Err frame (not just drop the connection) \
             so a client can retry"
        );

        let frame = reader.read_frame().expect("read the Attach reply frame");
        let msg = decode_control(&frame.payload).expect("decode the Attach reply");
        match msg {
            ControlMsg::AttachOk { .. } => panic!(
                "attach must not succeed in creating and attaching a brand-new session \
                 while a handoff is in progress"
            ),
            ControlMsg::Err { code, .. } => {
                assert_eq!(
                    code, "handoff-in-progress",
                    "attach's create-if-missing path should surface the same retryable \
                     handoff-in-progress rejection as a plain New, got code {code:?}"
                );
            }
            other => panic!("expected an Err reply, got {other:?}"),
        }

        let state = shared.lock_state();
        assert!(
            !state.sessions.contains_key(id),
            "attach must not have registered a new session while a handoff is in progress"
        );
    }

    /// H4 (P6 review, conn.rs:518 + E#3): a session currently detached
    /// for an in-progress handoff (`handoff::detach_for_handoff` has
    /// removed its live registry entry but the ledger still says
    /// `Running`, per the handoff module doc's contract) must not have
    /// its `Kill` silently swallowed as `no-such-session`: the session
    /// is paused, not gone, and will either resume on this daemon or
    /// migrate to the new one.
    #[test]
    fn kill_during_handoff_pause_window_does_not_report_no_such_session() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let shared = Arc::new(Shared::new(tmp.path().to_path_buf(), false));
        let id = "01J-p6-h4-kill-during-pause-test";
        let spec = cat_spec(id);
        let entry =
            crate::session::spawn_session(&shared, &spec).expect("spawn_session should succeed");
        entry.release_start();
        let pid = entry.pid;
        let _kill_on_drop = KillOnDrop(pid);
        {
            let mut state = shared.lock_state();
            state.ledger.insert(entry.id.clone(), entry.info());
            state.sessions.insert(entry.id.clone(), entry);
        }

        // Simulate the pause window exactly as `offer_handoff` creates
        // it: the flag is set before detaching (`Conn::prepare_handoff`
        // sets it first), then `detach_for_handoff` removes the live
        // entry while the ledger keeps saying `Running`.
        shared
            .handoff_in_progress
            .store(true, std::sync::atomic::Ordering::SeqCst);
        let detached = crate::handoff::detach_for_handoff(&shared, id)
            .expect("detach_for_handoff should return the live entry");

        let (mut conn, mut reader) = make_test_conn(&shared, 3);
        let keep_going = conn.kill(id);
        assert!(
            keep_going,
            "a rejected/deferred kill should still reply normally, not just drop the \
             connection"
        );

        let frame = reader.read_frame().expect("read the Kill reply frame");
        let msg = decode_control(&frame.payload).expect("decode the Kill reply");
        match msg {
            ControlMsg::Err { code, .. } => {
                assert_ne!(
                    code, "no-such-session",
                    "a Kill for a session currently detached for an in-progress handoff \
                     must not be silently swallowed as no-such-session: the session is \
                     paused, not gone"
                );
            }
            other => panic!(
                "expected a distinct retryable Err reply for a Kill during the handoff \
                 pause window, got {other:?}"
            ),
        }

        // Cleanup: this test's detached entry never went back into the
        // registry (kill() found no live entry, unlike a real
        // resume_all), so the real child is killed directly via the
        // drop guard above; drop the detached entry's own handles now.
        drop(detached);
    }
}
