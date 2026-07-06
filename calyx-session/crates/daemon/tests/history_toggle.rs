//! P6 RED, R6: the opt-in toggle's arrival path. Two contracts:
//!
//! 1. `ControlMsg::SetHistoryEnabled` is a live, mid-daemon-lifetime
//!    override: sending it flips the daemon-wide default without
//!    restarting the daemon process, and the daemon replies
//!    `SetHistoryEnabledOk` echoing the value now in effect.
//! 2. That override applies only to sessions *created* after it is
//!    processed. A session already running when the toggle flips from
//!    off to on keeps behaving as if history were off (it captured
//!    whatever was in effect at its own creation); a session created
//!    afterward gets history persistence.

mod common;

use std::os::unix::net::UnixStream;

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf 'R6_MARKER\\n'; cat".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

fn wait_for_marker(stream: &UnixStream, marker: &str) {
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
}

#[test]
fn toggling_history_on_mid_daemon_lifetime_applies_only_to_sessions_created_afterward() {
    // Bind-time default is off.
    let daemon = common::ScratchDaemon::spawn();
    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);

    // Session A, created while history is off.
    let id_a = "01J-p6-toggle-session-a".to_string();
    let stream_a = daemon.connect().expect("connect stream A");
    common::hello(&stream_a);
    let reply_a = common::roundtrip(
        &stream_a,
        &ControlMsg::Attach {
            id: id_a.clone(),
            create: Some(spec(&id_a)),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip for session A");
    assert!(matches!(reply_a, ControlMsg::AttachOk { .. }));
    wait_for_marker(&stream_a, "R6_MARKER");

    // Flip the daemon-wide default on, without restarting the daemon.
    let toggle_reply =
        common::roundtrip(&control, &ControlMsg::SetHistoryEnabled { enabled: true })
            .expect("SetHistoryEnabled round-trip");
    assert_eq!(
        toggle_reply,
        ControlMsg::SetHistoryEnabledOk { enabled: true },
        "SetHistoryEnabled should reply with the value now in effect"
    );

    // Session B, created after the toggle.
    let id_b = "01J-p6-toggle-session-b".to_string();
    let stream_b = daemon.connect().expect("connect stream B");
    common::hello(&stream_b);
    let reply_b = common::roundtrip(
        &stream_b,
        &ControlMsg::Attach {
            id: id_b.clone(),
            create: Some(spec(&id_b)),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip for session B");
    assert!(matches!(reply_b, ControlMsg::AttachOk { .. }));
    wait_for_marker(&stream_b, "R6_MARKER");

    let history_path_a = daemon.state_dir.join("history").join(format!("{id_a}.raw"));
    let history_path_b = daemon.state_dir.join("history").join(format!("{id_b}.raw"));

    assert!(
        !history_path_a.exists(),
        "session A predates the toggle and should never get history persistence, found: {}",
        history_path_a.display()
    );
    common::read_with_retry(&history_path_b, common::IO_TIMEOUT)
        .expect("session B was created after the toggle flipped on and should have a history file");
}
