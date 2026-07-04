//! Regression test (P2 review bug #9): `CALYX_SESSION_ID` must always
//! reflect the real session id inside the spawned shell, even if
//! `SessionSpec.env` tries to set a different value. `spawn_session`
//! currently sets `CALYX_SESSION_ID` first and then applies
//! `spec.env` on top via repeated `Command::env` calls — and later
//! calls override earlier ones for the same key — so a client-supplied
//! `env` entry for that name silently wins.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

#[test]
fn calyx_session_id_env_var_cannot_be_overridden_by_spec_env() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p2-session-id-override-test".to_string();
    let s = SessionSpec {
        id: id.clone(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "echo \"ID=$CALYX_SESSION_ID\"".to_string(),
        ]),
        env: vec![("CALYX_SESSION_ID".to_string(), "bogus".to_string())],
        cols: 80,
        rows: 24,
    };

    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(s),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let mut acc = Vec::new();
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the echoed ID= line");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&acc).contains("ID=") {
                break;
            }
        }
    }

    let output = String::from_utf8_lossy(&acc);
    assert!(
        output.contains(&format!("ID={id}")),
        "CALYX_SESSION_ID inside the session should be the real session id, got {output:?}"
    );
    assert!(
        !output.contains("ID=bogus"),
        "spec.env should not be able to override CALYX_SESSION_ID, got {output:?}"
    );
}
