//! Tests 7, 8, 9, 11 (spec): attach lifecycle echo, replay on a fresh
//! attach, resize propagation, and multi-client fan-out.

mod common;

use std::os::unix::net::UnixStream;

use proto::{ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec};

fn spec(id: &str, argv: Vec<&str>) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(argv.into_iter().map(String::from).collect()),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

/// Reads frames (skipping any interleaved `Control` frames) until
/// `needle` has appeared across the concatenated `Output`/`Replay`
/// payloads, or a read times out.
fn read_until_contains(reader: &mut FrameReader<UnixStream>, needle: &str) -> String {
    let mut acc = Vec::new();
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for expected output");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            let text = String::from_utf8_lossy(&acc).into_owned();
            if text.contains(needle) {
                return text;
            }
        }
    }
}

// ==================== Test 7 ====================

#[test]
fn attach_and_input_is_echoed_back_as_output() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec("01J-p2-echo-test", vec!["/bin/cat"]);
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: Some(s.clone()),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(
        matches!(reply, ControlMsg::AttachOk { .. }),
        "expected AttachOk, got {reply:?}"
    );

    let mut writer = FrameWriter::new(stream.try_clone().expect("clone for writer"));
    writer
        .write_frame(FrameType::Input, b"hello\n")
        .expect("write Input frame");

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let output = read_until_contains(&mut reader, "hello");
    assert!(
        output.contains("hello"),
        "expected echoed 'hello' in output, got {output:?}"
    );
}

// ==================== Test 8 ====================

#[test]
fn new_attach_receives_a_replay_frame_with_prior_output() {
    let daemon = common::ScratchDaemon::spawn();
    let s = spec("01J-p2-replay-test", vec!["/bin/sh"]);

    let first = daemon.connect().expect("connect first stream");
    common::hello(&first);
    let reply = common::roundtrip(
        &first,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: Some(s.clone()),
            cols: 80,
            rows: 24,
        },
    )
    .expect("first Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let mut writer = FrameWriter::new(first.try_clone().expect("clone for writer"));
    writer
        .write_frame(FrameType::Input, b"printf 'MARKER\\n'\n")
        .expect("write Input frame");

    let mut reader = FrameReader::new(first.try_clone().expect("clone for reader"));
    let _ = read_until_contains(&mut reader, "MARKER");

    // A second, independent connection attaches to the same session and
    // must be caught up via a Replay frame before anything else.
    let second = daemon.connect().expect("connect second stream");
    common::hello(&second);
    let reply2 = common::roundtrip(
        &second,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: None,
            cols: 80,
            rows: 24,
        },
    )
    .expect("second Attach round-trip");
    assert!(matches!(reply2, ControlMsg::AttachOk { .. }));

    let mut reader2 = FrameReader::new(second.try_clone().expect("clone for reader2"));
    let replay_frame = reader2
        .read_frame()
        .expect("read first frame after second AttachOk");
    assert_eq!(
        replay_frame.frame_type,
        FrameType::Replay,
        "the first frame after AttachOk on a new attach must be a Replay frame"
    );
    assert!(
        String::from_utf8_lossy(&replay_frame.payload).contains("MARKER"),
        "replay frame should contain prior output, got {:?}",
        String::from_utf8_lossy(&replay_frame.payload)
    );
}

// ==================== Test 9 ====================

#[test]
fn resize_propagates_to_the_pty_and_is_visible_via_stty_size() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec(
        "01J-p2-resize-test",
        vec!["/bin/sh", "-c", "sleep 0.2; stty size"],
    );
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: Some(s.clone()),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    // Resize has no dedicated *Ok reply (fire-and-forget per the
    // protocol contract), so send it directly rather than via
    // `common::roundtrip`.
    common::write_control(
        &stream,
        &ControlMsg::Resize {
            cols: 100,
            rows: 30,
        },
    )
    .expect("write Resize frame");

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let output = read_until_contains(&mut reader, "30 100");
    assert!(
        output.contains("30 100"),
        "expected `stty size` output '30 100' after Resize{{100,30}}, got {output:?}"
    );
}

// ==================== Test 11 ====================

#[test]
fn two_attached_clients_both_receive_echoed_input_from_either() {
    let daemon = common::ScratchDaemon::spawn();
    let s = spec("01J-p2-multi-client-test", vec!["/bin/cat"]);

    let stream_a = daemon.connect().expect("connect stream A");
    common::hello(&stream_a);
    let reply_a = common::roundtrip(
        &stream_a,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: Some(s.clone()),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach A round-trip");
    assert!(matches!(reply_a, ControlMsg::AttachOk { .. }));

    let stream_b = daemon.connect().expect("connect stream B");
    common::hello(&stream_b);
    let reply_b = common::roundtrip(
        &stream_b,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: None,
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach B round-trip");
    assert!(matches!(reply_b, ControlMsg::AttachOk { .. }));

    let mut writer_a = FrameWriter::new(stream_a.try_clone().expect("clone A writer"));
    writer_a
        .write_frame(FrameType::Input, b"shared\n")
        .expect("write Input on A");

    let mut reader_a = FrameReader::new(stream_a.try_clone().expect("clone A reader"));
    let mut reader_b = FrameReader::new(stream_b.try_clone().expect("clone B reader"));
    let output_a = read_until_contains(&mut reader_a, "shared");
    let output_b = read_until_contains(&mut reader_b, "shared");
    assert!(
        output_a.contains("shared"),
        "client A should see its own echoed input"
    );
    assert!(
        output_b.contains("shared"),
        "client B should also see input typed by client A"
    );
}
