//! Test 5 (spec): `Hello`/`HelloOk`/`HelloErr` version handshake.

mod common;

use proto::{ControlMsg, PROTOCOL_VERSION};

#[test]
fn hello_with_matching_version_returns_hello_ok() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");

    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Hello {
            version: PROTOCOL_VERSION,
        },
    )
    .expect("Hello round-trip");

    assert_eq!(
        reply,
        ControlMsg::HelloOk {
            version: PROTOCOL_VERSION
        }
    );
}

#[test]
fn hello_with_mismatched_version_returns_hello_err() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");

    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Hello {
            version: PROTOCOL_VERSION + 1000,
        },
    )
    .expect("Hello round-trip");

    assert!(
        matches!(reply, ControlMsg::HelloErr { .. }),
        "expected HelloErr for a mismatched version, got {reply:?}"
    );
}
