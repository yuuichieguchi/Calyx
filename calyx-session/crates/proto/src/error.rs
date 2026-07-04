//! Error type returned by the `proto` crate's framing and control-message
//! (de)serialization.

use std::fmt;
use std::io;

/// Errors surfaced by frame I/O and control-message encode/decode.
///
/// Every fallible entry point in this crate must return one of these
/// instead of panicking, even for malformed/hostile input (oversized
/// frame length, unknown frame type, truncated or invalid CBOR): the
/// daemon reads frames from a Unix socket a client fully controls, so
/// "reject cleanly" is a load-bearing property, not a nicety.
#[derive(Debug)]
pub enum ProtoError {
    /// Underlying I/O failure (including EOF while a frame was only
    /// partially read).
    Io(io::Error),
    /// The declared frame length (type byte + payload) exceeded
    /// [`crate::MAX_FRAME_LEN`].
    FrameTooLarge { len: u32, max: u32 },
    /// The frame's type byte did not match any [`crate::FrameType`]
    /// variant.
    UnknownFrameType(u8),
    /// A `ControlMsg` failed to encode to or decode from CBOR.
    Cbor(String),
}

impl fmt::Display for ProtoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProtoError::Io(e) => write!(f, "proto: io error: {e}"),
            ProtoError::FrameTooLarge { len, max } => {
                write!(f, "proto: frame length {len} exceeds max {max}")
            }
            ProtoError::UnknownFrameType(b) => write!(f, "proto: unknown frame type byte {b}"),
            ProtoError::Cbor(msg) => write!(f, "proto: cbor error: {msg}"),
        }
    }
}

impl std::error::Error for ProtoError {}

impl From<io::Error> for ProtoError {
    fn from(e: io::Error) -> Self {
        ProtoError::Io(e)
    }
}
