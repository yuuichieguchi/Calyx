//! P6 RED, R2: with history persistence explicitly enabled, a
//! session's raw PTY output is appended byte-for-byte to
//! `$STATE_DIR/history/<id>.raw` (file mode 0600, parent dir mode
//! 0700).
//!
//! Byte-level oracle: rather than assuming what a shell's `printf`
//! "logically" produces (PTY line-discipline translation can rewrite
//! bytes, e.g. `\n` -> `\r\n`), this test compares the on-disk history
//! file's bytes against the *same* daemon's live `Output` mirror for
//! the same session: an independently-exercised, already-tested code
//! path (see crates/daemon/tests/attach.rs), not the implementation
//! under test. Both are fed from the identical successive `chunk`s the
//! session thread reads off the PTY, in the same order, so the two
//! must match exactly.
//!
//! The `Replay` frame is deliberately *not* part of the mirror: replay
//! is a *rendered* snapshot, and its bytes begin with a synthesized
//! reset/clear/tab-stop preamble that never crossed the PTY, so it can
//! never be byte-identical to raw PTY output. Attaching in the same
//! request that creates the session means that snapshot is rendered
//! from the still-empty terminal before the child's first output
//! (attach requests are enqueued while the create still holds the
//! registry lock, and the session thread serves its mailbox before
//! each PTY read), leaving the Output stream as the complete raw
//! record.

mod common;

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

const DONE_MARKER: &str = "R2_DONE_MARKER";

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("printf 'HISTORY_PERSIST_TEST_PAYLOAD\\n{DONE_MARKER}\\n'; cat"),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

/// Like `common::read_with_retry`, but for raw bytes rather than a
/// UTF-8 string: a history file is not guaranteed to hold valid UTF-8
/// in general, even though this test's own fixture output happens to
/// be plain ASCII. Retries (rather than a single read) because the
/// history append for the bytes this test just observed live may not
/// have reached disk at the exact instant this function is first
/// called.
fn read_bytes_with_retry(path: &Path, timeout: Duration) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    let mut last_err = None;
    while Instant::now() < deadline {
        match std::fs::read(path) {
            Ok(bytes) if !bytes.is_empty() => return Ok(bytes),
            Ok(_) => {}
            Err(e) => last_err = Some(e),
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(last_err.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::TimedOut, "file never appeared with content")
    }))
}

#[test]
fn opt_in_history_persists_exact_pty_output_bytes_with_expected_permissions() {
    let daemon = common::ScratchDaemon::spawn_with_history_enabled();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p6-history-persist-test".to_string();
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
    let mut live_output = Vec::new();
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for DONE_MARKER");
        // Output frames only; see the module doc for why the Replay
        // frame is excluded from the raw mirror.
        if frame.frame_type == FrameType::Output {
            live_output.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&live_output).contains(DONE_MARKER) {
                break;
            }
        }
    }

    let history_dir = daemon.state_dir.join("history");
    let history_path = history_dir.join(format!("{id}.raw"));

    let history_bytes = read_bytes_with_retry(&history_path, common::IO_TIMEOUT)
        .expect("history file should exist and contain the session's output");

    assert_eq!(
        history_bytes, live_output,
        "on-disk history bytes must exactly match the live Output mirror for the same session"
    );

    let history_dir_mode = std::fs::metadata(&history_dir)
        .expect("stat history dir")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        history_dir_mode, 0o700,
        "history directory should be mode 0700, got {history_dir_mode:o}"
    );

    let history_file_mode = std::fs::metadata(&history_path)
        .expect("stat history file")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        history_file_mode, 0o600,
        "history file should be mode 0600, got {history_file_mode:o}"
    );
}
