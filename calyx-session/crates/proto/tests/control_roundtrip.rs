//! Test 1 (spec): every `ControlMsg` variant round-trips through
//! `encode_control` -> `decode_control` unchanged.

use std::collections::BTreeMap;

use proto::{
    decode_control, encode_control, ControlMsg, SessionEvent, SessionInfo, SessionSpec,
    SessionState,
};

fn assert_roundtrips(msg: ControlMsg) {
    let bytes = encode_control(&msg).expect("encode_control should succeed");
    let decoded =
        decode_control(&bytes).expect("decode_control should succeed on our own encoding");
    assert_eq!(decoded, msg, "round-trip through CBOR must be lossless");
}

fn sample_spec() -> SessionSpec {
    SessionSpec {
        id: "01J000000000000000000TEST".to_string(),
        name: Some("my-session".to_string()),
        cwd: Some("/tmp/scratch".to_string()),
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "true".to_string(),
        ]),
        env: vec![("FOO".to_string(), "bar".to_string())],
        cols: 80,
        rows: 24,
    }
}

fn sample_info() -> SessionInfo {
    let mut meta = BTreeMap::new();
    meta.insert("key".to_string(), "value".to_string());
    SessionInfo {
        id: "01J000000000000000000TEST".to_string(),
        name: Some("my-session".to_string()),
        cwd: Some("/tmp/scratch".to_string()),
        state: SessionState::Running,
        created_at_ms: 1_700_000_000_000,
        attached_clients: 2,
        pid: 12345,
        meta,
    }
}

#[test]
fn roundtrip_hello() {
    assert_roundtrips(ControlMsg::Hello { version: 1 });
}

#[test]
fn roundtrip_hello_ok() {
    assert_roundtrips(ControlMsg::HelloOk { version: 1 });
}

#[test]
fn roundtrip_hello_err() {
    assert_roundtrips(ControlMsg::HelloErr {
        reason: "version mismatch".to_string(),
    });
}

#[test]
fn roundtrip_list() {
    assert_roundtrips(ControlMsg::List);
}

#[test]
fn roundtrip_list_ok() {
    assert_roundtrips(ControlMsg::ListOk {
        sessions: vec![sample_info()],
    });
}

#[test]
fn roundtrip_list_ok_empty() {
    assert_roundtrips(ControlMsg::ListOk { sessions: vec![] });
}

#[test]
fn roundtrip_list_all() {
    assert_roundtrips(ControlMsg::ListAll);
}

#[test]
fn roundtrip_list_all_ok() {
    assert_roundtrips(ControlMsg::ListAllOk {
        sessions: vec![sample_info()],
    });
}

#[test]
fn roundtrip_new() {
    assert_roundtrips(ControlMsg::New {
        spec: sample_spec(),
    });
}

#[test]
fn roundtrip_new_ok() {
    assert_roundtrips(ControlMsg::NewOk {
        info: sample_info(),
    });
}

#[test]
fn roundtrip_attach_without_create() {
    assert_roundtrips(ControlMsg::Attach {
        id: "01J000000000000000000TEST".to_string(),
        create: None,
        cols: 100,
        rows: 30,
    });
}

#[test]
fn roundtrip_attach_with_create() {
    assert_roundtrips(ControlMsg::Attach {
        id: "01J000000000000000000TEST".to_string(),
        create: Some(sample_spec()),
        cols: 100,
        rows: 30,
    });
}

#[test]
fn roundtrip_attach_ok() {
    assert_roundtrips(ControlMsg::AttachOk {
        info: sample_info(),
    });
}

#[test]
fn roundtrip_detach() {
    assert_roundtrips(ControlMsg::Detach);
}

#[test]
fn roundtrip_kill() {
    assert_roundtrips(ControlMsg::Kill {
        id: "01J000000000000000000TEST".to_string(),
    });
}

#[test]
fn roundtrip_kill_ok() {
    assert_roundtrips(ControlMsg::KillOk);
}

#[test]
fn roundtrip_meta_set() {
    assert_roundtrips(ControlMsg::MetaSet {
        id: "01J000000000000000000TEST".to_string(),
        key: "k".to_string(),
        value: "v".to_string(),
    });
}

#[test]
fn roundtrip_meta_get() {
    assert_roundtrips(ControlMsg::MetaGet {
        id: "01J000000000000000000TEST".to_string(),
    });
}

#[test]
fn roundtrip_meta_ok() {
    let mut meta = BTreeMap::new();
    meta.insert("k".to_string(), "v".to_string());
    assert_roundtrips(ControlMsg::MetaOk { meta });
}

#[test]
fn roundtrip_resize() {
    assert_roundtrips(ControlMsg::Resize {
        cols: 132,
        rows: 43,
    });
}

#[test]
fn roundtrip_event_exited() {
    assert_roundtrips(ControlMsg::Event(SessionEvent::Exited {
        id: "01J000000000000000000TEST".to_string(),
        code: 7,
    }));
}

#[test]
fn roundtrip_err() {
    assert_roundtrips(ControlMsg::Err {
        code: "not_found".to_string(),
        msg: "no such session".to_string(),
    });
}
