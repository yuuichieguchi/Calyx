//! Regression test (P2 review bug #10): a session's exit code must be
//! retrievable after it exits, via the new `ListAll` request (unlike
//! `List`, which only reports the live registry and drops a session
//! the moment it exits). P4's resume flow needs this to tell a user
//! how a session they weren't attached to ended.
//!
//! Currently `ListAll` is an unimplemented stub (a clean `Err` reply,
//! not `ListAllOk`) pending the GREEN pass; see `daemon::conn`.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionEvent, SessionSpec, SessionState};

fn spec(id: &str, code: i32) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("exit {code}"),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn list_all_reports_exit_code_of_an_exited_session() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p2-exit-code-test".to_string();
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec(&id, 5)),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    // Attaching first makes the exit directly observable (no polling):
    // wait for the pushed Exited event before asking ListAll.
    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the Exited event");
        if frame.frame_type == FrameType::Control {
            match proto::decode_control(&frame.payload).expect("decode control frame") {
                ControlMsg::Event(SessionEvent::Exited { code, .. }) => {
                    assert_eq!(code, 5);
                    break;
                }
                other => panic!("expected Exited event, got {other:?}"),
            }
        }
    }

    let list_all_reply =
        common::roundtrip(&stream, &ControlMsg::ListAll).expect("ListAll round-trip");
    let sessions = match list_all_reply {
        ControlMsg::ListAllOk { sessions } => sessions,
        other => panic!("expected ListAllOk, got {other:?}"),
    };
    let info = match sessions.iter().find(|si| si.id == id) {
        Some(info) => info,
        None => panic!(
            "ListAll should include an exited session (unlike List, which only \
             reports the live registry), got {sessions:?}"
        ),
    };
    assert_eq!(info.state, SessionState::Exited { code: 5 });
}
