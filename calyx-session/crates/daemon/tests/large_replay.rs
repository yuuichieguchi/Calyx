//! Regression test (P2 review bug #3): a fresh attach to a session
//! whose replay exceeds the 1 MiB per-client outbound queue cap must
//! still receive its `Replay` frame whole, not get disconnected.
//! `push_replay` hands the *entire* rendered replay to `OutQueue::push`
//! in one call; since `push` aborts (and discards) any single payload
//! that alone exceeds `MAX_QUEUED_BYTES`, a replay over that cap
//! currently tears the connection down before the client ever sees it.
//!
//! Getting a >1 MiB replay via *scrollback depth* turns out not to work
//! under the session's current 8 MiB `vt::Terminal` budget: that budget
//! is spent on `sizeof(Cell) * cols` per retained row, not raw text
//! bytes, so plain-text scrollback stabilizes at a retained size well
//! under 1 MiB no matter how much more is fed once eviction kicks in
//! (verified empirically: ~2.5 MiB of piped text produced a ~94 KiB
//! replay). Scrollback *eviction* only ever trims history (rows beyond
//! the visible screen), though, so a wide-enough *visible* screen holds
//! plenty of content without ever touching history: at `cols=2000,
//! rows=1000` the visible screen alone holds up to 2,000,000 cells, so
//! filling ~800 of those rows with one continuous run of a repeated
//! character (no newlines, so it soft-wraps across rows instead of
//! scrolling into history) comfortably clears 1 MiB without any
//! eviction risk.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

const DONE_MARKER: &str = "DONE_MARKER";
/// Comfortably over the 1 MiB `OutQueue` cap; see the module doc for
/// why this needs to land on the *visible* screen, not scrollback.
const BURST_CHARS: usize = 1_600_000;
const COLS: u16 = 2000;
const ROWS: u16 = 1000;

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        // One continuous run of 'A' (no newlines) soft-wraps across
        // BURST_CHARS / COLS ≈ 800 rows of the 1000-row visible
        // screen, then marks completion and idles on `cat` (rather
        // than exiting) so a fresh attach afterward is possible: an
        // exited session is removed from the live registry and can no
        // longer be attached to at all.
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("printf '%*s' {BURST_CHARS} '' | tr ' ' 'A'; echo {DONE_MARKER}; cat"),
        ]),
        env: vec![],
        cols: COLS,
        rows: ROWS,
    }
}

#[test]
fn attach_receives_full_replay_after_over_1mib_of_visible_screen_content() {
    let daemon = common::ScratchDaemon::spawn();
    let id = "01J-p2-large-replay-test".to_string();

    // A probe attaches from the start so the burst's completion is
    // directly observable (no sleeping/polling needed): once its
    // Output stream contains DONE_MARKER, the full burst has landed in
    // the session's vt::Terminal.
    let probe = daemon.connect().expect("connect probe stream");
    common::hello(&probe);
    let reply = common::roundtrip(
        &probe,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec(&id)),
            cols: COLS,
            rows: ROWS,
        },
    )
    .expect("probe Attach round-trip");
    assert!(
        matches!(reply, ControlMsg::AttachOk { .. }),
        "expected AttachOk for probe, got {reply:?}"
    );

    let mut probe_reader = FrameReader::new(probe.try_clone().expect("clone probe for reader"));
    let mut probe_acc = Vec::new();
    loop {
        let frame = probe_reader
            .read_frame()
            .expect("read frame while waiting for DONE_MARKER");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            probe_acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&probe_acc).contains(DONE_MARKER) {
                break;
            }
        }
    }

    // Fresh attach: its Replay frame must be delivered whole. A
    // truncated/aborted delivery surfaces as a read error (broken
    // connection) rather than a well-formed Replay frame.
    let second = daemon.connect().expect("connect second stream");
    common::hello(&second);
    let reply2 = common::roundtrip(
        &second,
        &ControlMsg::Attach {
            id: id.clone(),
            create: None,
            cols: COLS,
            rows: ROWS,
        },
    )
    .expect(
        "second Attach round-trip should complete even though this session's \
         replay exceeds the 1 MiB per-client queue cap",
    );
    assert!(
        matches!(reply2, ControlMsg::AttachOk { .. }),
        "expected AttachOk for second attach, got {reply2:?}"
    );

    let mut reader2 = FrameReader::new(second.try_clone().expect("clone second for reader"));
    let mut replay_acc = Vec::new();
    while replay_acc.is_empty() {
        let frame = reader2.read_frame().expect(
            "second attach's Replay should arrive without disconnecting, even though \
             it exceeds the 1 MiB per-client queue cap",
        );
        if frame.frame_type == FrameType::Replay {
            replay_acc.extend_from_slice(&frame.payload);
        }
    }

    assert!(
        replay_acc.len() > 1_000_000,
        "replay for a session with >1 MiB of visible-screen content should itself \
         be well over the 1 MiB queue cap, got {} bytes",
        replay_acc.len()
    );
    assert!(
        replay_acc.iter().filter(|&&b| b == b'A').count() > 1_000_000,
        "replay should contain the bulk of the 'A' burst content"
    );
}
