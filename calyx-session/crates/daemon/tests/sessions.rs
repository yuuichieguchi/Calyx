//! Tests 6, 10, 13, 14 (spec): session creation visibility in `ListOk`,
//! child-exit events + registry removal, `Attach { create }`
//! idempotency, and the on-disk session ledger.

mod common;

use std::os::unix::fs::PermissionsExt;

use proto::{ControlMsg, FrameType, SessionEvent, SessionSpec, SessionState};

fn spec(id: &str, cwd: &str, argv: Vec<&str>) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: Some(cwd.to_string()),
        argv: Some(argv.into_iter().map(String::from).collect()),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

fn scratch_cwd() -> String {
    std::env::temp_dir().to_string_lossy().into_owned()
}

// ==================== Test 6 ====================

#[test]
fn new_session_appears_in_list_ok() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let cwd = scratch_cwd();
    let s = spec("01J-p2-new-session", &cwd, vec!["/bin/cat"]);

    let reply =
        common::roundtrip(&stream, &ControlMsg::New { spec: s.clone() }).expect("New round-trip");
    let info = match reply {
        ControlMsg::NewOk { info } => info,
        other => panic!("expected NewOk, got {other:?}"),
    };
    assert_eq!(info.id, s.id);
    assert_eq!(info.cwd.as_deref(), Some(cwd.as_str()));
    assert_eq!(info.state, SessionState::Running);

    let list_reply = common::roundtrip(&stream, &ControlMsg::List).expect("List round-trip");
    let sessions = match list_reply {
        ControlMsg::ListOk { sessions } => sessions,
        other => panic!("expected ListOk, got {other:?}"),
    };
    assert!(
        sessions.iter().any(|si| si.id == s.id),
        "new session should appear in ListOk, got {sessions:?}"
    );
}

// ==================== Test 10 ====================

#[test]
fn child_exit_emits_event_and_removes_session_from_list() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec(
        "01J-p2-exit-test",
        &scratch_cwd(),
        vec!["/bin/sh", "-c", "exit 7"],
    );
    let attach_reply = common::roundtrip(
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
        matches!(attach_reply, ControlMsg::AttachOk { .. }),
        "expected AttachOk, got {attach_reply:?}"
    );

    let mut reader = proto::FrameReader::new(stream.try_clone().expect("clone stream for reader"));
    // The Replay frame always precedes further activity; skip it, then
    // wait for the pushed Exited event, tolerating any Output frames
    // (e.g. shell startup noise) that may arrive first.
    let _replay = reader.read_frame().expect("read Replay frame");
    let event = loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the Exited event");
        if frame.frame_type == FrameType::Control {
            break proto::decode_control(&frame.payload).expect("decode Exited event");
        }
    };
    assert_eq!(
        event,
        ControlMsg::Event(SessionEvent::Exited {
            id: s.id.clone(),
            code: 7,
        })
    );

    let list_reply = common::roundtrip(&stream, &ControlMsg::List).expect("List round-trip");
    let sessions = match list_reply {
        ControlMsg::ListOk { sessions } => sessions,
        other => panic!("expected ListOk, got {other:?}"),
    };
    assert!(
        !sessions.iter().any(|si| si.id == s.id),
        "exited session should be removed from ListOk, got {sessions:?}"
    );
}

// ==================== Test 13 ====================

#[test]
fn attach_create_is_idempotent_for_the_same_id() {
    let daemon = common::ScratchDaemon::spawn();
    let s = spec("01J-p2-idempotent-create", &scratch_cwd(), vec!["/bin/cat"]);

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
    .expect("first Attach round-trip");
    let info_a = match reply_a {
        ControlMsg::AttachOk { info } => info,
        other => panic!("expected AttachOk, got {other:?}"),
    };

    let stream_b = daemon.connect().expect("connect stream B");
    common::hello(&stream_b);
    let reply_b = common::roundtrip(
        &stream_b,
        &ControlMsg::Attach {
            id: s.id.clone(),
            create: Some(s.clone()),
            cols: 80,
            rows: 24,
        },
    )
    .expect("second Attach round-trip");
    let info_b = match reply_b {
        ControlMsg::AttachOk { info } => info,
        other => panic!("expected AttachOk, got {other:?}"),
    };

    assert_eq!(
        info_a.created_at_ms, info_b.created_at_ms,
        "a second Attach{{create}} with the same id must target the existing \
         session (same created_at_ms) instead of spawning a new process"
    );

    let list_reply = common::roundtrip(&stream_a, &ControlMsg::List).expect("List round-trip");
    let sessions = match list_reply {
        ControlMsg::ListOk { sessions } => sessions,
        other => panic!("expected ListOk, got {other:?}"),
    };
    let session = sessions
        .iter()
        .find(|si| si.id == s.id)
        .expect("session should be listed");
    assert_eq!(
        session.attached_clients, 2,
        "both connections attaching to the same id should count as 2 attached clients"
    );
}

// ==================== Test 14 ====================

#[test]
fn sessions_ledger_is_persisted_atomically_with_0600_permissions() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let cwd = scratch_cwd();
    let s = spec("01J-p2-ledger-test", &cwd, vec!["/bin/cat"]);
    let _ =
        common::roundtrip(&stream, &ControlMsg::New { spec: s.clone() }).expect("New round-trip");

    let ledger_path = daemon.state_dir.join("sessions.json");
    let contents = common::read_with_retry(&ledger_path, common::IO_TIMEOUT)
        .expect("sessions.json should exist and be non-empty after New");

    let mode = std::fs::metadata(&ledger_path)
        .expect("stat sessions.json")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        mode, 0o600,
        "sessions.json should be mode 0600, got {mode:o}"
    );

    assert!(
        contents.contains(&s.id),
        "sessions.json should contain the session id, got: {contents}"
    );
    assert!(
        contents.contains(&cwd),
        "sessions.json should contain the session cwd, got: {contents}"
    );
}

#[test]
fn sessions_ledger_file_survives_a_daemon_restart() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec(
        "01J-p2-restart-test",
        &scratch_cwd(),
        vec!["/bin/sh", "-c", "exit 3"],
    );
    let _ =
        common::roundtrip(&stream, &ControlMsg::New { spec: s.clone() }).expect("New round-trip");

    let ledger_path = daemon.state_dir.join("sessions.json");
    let _ = common::read_with_retry(&ledger_path, common::IO_TIMEOUT)
        .expect("sessions.json should exist before restart");

    // "Restart": bind a second daemon against the same directories. P2
    // scope (per spec) stops at the ledger *file* surviving; a full
    // `ls` round-trip reconstructing state through the new process is
    // out of scope until P3.
    let config = daemon::DaemonConfig {
        runtime_dir: daemon.runtime_dir.clone(),
        state_dir: daemon.state_dir.clone(),
    };
    drop(daemon);
    let _second = std::thread::spawn(move || daemon::Daemon::bind(config)?.run_until_idle());

    let contents_after_restart = common::read_with_retry(&ledger_path, common::IO_TIMEOUT)
        .expect("sessions.json should still exist after a daemon restart");
    assert!(
        contents_after_restart.contains(&s.id),
        "sessions.json should retain the session id across a restart, got: {contents_after_restart}"
    );
}
