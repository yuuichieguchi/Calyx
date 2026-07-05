//! Test 4 (spec): malformed CBOR must decode to an `Err`, never panic.

use proto::{decode_control, ProtoError};

#[test]
fn decode_control_rejects_garbage_bytes_without_panicking() {
    // Arbitrary bytes that are not valid CBOR at all.
    let garbage: &[u8] = &[0xff, 0x00, 0xde, 0xad, 0xbe, 0xef];
    let result = decode_control(garbage);
    assert!(
        matches!(result, Err(ProtoError::Cbor(_))),
        "expected ProtoError::Cbor, got {result:?}"
    );
}

#[test]
fn decode_control_rejects_truncated_cbor_without_panicking() {
    // A CBOR map-start byte with no following key/value pairs: valid
    // leading byte, invalid/truncated structure.
    let truncated: &[u8] = &[0xa1];
    let result = decode_control(truncated);
    assert!(
        matches!(result, Err(ProtoError::Cbor(_))),
        "expected ProtoError::Cbor, got {result:?}"
    );
}

#[test]
fn decode_control_rejects_valid_cbor_of_the_wrong_shape_without_panicking() {
    // Valid CBOR (a single unsigned integer) that cannot deserialize
    // into any `ControlMsg` variant.
    let mut wrong_shape = Vec::new();
    ciborium::into_writer(&42u64, &mut wrong_shape).expect("encode a plain u64 as CBOR");
    let result = decode_control(&wrong_shape);
    assert!(
        matches!(result, Err(ProtoError::Cbor(_))),
        "expected ProtoError::Cbor, got {result:?}"
    );
}
