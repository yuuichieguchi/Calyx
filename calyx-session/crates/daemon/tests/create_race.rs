//! Regression test (P2 review bug #2): a concurrent `Attach{create}`
//! race for the same id must never leave the winning session
//! unreachable. The daemon's `create_session` correctly kills the
//! *loser's own* duplicate spawn, but that loser's session thread later
//! runs its normal exit-teardown path (`state.sessions.remove(&id)`)
//! unconditionally — removing whichever entry is registered under that
//! id at the time, which by then is the *winner's* entry, not the
//! loser's own (never-registered) one. The observable effect: the
//! winning session either drops out of `List` or becomes unreachable
//! for `Input` (both keyed by re-looking up `state.sessions[id]`).
//!
//! Not sleep-dependent: the race's *winner* is nondeterministic, but a
//! `Barrier` rendezvous after both connections are already connected
//! and hello'd maximizes the chance of real overlap between the two
//! `spawn_session` calls, and repeating the attempt drives the
//! probability of hitting it at least once arbitrarily high under the
//! current implementation. Each attempt asserts its own invariants, so
//! a single bad attempt already fails the test.

mod common;

use std::sync::Barrier;
use std::thread;

use proto::{ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec};

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
fn concurrent_attach_create_never_loses_the_winning_session() {
    let daemon = common::ScratchDaemon::spawn();
    const ATTEMPTS: usize = 15;

    for attempt in 0..ATTEMPTS {
        let id = format!("01J-p2-create-race-{attempt}");
        let s = spec(&id);

        let stream_a = daemon.connect().expect("connect stream A");
        common::hello(&stream_a);
        let stream_b = daemon.connect().expect("connect stream B");
        common::hello(&stream_b);

        let (id_a, id_b) = (id.clone(), id.clone());
        let (s_a, s_b) = (s.clone(), s.clone());
        let barrier = Barrier::new(2);
        let (reply_a, reply_b) = thread::scope(|scope| {
            let stream_a_ref = &stream_a;
            let stream_b_ref = &stream_b;
            let barrier_ref = &barrier;
            let handle_a = scope.spawn(move || {
                barrier_ref.wait();
                common::roundtrip(
                    stream_a_ref,
                    &ControlMsg::Attach {
                        id: id_a,
                        create: Some(s_a),
                        cols: 80,
                        rows: 24,
                    },
                )
                .expect("Attach A round-trip")
            });
            let handle_b = scope.spawn(move || {
                barrier_ref.wait();
                common::roundtrip(
                    stream_b_ref,
                    &ControlMsg::Attach {
                        id: id_b,
                        create: Some(s_b),
                        cols: 80,
                        rows: 24,
                    },
                )
                .expect("Attach B round-trip")
            });
            (
                handle_a.join().expect("thread A should not panic"),
                handle_b.join().expect("thread B should not panic"),
            )
        });

        assert!(
            matches!(reply_a, ControlMsg::AttachOk { .. }),
            "attempt {attempt}: expected AttachOk on connection A, got {reply_a:?}"
        );
        assert!(
            matches!(reply_b, ControlMsg::AttachOk { .. }),
            "attempt {attempt}: expected AttachOk on connection B, got {reply_b:?}"
        );

        // Invariant 1: the session must still be listed after both
        // Attach{create} calls resolve, regardless of which lost the
        // create race.
        let list_reply = common::roundtrip(&stream_a, &ControlMsg::List).expect("List round-trip");
        let sessions = match list_reply {
            ControlMsg::ListOk { sessions } => sessions,
            other => panic!("attempt {attempt}: expected ListOk, got {other:?}"),
        };
        assert!(
            sessions.iter().any(|si| si.id == id),
            "attempt {attempt}: session {id:?} should still be listed after a \
             concurrent Attach{{create}} race, got {sessions:?}"
        );

        // Invariant 2: input on either connection must still reach the
        // (single, surviving) PTY and echo back. A losing thread that
        // incorrectly tore down the winner's registry entry leaves the
        // process alive but unreachable, so new input silently
        // vanishes instead of echoing (see this file's module doc).
        let mut writer = FrameWriter::new(stream_a.try_clone().expect("clone A for writer"));
        let needle = format!("race-{attempt}");
        writer
            .write_frame(FrameType::Input, format!("{needle}\n").as_bytes())
            .expect("write Input frame");

        let mut reader = FrameReader::new(stream_a.try_clone().expect("clone A for reader"));
        let mut acc = Vec::new();
        let found = loop {
            let frame = match reader.read_frame() {
                Ok(frame) => frame,
                Err(_) => break false,
            };
            if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
                acc.extend_from_slice(&frame.payload);
                if String::from_utf8_lossy(&acc).contains(&needle) {
                    break true;
                }
            }
        };
        assert!(
            found,
            "attempt {attempt}: input sent after a concurrent Attach{{create}} race \
             should still echo back, got {:?}",
            String::from_utf8_lossy(&acc)
        );
    }
}
