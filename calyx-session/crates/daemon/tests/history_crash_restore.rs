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

use std::os::unix::net::UnixStream;

use proto::{ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec};

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

/// Sets up the "pre-crash" half of the crash-restore scenario shared by
/// every test in this file: a live session for `id` on a first daemon
/// generation with history enabled, kept running (never killed, never
/// let exit, so its own teardown never runs and its history file is
/// never cleaned up on its own account -- exactly the state a crash
/// leaves behind) until its output contains `PRECRASH_MARKER`, with the
/// on-disk history file confirmed present and containing that marker.
///
/// Returns the first-generation `ScratchDaemon`, which the caller must
/// keep alive (not drop) for as long as the "crashed" state needs to
/// survive: dropping it tears down its backing tempdir and deletes the
/// just-written history file, the opposite of what a real crash leaves
/// behind.
fn precrash_session(id: &str) -> common::ScratchDaemon {
    let daemon1 = common::ScratchDaemon::spawn_with_history_enabled();

    let stream1 = daemon1
        .connect()
        .expect("connect to first daemon generation");
    common::hello(&stream1);
    let printf_cmd = format!("printf '{PRECRASH_MARKER}\\n'; cat");
    let reply = common::roundtrip(
        &stream1,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: Some(spec(id, vec!["/bin/sh", "-c", &printf_cmd])),
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

    daemon1
}

/// Retries `daemon.connect()` (each attempt a fresh connection) until
/// one lands on a daemon generation whose live `GetHistoryEnabled`
/// answer matches `expected_history_enabled`, and returns that already
/// hello'd connection.
///
/// Needed because `Daemon::bind` unlinks and rebinds
/// `runtime_dir/sessiond.sock` in place (`crates/daemon/src/lib.rs`'s
/// `bind`) rather than requiring the caller to wait for a clean
/// handover: right after spawning a second daemon generation's thread,
/// the *first* generation's listener is still open and still accepting
/// on the not-yet-unlinked path, so a plain `daemon.connect()` issued
/// immediately afterward can just as easily land back on the first
/// generation as on the second. For the ON-ON scenario that
/// ambiguity happens not to matter (either generation's `Replay`
/// contains the marker), but the ON-OFF tests below need to prove
/// something specifically about the *second* generation's behavior, so
/// they must not silently pass by exercising the first one instead.
fn connect_until_history_flag_is(
    daemon: &common::ScratchDaemon,
    expected_history_enabled: bool,
) -> UnixStream {
    let deadline = std::time::Instant::now() + common::IO_TIMEOUT;
    loop {
        let stream = daemon
            .connect()
            .expect("connect to whichever daemon generation is currently serving this socket");
        common::hello(&stream);
        let reply = common::roundtrip(&stream, &ControlMsg::GetHistoryEnabled)
            .expect("GetHistoryEnabled round-trip");
        match reply {
            ControlMsg::HistoryEnabled { enabled } if enabled == expected_history_enabled => {
                return stream;
            }
            ControlMsg::HistoryEnabled { .. } => {
                if std::time::Instant::now() >= deadline {
                    panic!(
                        "never observed a daemon generation reporting history_enabled = \
                         {expected_history_enabled} within {:?} (still only reaching a \
                         generation with the other value)",
                        common::IO_TIMEOUT
                    );
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            other => panic!("expected a HistoryEnabled reply, got {other:?}"),
        }
    }
}

#[test]
fn session_create_after_a_crash_seeds_replay_from_leftover_history() {
    let id = "01J-p6-crash-restore-test";
    let daemon1 = precrash_session(id);

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
            id: id.to_string(),
            create: Some(spec(id, vec!["/bin/cat"])),
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

/// R1 (team-lead RED assignment, B1): the ON-OFF case the existing
/// ON-ON test above does not cover. A real auto-respawned daemon (e.g.
/// `attach --create` racing a crashed daemon back to life) binds with
/// whatever `DaemonConfig::history_enabled` its config resolves to at
/// bind time -- the live `SetHistoryEnabled` override that may have
/// been in effect died with the crashed process, so this is the
/// bind-time default, `false` unless a user's config opts in globally.
/// File existence, not that daemon-wide flag, must decide the seed for
/// *this* session: it already opted in for its own lifetime the moment
/// its history file was created, and a crash must not silently revoke
/// that (see crate::history's module doc and session.rs's
/// seed-once-then-reset block, gated today on `history_enabled` alone
/// at `crates/daemon/src/session.rs:632`).
#[test]
fn session_create_after_a_crash_seeds_replay_even_when_the_new_generation_has_history_off() {
    let id = "01J-p6-crash-restore-history-off-test";
    let daemon1 = precrash_session(id);

    // Same "restart" idiom as the ON-ON test above, except the second
    // generation's config has history persistence off -- the bug's
    // exact trigger.
    let config = daemon::DaemonConfig {
        runtime_dir: daemon1.runtime_dir.clone(),
        state_dir: daemon1.state_dir.clone(),
        history_enabled: false,
    };
    let _daemon2 = std::thread::spawn(move || daemon::Daemon::bind(config)?.run_until_idle());

    // Do not just `daemon1.connect()`: right after spawning the second
    // generation's thread, the first generation's listener is still
    // open on the not-yet-unlinked socket path, so a plain connect
    // issued immediately afterward can land back on the first
    // generation (whose already-live session for `id` would trivially
    // contain the marker regardless of any fix here). Poll until a
    // connection actually reports the *second* generation's
    // history-off config before proceeding.
    let stream2 = connect_until_history_flag_is(&daemon1, false);
    let reply2 = common::roundtrip(
        &stream2,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: Some(spec(id, vec!["/bin/cat"])),
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
        "a session recreated after a crash must seed its fresh terminal from the persisted \
         history bytes even when the recreating daemon generation's history flag is off: a \
         leftover file's existence must win over the daemon-wide default, since the file is \
         what proves this session opted in for its own lifetime; got: {:?}",
        String::from_utf8_lossy(&replay_frame.payload)
    );
}

/// R2 (team-lead RED assignment, B1): continuing from the same
/// crash-then-recreate scenario as the test above, the recreated
/// session must keep *appending* its own post-restart PTY output to
/// its history file, not merely seed the initial Replay from it. Today
/// both the seed and the write path live behind the very same
/// `history_enabled` check (`crates/daemon/src/session.rs:632` for the
/// seed, `:680` for opening the `HistoryWriter`), so whatever fix makes
/// R1 above pass must not stop at feeding the terminal: a session
/// created from a leftover file has to keep a writer open for its
/// whole lifetime regardless of the daemon-wide flag.
#[test]
fn session_recreated_after_a_crash_keeps_appending_history_despite_the_new_generations_flag_being_off(
) {
    let id = "01J-p6-crash-restore-continues-appending-test";
    let daemon1 = precrash_session(id);
    let history_path = daemon1.state_dir.join("history").join(format!("{id}.raw"));

    let config = daemon::DaemonConfig {
        runtime_dir: daemon1.runtime_dir.clone(),
        state_dir: daemon1.state_dir.clone(),
        history_enabled: false,
    };
    let _daemon2 = std::thread::spawn(move || daemon::Daemon::bind(config)?.run_until_idle());

    // Same reasoning as R1's test above: poll until the connection
    // actually reaches the second, history-off generation rather than
    // the still-open first one.
    let stream2 = connect_until_history_flag_is(&daemon1, false);
    let reply2 = common::roundtrip(
        &stream2,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: Some(spec(id, vec!["/bin/cat"])),
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
    let _replay_frame = reader2
        .read_frame()
        .expect("read the Replay frame after second-generation AttachOk");

    // `/bin/cat` echoes whatever Input it receives straight back as
    // Output, the same idiom attach.rs's echo test uses: a marker that
    // could only have been produced by this recreated session's own
    // post-restart PTY activity, never by the pre-crash content already
    // seeded into the terminal.
    const POST_RESTART_MARKER: &str = "POST_RESTART_MARKER_CONTENT";
    let mut writer2 = FrameWriter::new(stream2.try_clone().expect("clone for writer"));
    writer2
        .write_frame(
            FrameType::Input,
            format!("{POST_RESTART_MARKER}\n").as_bytes(),
        )
        .expect("write Input frame to the recreated session");

    let mut acc = Vec::new();
    loop {
        let frame = reader2
            .read_frame()
            .expect("read frame while waiting for POST_RESTART_MARKER echoed back");
        if frame.frame_type == FrameType::Output {
            acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&acc).contains(POST_RESTART_MARKER) {
                break;
            }
        }
    }

    // Poll rather than a single read: the (best-effort, unfsynced)
    // history append for the bytes just observed live may not have
    // reached disk at the exact instant the live Output loop above
    // broke out.
    let deadline = std::time::Instant::now() + common::IO_TIMEOUT;
    let mut history_bytes;
    loop {
        history_bytes = std::fs::read(&history_path).unwrap_or_default();
        if String::from_utf8_lossy(&history_bytes).contains(POST_RESTART_MARKER)
            || std::time::Instant::now() >= deadline
        {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    assert!(
        String::from_utf8_lossy(&history_bytes).contains(POST_RESTART_MARKER),
        "the recreated session must keep appending its own post-restart PTY output to its \
         history file even though the recreating daemon generation's flag is off -- a \
         leftover file's existence must keep the writer open for this session's whole \
         lifetime, not just seed the initial Replay; on-disk bytes: {:?}",
        String::from_utf8_lossy(&history_bytes)
    );
}
