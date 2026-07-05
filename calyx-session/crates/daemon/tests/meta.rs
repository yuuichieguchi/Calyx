//! Test 15 (spec): `MetaSet` -> `MetaGet` round-trip.

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
fn meta_set_then_get_roundtrips() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let s = spec("01J-p2-meta-test");
    let _ =
        common::roundtrip(&stream, &ControlMsg::New { spec: s.clone() }).expect("New round-trip");

    let set_reply = common::roundtrip(
        &stream,
        &ControlMsg::MetaSet {
            id: s.id.clone(),
            key: "purpose".to_string(),
            value: "code-review".to_string(),
        },
    )
    .expect("MetaSet round-trip");
    let set_meta = match set_reply {
        ControlMsg::MetaOk { meta } => meta,
        other => panic!("expected MetaOk from MetaSet, got {other:?}"),
    };
    assert_eq!(
        set_meta.get("purpose").map(String::as_str),
        Some("code-review")
    );

    let get_reply = common::roundtrip(&stream, &ControlMsg::MetaGet { id: s.id.clone() })
        .expect("MetaGet round-trip");
    let get_meta = match get_reply {
        ControlMsg::MetaOk { meta } => meta,
        other => panic!("expected MetaOk from MetaGet, got {other:?}"),
    };
    assert_eq!(
        get_meta.get("purpose").map(String::as_str),
        Some("code-review"),
        "MetaGet should reflect the prior MetaSet"
    );
}
