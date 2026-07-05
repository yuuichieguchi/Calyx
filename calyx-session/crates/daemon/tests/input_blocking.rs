//! Regression test (P2 review bug #5): a large `Input` frame to a
//! session whose child never reads its stdin must not block that
//! *connection's* reader thread from dispatching subsequent control
//! messages. `forward_input` writes synchronously to the PTY master on
//! the same thread that reads and dispatches every frame for a
//! connection; once the kernel's tty input queue fills up, that write
//! blocks, wedging the reader until something drains the PTY — which
//! never happens here, since the child is asleep.
//!
//! The tty must be in raw mode with echo disabled first (`stty raw
//! -echo`): with echo left on, the kernel mirrors input bytes straight
//! back to the output side, which the session thread's own read loop
//! keeps draining as fast as it arrives, masking the bug entirely.
//! With echo off but still in canonical (cooked) mode, this platform's
//! pty apparently never blocks a master-side write at all (verified
//! empirically up to a 15 MiB single Input frame). Only with `raw`
//! *and* `-echo` together does the input queue exhibit an actual fixed
//! capacity — confirmed empirically (via a standalone probe outside
//! this daemon) to block a nonblocking write after ~2.4 MiB on this
//! platform — so an Input burst comfortably over that is what this
//! test needs.
//!
//! The client's own write of the (moderately sized, well within any
//! plausible tty input queue) Input frame completes cleanly regardless
//! of the bug — the daemon actively drains the socket while *reading*
//! the frame; only *dispatching* it (the PTY write) can then block —
//! so this needs no timeout tricks on the write side. The follow-up
//! `List` on the same connection is bounded by the stream's existing
//! read timeout.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "stty raw -echo; echo READY; sleep 5".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn input_burst_does_not_block_subsequent_control_on_the_same_connection() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p2-input-block-test".to_string();
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec(&id)),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    // Deterministic sync point: `echo READY`'s own stdout is visible
    // regardless of the tty's echo setting, so waiting for it (rather
    // than sleeping) guarantees `stty -echo` has already taken effect
    // by the time the Input burst below is sent.
    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let mut acc = Vec::new();
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for READY");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&acc).contains("READY") {
                break;
            }
        }
    }

    let mut writer = FrameWriter::new(stream.try_clone().expect("clone for writer"));
    writer
        .write_frame(FrameType::Input, &vec![b'x'; 15 * 1024 * 1024])
        .expect("write large Input frame");

    // A control message on the *same* connection must still be
    // processed promptly: if the reader thread is stuck inside a
    // blocking PTY write (forwarding the input above), this times out.
    common::write_control(
        &stream,
        &ControlMsg::Resize {
            cols: 100,
            rows: 30,
        },
    )
    .expect("write Resize frame");
    let list_reply = common::roundtrip(&stream, &ControlMsg::List).expect(
        "List on the same connection should complete promptly even after a large \
         Input frame to a child that never reads stdin (the reader thread must not \
         block on the PTY write)",
    );
    assert!(matches!(list_reply, ControlMsg::ListOk { .. }));
}
