//! Shared daemon state: the live session registry, the persisted
//! ledger view, and the client/activity accounting `run_until_idle`
//! watches.

use std::collections::{BTreeMap, HashMap};
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;
use std::time::Instant;

use proto::{SessionInfo, SessionState};

use crate::outq::lock_unpoisoned;
use crate::session::{SessionInput, SessionMailbox};

pub(crate) struct Shared {
    pub(crate) state: Mutex<State>,
    pub(crate) cond: Condvar,
    /// Root for this daemon's on-disk state; `spawn_session` derives
    /// the history directory from it (see `crate::history`).
    pub(crate) state_dir: PathBuf,
    /// Live daemon-wide default for opt-in history persistence: seeded
    /// from `DaemonConfig::history_enabled` at bind time, overridable
    /// via `ControlMsg::SetHistoryEnabled`. Read once per session at
    /// creation (`spawn_session`), so a mid-lifetime flip affects only
    /// sessions created afterwards.
    pub(crate) history_enabled: AtomicBool,
    /// Ledger snapshots headed for the persister thread; see
    /// `persist_ledger`. `None` once `shutdown_persister` ran.
    persist_tx: Mutex<Option<mpsc::Sender<Vec<SessionInfo>>>>,
    persister: Mutex<Option<thread::JoinHandle<()>>>,
    /// Live Handoff (EXPERIMENTAL, see `crate::handoff`): what
    /// `ControlMsg::PrepareHandoff` needs from the serving entry point
    /// (`crate::install_handoff_env`). `None` outside a served daemon
    /// (unit tests, library embedding), which makes a handoff request
    /// refuse cleanly instead of guessing paths.
    pub(crate) handoff_env: Mutex<Option<HandoffEnv>>,
    /// Single-flight latch for handoff attempts: `PrepareHandoff`
    /// refuses while an earlier attempt is still pending.
    pub(crate) handoff_in_progress: AtomicBool,
}

/// See `Shared::handoff_env`.
pub(crate) struct HandoffEnv {
    /// `DaemonConfig::runtime_dir`: where the dedicated handoff socket
    /// gets bound.
    pub(crate) runtime_dir: PathBuf,
    /// A dup of the serving control listener, passed to the next
    /// daemon generation so accepting never stops across a handoff
    /// (no unbind/rebind gap; `crate::handoff`'s module doc).
    pub(crate) listener: OwnedFd,
}

impl Shared {
    pub(crate) fn new(state_dir: PathBuf, history_enabled: bool) -> Shared {
        // Dedicated persister thread: registry-lock holders only take
        // an in-memory snapshot, so no request path ever waits on
        // write+fsync. Writes are throttled leading+trailing: a first
        // snapshot after a quiet period is written immediately, and a
        // burst (create + instant exit, say) coalesces into one
        // trailing write once the throttle interval elapses — each
        // snapshot is the *whole* ledger, so skipping intermediates
        // loses nothing. The trailing write also restores the file if
        // the burst's earlier write got wiped out from under us
        // (state-dir teardown around a daemon "restart").
        let (persist_tx, persist_rx) = mpsc::channel::<Vec<SessionInfo>>();
        let persister = {
            let state_dir = state_dir.clone();
            thread::spawn(move || {
                const THROTTLE: std::time::Duration = std::time::Duration::from_millis(500);
                let mut last_write: Option<Instant> = None;
                while let Ok(mut snapshot) = persist_rx.recv() {
                    while let Ok(newer) = persist_rx.try_recv() {
                        snapshot = newer;
                    }
                    if let Some(at) = last_write {
                        let since = at.elapsed();
                        if since < THROTTLE {
                            thread::sleep(THROTTLE - since);
                            while let Ok(newer) = persist_rx.try_recv() {
                                snapshot = newer;
                            }
                        }
                    }
                    if let Err(e) = crate::ledger::write(&state_dir, &snapshot) {
                        eprintln!("calyx-sessiond: failed to write sessions.json: {e}");
                    }
                    last_write = Some(Instant::now());
                }
            })
        };
        Shared {
            state: Mutex::new(State {
                sessions: HashMap::new(),
                ledger: BTreeMap::new(),
                total_clients: 0,
                last_activity: Instant::now(),
            }),
            cond: Condvar::new(),
            state_dir,
            history_enabled: AtomicBool::new(history_enabled),
            persist_tx: Mutex::new(Some(persist_tx)),
            persister: Mutex::new(Some(persister)),
            handoff_env: Mutex::new(None),
            handoff_in_progress: AtomicBool::new(false),
        }
    }

    /// Flushes and joins the persister thread: dropping the sender
    /// lets the thread finish delivering everything already queued
    /// (including a throttled trailing write) and exit; the join makes
    /// that completion visible to the caller. Later `persist_ledger`
    /// calls become no-ops, which is fine: this only runs when the
    /// daemon is exiting.
    pub(crate) fn shutdown_persister(&self) {
        drop(lock_unpoisoned(&self.persist_tx).take());
        if let Some(handle) = lock_unpoisoned(&self.persister).take() {
            let _ = handle.join();
        }
    }

    pub(crate) fn lock_state(&self) -> std::sync::MutexGuard<'_, State> {
        lock_unpoisoned(&self.state)
    }

    /// Hands the current ledger to the persister thread. Failures are
    /// logged there, not propagated: a full disk must not take down
    /// live sessions.
    pub(crate) fn persist_ledger(&self, state: &State) {
        let snapshot: Vec<SessionInfo> = state.ledger.values().cloned().collect();
        // A missing sender or send error means the persister already
        // shut down (only possible when the daemon is exiting).
        if let Some(tx) = lock_unpoisoned(&self.persist_tx).as_ref() {
            let _ = tx.send(snapshot);
        }
    }
}

pub(crate) struct State {
    pub(crate) sessions: HashMap<String, SessionEntry>,
    /// Persisted view (includes exited sessions); see `ledger::load`.
    pub(crate) ledger: BTreeMap<String, SessionInfo>,
    pub(crate) total_clients: usize,
    pub(crate) last_activity: Instant,
}

impl State {
    pub(crate) fn touch(&mut self) {
        self.last_activity = Instant::now();
    }
}

/// Registry-side view of one live session. The PTY master, the child,
/// and the `vt::Terminal` live on the session's own thread (see
/// `session.rs`); this entry holds what other threads need: identity,
/// counters, a mailbox to reach the session thread, the input buffer,
/// and a dup of the master for nonblocking input drains.
pub(crate) struct SessionEntry {
    pub(crate) id: String,
    pub(crate) name: Option<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) created_at_ms: u64,
    pub(crate) pid: u32,
    pub(crate) meta: BTreeMap<String, String>,
    pub(crate) attached_clients: u32,
    pub(crate) mailbox: Arc<SessionMailbox>,
    pub(crate) master_input: Arc<OwnedFd>,
    pub(crate) input: Arc<SessionInput>,
    /// Start gate for the session thread; see `spawn_session`. Firing
    /// it (or dropping this entry) lets the thread run.
    pub(crate) start_tx: mpsc::SyncSender<()>,
}

impl SessionEntry {
    /// Releases the session thread's start gate (idempotent: the gate
    /// only parks the thread once, and a second send just fills the
    /// channel's buffer).
    pub(crate) fn release_start(&self) {
        let _ = self.start_tx.send(());
    }

    pub(crate) fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            cwd: self.cwd.clone(),
            state: SessionState::Running,
            created_at_ms: self.created_at_ms,
            attached_clients: self.attached_clients,
            pid: self.pid,
            meta: self.meta.clone(),
        }
    }
}
