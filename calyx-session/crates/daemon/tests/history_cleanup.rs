//! P6 RED, R4: history exists to survive a daemon crash, not an
//! individual session's own end (see crates/daemon/src/history.rs's
//! module doc): on any session teardown, killed or exited normally,
//! the daemon deletes that session's history file(s).

mod common;

use std::os::unix::net::UnixStream;

use proto::{ControlMsg, FrameReader, FrameType, SessionEvent, SessionSpec};

fn long_lived_spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf 'R4_ALIVE_MARKER\\n'; cat".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

fn exits_after_a_short_delay_spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        // The delay (baked into the fixture child, not into this
        // test's own synchronization) gives a reliable window, after
        // the marker is observed live but before the child actually
        // exits, in which to check the history file exists while the
        // session is still alive. Mirrors the existing
        // resize-propagation test's `sleep 0.2; stty size` fixture
        // (crates/daemon/tests/attach.rs).
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf 'R4_EXIT_MARKER\\n'; sleep 0.3; exit 7".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

/// Attaches, creating `spec`'s session, and blocks until its first
/// live Output/Replay bytes containing `marker` arrive: proof the
/// session has actually started producing output, so a subsequent
/// history-file check isn't racing session startup.
fn attach_and_wait_for_marker(
    daemon: &common::ScratchDaemon,
    spec: SessionSpec,
    marker: &str,
) -> UnixStream {
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: spec.id.clone(),
            create: Some(spec),
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
            .expect("read frame while waiting for marker");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&acc).contains(marker) {
                break;
            }
        }
    }
    stream
}

#[test]
fn killing_a_session_removes_its_history_file() {
    let daemon = common::ScratchDaemon::spawn_with_history_enabled();
    let id = "01J-p6-history-kill-cleanup-test".to_string();
    let _stream = attach_and_wait_for_marker(&daemon, long_lived_spec(&id), "R4_ALIVE_MARKER");

    let history_path = daemon.state_dir.join("history").join(format!("{id}.raw"));
    common::read_with_retry(&history_path, common::IO_TIMEOUT)
        .expect("history file should exist while the session is alive and producing output");

    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);
    let reply =
        common::roundtrip(&control, &ControlMsg::Kill { id: id.clone() }).expect("Kill round-trip");
    assert!(
        matches!(reply, ControlMsg::KillOk),
        "expected KillOk, got {reply:?}"
    );

    assert!(
        !history_path.exists(),
        "history file must be removed once a session is killed, found: {}",
        history_path.display()
    );
}

#[test]
fn a_session_that_exits_on_its_own_also_removes_its_history_file() {
    let daemon = common::ScratchDaemon::spawn_with_history_enabled();
    let id = "01J-p6-history-exit-cleanup-test".to_string();
    let stream = attach_and_wait_for_marker(
        &daemon,
        exits_after_a_short_delay_spec(&id),
        "R4_EXIT_MARKER",
    );

    let history_path = daemon.state_dir.join("history").join(format!("{id}.raw"));
    // The child is still alive here (its `sleep 0.3` hasn't elapsed
    // yet): the history file existing at this point specifically rules
    // out "the file only ever appears after teardown" as an
    // (incorrect) explanation for the post-exit absence check below.
    common::read_with_retry(&history_path, common::IO_TIMEOUT)
        .expect("history file should exist while the session is alive and producing output");

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

    assert!(
        !history_path.exists(),
        "history file must be removed once a session exits on its own (history exists to \
         survive a daemon crash, not an individual session's own end), found: {}",
        history_path.display()
    );
}

/// R3 (team-lead RED assignment, B2): teardown cleanup today is gated
/// on the *daemon-wide* `history_enabled` flag alone
/// (`crates/daemon/src/session.rs:966`), the same asymmetry R1/R2
/// exercise on the create side. A session created while a leftover
/// history file for its id already exists must have that file (and its
/// rotation) removed on kill, even when the daemon-wide flag is off:
/// the file's existence at creation is what proves this particular
/// session opted in for its own lifetime (see
/// crates/daemon/tests/history_crash_restore.rs's R1/R2), and cleanup
/// must honor the same proof, not the flag alone.
///
/// The leftover file is manufactured directly (`fs::write`, mirroring
/// crates/daemon/src/history.rs's own unit tests) rather than via a
/// full two-daemon-generation crash simulation: what is under test
/// here is teardown's cleanup gating, not the seed path R1/R2 already
/// cover, so a single flag-off `ScratchDaemon` with a pre-existing file
/// is the smaller, sufficient reproduction.
#[test]
fn killing_a_session_removes_leftover_history_files_even_when_the_daemon_flag_is_off() {
    let daemon = common::ScratchDaemon::spawn(); // history_enabled: false (the default)
    let id = "01J-p6-r3-cleanup-flag-off-test";

    let history_dir = daemon.state_dir.join("history");
    std::fs::create_dir_all(&history_dir).expect("create scratch history dir");
    let history_path = history_dir.join(format!("{id}.raw"));
    std::fs::write(&history_path, b"LEFTOVER_FROM_A_PRIOR_CRASH\n")
        .expect("write scratch leftover history file, standing in for a prior crash's file");

    let spec = SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf 'R3_ALIVE_MARKER\\n'; cat".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    };
    let _stream = attach_and_wait_for_marker(&daemon, spec, "R3_ALIVE_MARKER");

    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);
    let reply = common::roundtrip(&control, &ControlMsg::Kill { id: id.to_string() })
        .expect("Kill round-trip");
    assert!(
        matches!(reply, ControlMsg::KillOk),
        "expected KillOk, got {reply:?}"
    );

    assert!(
        !history_path.exists(),
        "a history file left over from a prior crash must be removed on kill even when the \
         daemon-wide history flag is off, since the file's existence at session creation is \
         what proves this session opted in for its own lifetime, found: {}",
        history_path.display()
    );
}
