//! Regression test (P2 review bug #6): once a client has seen its
//! session's `Exited` event, the daemon must close that client's
//! connection promptly (finish its `OutQueue`, stopping the writer
//! thread) rather than leave it open forever. Currently, the session
//! thread's exit path pushes the `Exited` event to each attached
//! client's queue but never calls `OutQueue::finish`/`abort` on it, so
//! the writer thread loops back into `pop()` and blocks indefinitely —
//! the connection only ever closes if the *client* hangs up first. Left
//! open, this also means `total_clients` never drops for that
//! connection, which is what would let the daemon reach its idle state.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, ProtoError, SessionEvent, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exit 0".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn client_connection_is_closed_promptly_after_its_session_exits() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p2-exit-close-test".to_string();
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

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let exit_code = loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the Exited event");
        if frame.frame_type == FrameType::Control {
            match proto::decode_control(&frame.payload).expect("decode control frame") {
                ControlMsg::Event(SessionEvent::Exited { code, .. }) => break code,
                other => panic!("expected Exited event, got {other:?}"),
            }
        }
    };
    assert_eq!(exit_code, 0);

    // Once this client has seen its session's Exited event, the daemon
    // must proactively close the connection: a further read must see a
    // clean EOF, bounded by the stream's read timeout rather than
    // hanging indefinitely.
    let result = reader.read_frame();
    assert!(
        matches!(
            result,
            Err(ProtoError::Io(ref e)) if e.kind() == std::io::ErrorKind::UnexpectedEof
        ),
        "expected a clean EOF after the session's Exited event (the daemon should \
         finish/close this client's connection), got {result:?}"
    );
}
