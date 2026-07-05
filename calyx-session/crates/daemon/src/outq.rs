//! Per-client outbound frame queue.
//!
//! Every byte destined for a connected client flows through exactly one
//! `OutQueue` (its dedicated writer thread drains it), which gives two
//! properties the daemon contract needs: strict FIFO ordering of
//! `AttachOk` / `Replay` / `Output` / `Event` frames per client, and a
//! bounded buffer so one stalled client can be disconnected without
//! ever blocking the PTY reader that feeds all clients.

use std::collections::VecDeque;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};

use std::time::{Duration, Instant};

use proto::{FrameType, FrameWriter};

/// Backlog level of *capped* traffic (everything except Replay
/// snapshots) that marks a client as falling behind. Crossing it only
/// starts the clock: disconnection happens when the backlog stays
/// above this level for `SUSTAINED_OVER` (that client only; the
/// session and other clients are unaffected). An instantaneous
/// threshold would misfire on healthy clients: a release-build session
/// can enqueue a multi-megabyte PTY burst faster than the writer
/// thread gets scheduled at all.
pub(crate) const MAX_QUEUED_BYTES: usize = 1024 * 1024;

/// How long the backlog may stay above `MAX_QUEUED_BYTES` before the
/// client is declared stalled and disconnected.
const SUSTAINED_OVER: Duration = Duration::from_secs(2);

/// Absolute backlog bound: even within the sustained-over grace, a
/// runaway producer cannot buffer more than this per client.
const HARD_MAX_QUEUED_BYTES: usize = 16 * 1024 * 1024;

/// Upper bound on a single blocking socket write. Insurance against a
/// connected-but-never-reading client pinning its writer thread (and
/// any queued teardown) forever; a healthy client acks a write within
/// milliseconds.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

pub(crate) struct OutQueue {
    state: Mutex<QueueState>,
    cond: Condvar,
}

struct QueueItem {
    frame_type: FrameType,
    payload: Vec<u8>,
    /// Whether this item's size counts against `MAX_QUEUED_BYTES`.
    /// Replay snapshots don't: their size is a property of the session
    /// (screen dimensions x content), not of a client falling behind,
    /// which is what the cap exists to detect.
    counted: bool,
}

struct QueueState {
    items: VecDeque<QueueItem>,
    queued_bytes: usize,
    /// Queued Replay bytes: exempt from the soft threshold, but part
    /// of the absolute `HARD_MAX_QUEUED_BYTES` accounting (repeated
    /// attach/detach cycles must not grow this queue without bound).
    replay_bytes: usize,
    /// When the backlog first exceeded `MAX_QUEUED_BYTES` without
    /// dropping back under it since.
    over_since: Option<Instant>,
    /// No further pushes; the writer drains what's queued, then exits.
    draining: bool,
    /// Everything is discarded immediately (backpressure overflow or a
    /// dead socket); the writer exits without flushing.
    aborted: bool,
}

impl OutQueue {
    pub(crate) fn new() -> Arc<OutQueue> {
        Arc::new(OutQueue {
            state: Mutex::new(QueueState {
                items: VecDeque::new(),
                queued_bytes: 0,
                replay_bytes: 0,
                over_since: None,
                draining: false,
                aborted: false,
            }),
            cond: Condvar::new(),
        })
    }

    /// Enqueues one frame without ever blocking. Returns `false` if the
    /// queue is closed or the byte cap would be exceeded; the latter
    /// also closes the queue permanently, which makes the writer thread
    /// shut the socket down (the disconnect-on-backpressure contract).
    pub(crate) fn push(&self, frame_type: FrameType, payload: Vec<u8>) -> bool {
        let mut st = lock_unpoisoned(&self.state);
        if st.draining || st.aborted {
            return false;
        }
        if st.queued_bytes + st.replay_bytes + payload.len() > HARD_MAX_QUEUED_BYTES {
            st.aborted = true;
            self.cond.notify_all();
            return false;
        }
        let new_soft_total = st.queued_bytes + payload.len();
        if new_soft_total > MAX_QUEUED_BYTES {
            match st.over_since {
                None => st.over_since = Some(Instant::now()),
                Some(since) if since.elapsed() >= SUSTAINED_OVER => {
                    st.aborted = true;
                    self.cond.notify_all();
                    return false;
                }
                Some(_) => {}
            }
        }
        st.queued_bytes += payload.len();
        st.items.push_back(QueueItem {
            frame_type,
            payload,
            counted: true,
        });
        self.cond.notify_all();
        true
    }

    /// Enqueues one Replay frame, exempt from the soft
    /// `MAX_QUEUED_BYTES` threshold (see `QueueItem::counted`) but
    /// still bounded by `HARD_MAX_QUEUED_BYTES`. Returns `false` if
    /// the queue is closed or the hard cap would be exceeded.
    pub(crate) fn push_replay(&self, payload: Vec<u8>) -> bool {
        let mut st = lock_unpoisoned(&self.state);
        if st.draining || st.aborted {
            return false;
        }
        if st.queued_bytes + st.replay_bytes + payload.len() > HARD_MAX_QUEUED_BYTES {
            st.aborted = true;
            self.cond.notify_all();
            return false;
        }
        st.replay_bytes += payload.len();
        st.items.push_back(QueueItem {
            frame_type: FrameType::Replay,
            payload,
            counted: false,
        });
        self.cond.notify_all();
        true
    }

    /// Blocks for the next frame; `None` once the queue is finished
    /// (drained after `finish`) or aborted (immediately, discarding).
    fn pop(&self) -> Option<(FrameType, Vec<u8>)> {
        let mut st = lock_unpoisoned(&self.state);
        loop {
            if st.aborted {
                return None;
            }
            if let Some(item) = st.items.pop_front() {
                if item.counted {
                    st.queued_bytes -= item.payload.len();
                    if st.queued_bytes <= MAX_QUEUED_BYTES {
                        st.over_since = None;
                    }
                } else {
                    st.replay_bytes -= item.payload.len();
                }
                return Some((item.frame_type, item.payload));
            }
            if st.draining {
                return None;
            }
            st = self
                .cond
                .wait(st)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    /// Graceful close: whatever is already queued (e.g. a final
    /// `HelloErr`) still reaches the socket before the writer exits.
    pub(crate) fn finish(&self) {
        lock_unpoisoned(&self.state).draining = true;
        self.cond.notify_all();
    }

    /// Hard close: discard everything queued and stop the writer as
    /// soon as it looks.
    pub(crate) fn abort(&self) {
        let mut st = lock_unpoisoned(&self.state);
        st.aborted = true;
        self.cond.notify_all();
    }
}

/// Drains `queue` into `stream` until the queue closes or the write
/// side fails, then shuts the socket down both ways so the connection's
/// reader thread unblocks and runs its cleanup.
pub(crate) fn writer_loop(queue: Arc<OutQueue>, stream: UnixStream) {
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let mut writer = FrameWriter::new(&stream);
    while let Some((frame_type, payload)) = queue.pop() {
        if writer.write_frame(frame_type, &payload).is_err() {
            break;
        }
    }
    queue.abort();
    let _ = stream.shutdown(Shutdown::Both);
}

/// The daemon's poison policy: a panicked holder is a bug, but a poison
/// panic cascade would take down every session; continue with the inner
/// state instead.
pub(crate) fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression test (P2 final review, must-fix): `push_replay`'s
    /// payload size is currently never added to any tracked total (see
    /// `QueueItem::counted: false`), so repeated `Attach -> Detach ->
    /// Attach` cycles — each re-rendering and re-queuing a full Replay
    /// snapshot — can grow this queue's backing memory without bound
    /// when nothing ever pops it (a client that attaches and detaches
    /// faster than its writer thread drains, say). The fixed
    /// semantics: Replay stays exempt from the *soft* threshold
    /// (`MAX_QUEUED_BYTES` / `SUSTAINED_OVER`, since its size reflects
    /// the session's screen content, not a client falling behind), but
    /// must still count toward the *absolute* `HARD_MAX_QUEUED_BYTES`
    /// cap, aborting once cumulative Replay bytes exceed it.
    #[test]
    fn push_replay_aborts_once_cumulative_bytes_exceed_the_hard_cap() {
        let queue = OutQueue::new();
        // Deliberately larger than the *soft* threshold on its own
        // (Replay must never be capped by that one — only by the
        // absolute hard cap below).
        let chunk = vec![0u8; 2 * MAX_QUEUED_BYTES];
        let attempts_needed_to_exceed_hard_cap = HARD_MAX_QUEUED_BYTES / chunk.len() + 1;

        let mut aborted = false;
        for _ in 0..attempts_needed_to_exceed_hard_cap {
            if !queue.push_replay(chunk.clone()) {
                aborted = true;
                break;
            }
        }

        assert!(
            aborted,
            "push_replay must abort once cumulative Replay bytes exceed \
             HARD_MAX_QUEUED_BYTES ({HARD_MAX_QUEUED_BYTES} bytes); currently \
             a Replay push is never added to any tracked total at all, so \
             this never happens (unbounded memory growth across repeated \
             Attach -> Detach -> Attach cycles)"
        );
    }

    /// Confirms the *existing* hard-cap behavior for counted (`push`)
    /// items is unaffected by the `push_replay` accounting fix above: a
    /// single counted push already over `HARD_MAX_QUEUED_BYTES` aborts
    /// immediately. This already passes today; kept here so the two
    /// paths (counted vs. Replay) are asserted side by side and a
    /// future change can't silently regress this one while fixing the
    /// other.
    #[test]
    fn push_counted_still_aborts_at_hard_cap() {
        let queue = OutQueue::new();
        let oversized = vec![0u8; HARD_MAX_QUEUED_BYTES + 1];
        assert!(
            !queue.push(FrameType::Output, oversized),
            "a single counted push already over HARD_MAX_QUEUED_BYTES must abort"
        );
    }
}
