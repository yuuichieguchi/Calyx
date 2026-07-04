//! Length-prefixed framing over any `std::io::Read`/`Write` stream
//! (deliberately not tied to tokio: the daemon is the only crate that
//! needs async I/O, and it can drive these blocking readers/writers
//! from a dedicated thread or `spawn_blocking`).
//!
//! Wire format per frame: `u32` length in little-endian (the byte count
//! of the frame-type byte *plus* the payload that follows it), then one
//! `u8` frame-type byte, then the payload itself.

use std::io::{self, Read, Write};

use crate::error::ProtoError;

/// Upper bound on a single frame's `type byte + payload` length, chosen
/// to be comfortably larger than any single control message or a
/// generous PTY output chunk while still bounding a malicious/buggy
/// peer's ability to force an unbounded allocation.
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

/// Identifies what a frame's payload contains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FrameType {
    /// CBOR-encoded [`crate::ControlMsg`].
    Control = 1,
    /// Raw bytes typed by an attached client, destined for the PTY.
    Input = 2,
    /// Raw bytes the PTY produced, destined for attached clients.
    Output = 3,
    /// Raw bytes reconstructing a session's current state on attach,
    /// sent once immediately after `AttachOk` and before any `Output`.
    Replay = 4,
}

impl FrameType {
    /// Maps a wire byte back to a `FrameType`, or `None` if it matches
    /// none of the defined variants (callers must turn that into a
    /// clean protocol error, never a panic or a silent default).
    pub fn from_u8(byte: u8) -> Option<FrameType> {
        match byte {
            1 => Some(FrameType::Control),
            2 => Some(FrameType::Input),
            3 => Some(FrameType::Output),
            4 => Some(FrameType::Replay),
            _ => None,
        }
    }
}

/// A single decoded frame: its type plus the raw payload that followed
/// the type byte (the length prefix itself is not retained).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub frame_type: FrameType,
    pub payload: Vec<u8>,
}

/// Reads whole frames off of any `Read` stream, buffering partial reads
/// internally so callers never need to worry about a frame arriving
/// split across multiple `read` calls (e.g. one byte at a time, as a
/// slow pipe might deliver it).
pub struct FrameReader<R> {
    inner: R,
}

impl<R: Read> FrameReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner }
    }

    /// Reads and returns the next whole frame, blocking until it has
    /// arrived in full.
    ///
    /// Must reject (via `Err`, never a panic) a declared length over
    /// [`MAX_FRAME_LEN`] and a type byte that doesn't match any
    /// [`FrameType`] variant: both are attacker/bug-controlled and must
    /// not be trusted to size an allocation or select known-safe
    /// behavior.
    pub fn read_frame(&mut self) -> Result<Frame, ProtoError> {
        let mut len_buf = [0u8; 4];
        self.inner.read_exact(&mut len_buf)?;
        let len = u32::from_le_bytes(len_buf);
        if len > MAX_FRAME_LEN {
            return Err(ProtoError::FrameTooLarge {
                len,
                max: MAX_FRAME_LEN,
            });
        }
        if len == 0 {
            return Err(ProtoError::Io(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame length 0 leaves no room for the frame-type byte",
            )));
        }

        let mut type_buf = [0u8; 1];
        self.inner.read_exact(&mut type_buf)?;
        let frame_type =
            FrameType::from_u8(type_buf[0]).ok_or(ProtoError::UnknownFrameType(type_buf[0]))?;

        let mut payload = vec![0u8; (len - 1) as usize];
        self.inner.read_exact(&mut payload)?;
        Ok(Frame {
            frame_type,
            payload,
        })
    }
}

/// Writes whole frames to any `Write` stream.
pub struct FrameWriter<W> {
    inner: W,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner }
    }

    /// Writes one frame: a `u32` LE length (`1 + payload.len()`), the
    /// frame-type byte, then `payload`. Returns `Err` rather than
    /// panicking if `payload` is large enough that `1 + payload.len()`
    /// would not fit in a `u32` or would exceed [`MAX_FRAME_LEN`].
    pub fn write_frame(&mut self, frame_type: FrameType, payload: &[u8]) -> Result<(), ProtoError> {
        let total = payload.len().saturating_add(1);
        if total > MAX_FRAME_LEN as usize {
            return Err(ProtoError::FrameTooLarge {
                len: u32::try_from(total).unwrap_or(u32::MAX),
                max: MAX_FRAME_LEN,
            });
        }
        self.inner.write_all(&(total as u32).to_le_bytes())?;
        self.inner.write_all(&[frame_type as u8])?;
        self.inner.write_all(payload)?;
        self.inner.flush()?;
        Ok(())
    }
}
