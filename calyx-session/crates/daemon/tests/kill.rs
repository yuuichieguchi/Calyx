//! Test 12 (spec): `Kill` -> `KillOk` -> the child process is actually
//! gone (`kill -0`), not just removed from the registry.

mod common;

use proto::{ControlMsg, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec!["/bin/cat".to_string()]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn kill_terminates_the_child_process() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec("01J-p2-kill-test");
    let reply =
        common::roundtrip(&stream, &ControlMsg::New { spec: s.clone() }).expect("New round-trip");
    let info = match reply {
        ControlMsg::NewOk { info } => info,
        other => panic!("expected NewOk, got {other:?}"),
    };
    assert_ne!(
        info.pid, 0,
        "a Running session should report a non-zero pid"
    );

    let kill_reply = common::roundtrip(&stream, &ControlMsg::Kill { id: s.id.clone() })
        .expect("Kill round-trip");
    assert!(
        matches!(kill_reply, ControlMsg::KillOk),
        "expected KillOk, got {kill_reply:?}"
    );

    // `kill(pid, 0)` succeeds (no signal sent) iff the process still
    // exists and is signalable by us; ESRCH means it's actually gone.
    let still_alive = unsafe { libc::kill(info.pid as libc::pid_t, 0) } == 0;
    assert!(
        !still_alive,
        "pid {} should no longer exist after Kill/KillOk (kill -0 unexpectedly succeeded)",
        info.pid
    );

    let list_reply = common::roundtrip(&stream, &ControlMsg::List).expect("List round-trip");
    let sessions = match list_reply {
        ControlMsg::ListOk { sessions } => sessions,
        other => panic!("expected ListOk, got {other:?}"),
    };
    assert!(
        !sessions.iter().any(|si| si.id == s.id),
        "killed session should be removed from ListOk, got {sessions:?}"
    );
}
