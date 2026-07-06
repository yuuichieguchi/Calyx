//! RED (exited-session garbage accumulation defect): the on-disk ledger
//! (`state_dir/sessions.json`) never removes `Exited` entries today --
//! no removal code exists at all in `ledger.rs`/`state.rs` -- so they
//! accumulate forever and every one of them also surfaces permanently
//! in `SessionBrowserModel`'s rows (Swift side; see
//! `SessionBrowserModelTests`). A real ledger was observed carrying 7
//! stale `Exited(137)` rows this way. These tests exercise the fix
//! end to end through the real `Daemon::bind`/`run_until_idle` path
//! (unlike `ledger::gc`'s own pure-function unit tests in
//! `daemon::ledger`'s `#[cfg(test)]` module, which stub the retention
//! logic itself): a stale `Exited` ledger record present before bind
//! must not reappear in `ListAll` after it, and a session that exits
//! for real must have its ledger record's `exited_at_ms` stamped (the
//! timestamp the retention GC keys off of).

mod common;

use std::io::Write;
use std::os::unix::fs::PermissionsExt;

use proto::{ControlMsg, FrameReader, FrameType, SessionEvent, SessionSpec, SessionState};

fn write_ledger_fixture(state_dir: &std::path::Path, json: &str) {
    std::fs::create_dir_all(state_dir).expect("create scratch state dir");
    let path = state_dir.join("sessions.json");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .expect("create scratch sessions.json fixture");
    file.write_all(json.as_bytes())
        .expect("write scratch sessions.json fixture");
    // Mirror the real ledger's 0600 permissions so this fixture is
    // indistinguishable from one `ledger::write` produced.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .expect("chmod scratch sessions.json fixture");
}

/// RED: a stale `Exited` record present in `sessions.json` before the
/// daemon ever binds (the exact shape a pre-this-fix ledger left
/// behind: no `exited_at_ms` key at all) must be gone from `ListAll`
/// once the daemon has bound -- today nothing in `Daemon::bind`/
/// `run_until_idle` ever drops a ledger entry, so this record survives
/// unchanged and this assertion fails.
#[test]
fn stale_legacy_exited_entry_is_gone_from_list_all_after_bind() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");

    write_ledger_fixture(
        &state_dir,
        r#"[{
            "id": "01J-gc-e2e-legacy-stale",
            "name": null,
            "cwd": null,
            "state": {"Exited": {"code": 137}},
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 0,
            "meta": {}
        }, {
            "id": "01J-gc-e2e-running",
            "name": null,
            "cwd": null,
            "state": "Running",
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 999999,
            "meta": {}
        }]"#,
    );

    let config = daemon::DaemonConfig {
        runtime_dir: runtime_dir.clone(),
        state_dir: state_dir.clone(),
        history_enabled: false,
    };
    let socket_path = runtime_dir.join(daemon::SOCKET_FILE);
    let _handle = std::thread::spawn(move || daemon::Daemon::bind(config)?.run_until_idle());

    let stream = common::connect_with_timeout(&socket_path, common::CONNECT_TIMEOUT)
        .expect("connect to daemon socket after bind");
    common::hello(&stream);

    let reply = common::roundtrip(&stream, &ControlMsg::ListAll).expect("ListAll round-trip");
    let sessions = match reply {
        ControlMsg::ListAllOk { sessions } => sessions,
        other => panic!("expected ListAllOk, got {other:?}"),
    };

    assert!(
        !sessions.iter().any(|si| si.id == "01J-gc-e2e-legacy-stale"),
        "a stale legacy Exited ledger record (no exited_at_ms, predating this GC) must not \
         survive a daemon bind -- ledger GC must run at bind time and drop it, got {sessions:?}"
    );
    assert!(
        sessions.iter().any(|si| si.id == "01J-gc-e2e-running"),
        "a Running ledger record must survive bind untouched, got {sessions:?}"
    );
}

/// RED: once a real session exits, its ledger record's `exited_at_ms`
/// must be stamped with the wall-clock time of the exit -- the
/// retention GC keys its "how long ago did this exit" decision off
/// this field, so a build that never stamps it (today: nothing does)
/// would treat every real exit as already-expired the moment GC lands,
/// deleting exit codes P4's resume flow still needs to read.
#[test]
fn a_real_exit_stamps_exited_at_ms_on_the_ledger_record() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-gc-e2e-stamp-test".to_string();
    let spec = SessionSpec {
        id: id.clone(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exit 3".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    };
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let before_exit_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock should be after the Unix epoch")
        .as_millis() as u64;

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

    let list_all_reply =
        common::roundtrip(&stream, &ControlMsg::ListAll).expect("ListAll round-trip");
    let sessions = match list_all_reply {
        ControlMsg::ListAllOk { sessions } => sessions,
        other => panic!("expected ListAllOk, got {other:?}"),
    };
    let info = sessions
        .iter()
        .find(|si| si.id == id)
        .expect("ListAll should still include the just-exited session");
    assert_eq!(info.state, SessionState::Exited { code: 3 });

    let exited_at_ms = info.exited_at_ms.expect(
        "a session's ledger record must have exited_at_ms populated once it has actually \
         exited -- the retention GC has nothing to key its age check off of otherwise",
    );
    assert!(
        exited_at_ms >= before_exit_ms,
        "exited_at_ms ({exited_at_ms}) should be at or after the wall-clock time just before \
         the Exited event was observed ({before_exit_ms})"
    );
}
