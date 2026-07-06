//! P6 RED, R1: with history persistence off (the daemon's default), a
//! session that produces output and then exits leaves no history file
//! or directory behind at all (checked after the session has fully
//! torn down: "state dir inspected after output + session end", per
//! the P6 plan).
//!
//! This is a deliberate negative-space contract (see
//! crates/daemon/src/history.rs's module doc): with R2 (opt-in ON;
//! crates/daemon/tests/history_persist.rs) writing for real, it
//! stands as a permanent regression guard against a future bug that
//! writes unconditionally without checking the flag.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionEvent, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf 'HISTORY_OFF_TEST_OUTPUT\\n'; exit 0".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn disabled_history_leaves_no_history_dir_or_file_after_session_end() {
    let daemon = common::ScratchDaemon::spawn(); // history_enabled: false (the default)
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p6-history-off-test".to_string();
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

    // Wait for the session to actually exit, so teardown (and any
    // history bookkeeping alongside it) has fully run before the
    // filesystem check below.
    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the Exited event");
        if frame.frame_type == FrameType::Control {
            if let Ok(ControlMsg::Event(SessionEvent::Exited { .. })) =
                proto::decode_control(&frame.payload)
            {
                break;
            }
        }
    }

    let history_dir = daemon.state_dir.join("history");
    assert!(
        !history_dir.exists(),
        "history directory must not exist at all when history persistence is off, found: {}",
        history_dir.display()
    );
}
