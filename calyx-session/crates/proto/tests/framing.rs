//! Tests 2 and 3 (spec): frames must reassemble correctly from a stream
//! that delivers them in arbitrarily small chunks, and must reject an
//! oversized declared length or an unrecognized frame-type byte with an
//! `Err` rather than a panic.

use std::io::{self, Read};

use proto::{Frame, FrameReader, FrameType, FrameWriter, ProtoError, MAX_FRAME_LEN};

/// Delivers the wrapped bytes one at a time, however large a read
/// buffer is requested, to exercise `FrameReader`'s handling of a
/// stream that never hands back a whole frame in a single `read` call
/// (a slow pipe being the realistic case in production).
struct OneByteAtATime<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> OneByteAtATime<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
}

impl<'a> Read for OneByteAtATime<'a> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.data.len() || buf.is_empty() {
            return Ok(0);
        }
        buf[0] = self.data[self.pos];
        self.pos += 1;
        Ok(1)
    }
}

#[test]
fn read_frame_reassembles_from_a_stream_delivered_one_byte_at_a_time() {
    let mut encoded = Vec::new();
    FrameWriter::new(&mut encoded)
        .write_frame(FrameType::Output, b"hello world")
        .expect("write_frame should succeed");

    let mut reader = FrameReader::new(OneByteAtATime::new(&encoded));
    let frame = reader
        .read_frame()
        .expect("read_frame should reassemble a frame delivered one byte at a time");

    assert_eq!(
        frame,
        Frame {
            frame_type: FrameType::Output,
            payload: b"hello world".to_vec(),
        }
    );
}

#[test]
fn read_frame_reassembles_two_consecutive_frames_one_byte_at_a_time() {
    let mut encoded = Vec::new();
    {
        let mut w = FrameWriter::new(&mut encoded);
        w.write_frame(FrameType::Input, b"first")
            .expect("write first frame");
        w.write_frame(FrameType::Input, b"second")
            .expect("write second frame");
    }

    let mut reader = FrameReader::new(OneByteAtATime::new(&encoded));
    let first = reader.read_frame().expect("read first frame");
    let second = reader.read_frame().expect("read second frame");

    assert_eq!(first.payload, b"first");
    assert_eq!(second.payload, b"second");
}

#[test]
fn read_frame_rejects_declared_length_over_max_without_panicking() {
    // u32 LE length header declaring more than MAX_FRAME_LEN, followed
    // by no actual payload (the reader must reject based on the header
    // alone, without attempting to read/allocate that much).
    let over_max = MAX_FRAME_LEN + 1;
    let mut bytes = over_max.to_le_bytes().to_vec();
    bytes.push(FrameType::Output as u8);

    let mut reader = FrameReader::new(&bytes[..]);
    let result = reader.read_frame();

    assert!(
        matches!(result, Err(ProtoError::FrameTooLarge { .. })),
        "expected FrameTooLarge, got {result:?}"
    );
}

#[test]
fn read_frame_rejects_unknown_frame_type_without_panicking() {
    // Length = 1 (just the type byte), type byte = 99 (not a valid
    // FrameType discriminant).
    let mut bytes = 1u32.to_le_bytes().to_vec();
    bytes.push(99);

    let mut reader = FrameReader::new(&bytes[..]);
    let result = reader.read_frame();

    assert!(
        matches!(result, Err(ProtoError::UnknownFrameType(99))),
        "expected UnknownFrameType(99), got {result:?}"
    );
}

#[test]
fn write_frame_rejects_payload_over_max_without_panicking() {
    let oversized_payload = vec![0u8; MAX_FRAME_LEN as usize];
    let mut sink = Vec::new();
    let result = FrameWriter::new(&mut sink).write_frame(FrameType::Output, &oversized_payload);

    assert!(
        matches!(result, Err(ProtoError::FrameTooLarge { .. })),
        "expected FrameTooLarge (payload len {} + 1 type byte exceeds MAX_FRAME_LEN {}), got {result:?}",
        oversized_payload.len(),
        MAX_FRAME_LEN,
    );
}
