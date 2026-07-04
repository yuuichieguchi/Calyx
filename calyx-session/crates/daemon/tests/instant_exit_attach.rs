//! Regression test (P2 review bug #7): `Attach{create}` against a
//! session whose child exits essentially instantly must always reply
//! `AttachOk`, never an error. `conn.rs`'s own comment documents the
//! race directly: after `create_session` registers the new entry, the
//! caller re-locks the state to attach to it, but a child fast enough
//! to have already exited (and been reaped by its session thread,
//! which removes the registry entry) beats that re-lock, so `attach()`
//! falls through to `err_no_session` instead of `AttachOk`. This is
//! also what made the CLI smoke test's immediate-exit attach scenario
//! flaky (it surfaces as a non-zero exit code instead of 0).
//!
//! Not sleep-dependent: a single sequential attempt rarely loses this
//! race (spawning any process, however trivial, tends to take longer
//! than a bare mutex re-lock). Firing many *concurrent* Attach{create}
//! requests (distinct ids, so this doesn't conflate with the separate
//! create-race regression test) creates genuine scheduling/lock
//! contention on `Shared::state`, which is what actually widens the
//! race window enough to hit reliably; repeating over several rounds
//! drives the probability of hitting it at least once arbitrarily
//! high under the current implementation.
//!
//! `CONCURRENCY`/`ROUNDS` are deliberately modest: a first attempt at
//! 16-way concurrency over 5 rounds started failing `openpty` outright
//! (an errno nix doesn't even have a name for) partway through —
//! almost certainly bug #4's missing `FD_CLOEXEC` compounding across
//! many *simultaneous* forks (each inherits every other
//! concurrently-open session's PTY master at fork time), a real bug
//! but a different one from the race under test here.

mod common;

use std::sync::Barrier;
use std::thread;

use proto::{ControlMsg, SessionSpec};

fn spec(id: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exit 0".to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn attach_create_to_an_instantly_exiting_session_always_returns_attach_ok() {
    let daemon = common::ScratchDaemon::spawn();
    const ROUNDS: usize = 8;
    const CONCURRENCY: usize = 4;

    for round in 0..ROUNDS {
        let ids: Vec<String> = (0..CONCURRENCY)
            .map(|i| format!("01J-p2-instant-exit-{round}-{i}"))
            .collect();
        let streams: Vec<_> = (0..CONCURRENCY)
            .map(|_| {
                let s = daemon.connect().expect("connect");
                common::hello(&s);
                s
            })
            .collect();

        let barrier = Barrier::new(CONCURRENCY);
        let replies = thread::scope(|scope| {
            let barrier = &barrier;
            let handles: Vec<_> = streams
                .iter()
                .zip(ids.iter())
                .map(|(stream, id)| {
                    let id = id.clone();
                    scope.spawn(move || {
                        barrier.wait();
                        common::roundtrip(
                            stream,
                            &ControlMsg::Attach {
                                id: id.clone(),
                                create: Some(spec(&id)),
                                cols: 80,
                                rows: 24,
                            },
                        )
                        .expect("Attach round-trip")
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().expect("thread should not panic"))
                .collect::<Vec<_>>()
        });

        for (i, reply) in replies.iter().enumerate() {
            assert!(
                matches!(reply, ControlMsg::AttachOk { .. }),
                "round {round} connection {i}: Attach{{create}} to an instantly-\
                 exiting session should always return AttachOk, got {reply:?}"
            );
        }
    }
}
