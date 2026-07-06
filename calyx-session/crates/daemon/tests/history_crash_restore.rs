//! P6 RED, R5 (integration half): after a history file for some
//! session id already exists on disk, simulating a crash (the file
//! was never cleaned up because the daemon process ended before
//! running that session's teardown; see
//! crates/daemon/src/history.rs's module doc), a second daemon
//! generation bound against the same runtime/state directories,
//! receiving `Attach{id, create}` for that same id, must seed the
//! freshly created session's terminal from the persisted bytes: the
//! client's `Replay` frame contains pre-crash content.
//!
//! Decomposition (per the P6 plan): this test does not attempt to
//! actually kill and restart the daemon *process* (this workspace's
//! daemon runs in-process via a spawned thread rather than a
//! subprocess in these integration tests, so there is no real process
//! to kill, and killing the test binary itself would just end the
//! test). It reuses the same "bind a second daemon generation against
//! the same directories" idiom the existing ledger-restart test
//! already establishes
//! (crates/daemon/tests/sessions.rs,
//! `sessions_ledger_file_survives_a_daemon_restart`), and manufactures
//! the "crash" precondition directly: a pre-existing history file with
//! known content, kept alive by never killing or letting the
//! first-generation session exit (either would trigger R4's cleanup,
//! which is the opposite of what a crash leaves behind), plus a
//! *second* generation whose in-memory registry starts out completely
//! empty regardless of what is on disk, exactly like a real
//! post-crash restart. The pure data-plumbing half (`read_persisted`
//! correctly concatenating and ordering rotated + active file bytes,
//! then seeding a fresh `vt::Terminal`) is unit-tested directly in
//! crates/daemon/src/history.rs; see
//! `read_persisted_concatenates_rotated_then_active_and_seeds_a_fresh_terminal`.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

const PRECRASH_MARKER: &str = "PRECRASH_MARKER_CONTENT";

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

#[test]
fn session_create_after_a_crash_seeds_replay_from_leftover_history() {
    let daemon1 = common::ScratchDaemon::spawn_with_history_enabled();
    let id = "01J-p6-crash-restore-test".to_string();

    // A live session on the first ("pre-crash") daemon generation,
    // kept running (never killed, never let exit) so its own teardown
    // never runs and its history file is never cleaned up on its own
    // account: exactly the state a crash leaves behind.
    let stream1 = daemon1
        .connect()
        .expect("connect to first daemon generation");
    common::hello(&stream1);
    let printf_cmd = format!("printf '{PRECRASH_MARKER}\\n'; cat");
    let reply = common::roundtrip(
        &stream1,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec(&id, vec!["/bin/sh", "-c", &printf_cmd])),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip on first daemon generation");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let mut reader1 = FrameReader::new(stream1.try_clone().expect("clone for reader"));
    loop {
        let frame = reader1
            .read_frame()
            .expect("read frame while waiting for PRECRASH_MARKER");
        if (frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay)
            && String::from_utf8_lossy(&frame.payload).contains(PRECRASH_MARKER)
        {
            break;
        }
    }

    let history_path = daemon1.state_dir.join("history").join(format!("{id}.raw"));
    common::read_with_retry(&history_path, common::IO_TIMEOUT)
        .expect("history file should exist and contain pre-crash content");

    // "Restart": bind a second daemon generation directly against the
    // same directories (mirrors sessions.rs's
    // sessions_ledger_file_survives_a_daemon_restart), without
    // dropping the first daemon's ScratchDaemon: its backing tempdir
    // must stay on disk, since dropping it would delete the
    // just-written history file, the opposite of what a crash leaves
    // behind.
    let config = daemon::DaemonConfig {
        runtime_dir: daemon1.runtime_dir.clone(),
        state_dir: daemon1.state_dir.clone(),
        history_enabled: true,
    };
    let _daemon2 = std::thread::spawn(move || daemon::Daemon::bind(config)?.run_until_idle());

    // The second generation's fresh, empty in-memory registry means
    // `Attach{id, create}` for the same id takes the "create" branch
    // (a brand new PTY/child), exactly like a real restart recreating
    // a session that was live when the daemon died.
    let stream2 = daemon1
        .connect()
        .expect("connect to second daemon generation");
    common::hello(&stream2);
    let reply2 = common::roundtrip(
        &stream2,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(spec(&id, vec!["/bin/cat"])),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach{create} round-trip on second daemon generation");
    assert!(
        matches!(reply2, ControlMsg::AttachOk { .. }),
        "expected AttachOk, got {reply2:?}"
    );

    let mut reader2 = FrameReader::new(stream2.try_clone().expect("clone for reader"));
    let replay_frame = reader2
        .read_frame()
        .expect("read first frame after second-generation AttachOk");
    assert_eq!(
        replay_frame.frame_type,
        FrameType::Replay,
        "the first frame after AttachOk on a new attach must be a Replay frame"
    );
    assert!(
        String::from_utf8_lossy(&replay_frame.payload).contains(PRECRASH_MARKER),
        "a session recreated after a crash, with an existing history file, should seed its \
         fresh terminal from the persisted bytes so the Replay a client receives contains \
         pre-crash content; got: {:?}",
        String::from_utf8_lossy(&replay_frame.payload)
    );
}
