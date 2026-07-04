//! Wire protocol for the calyx-session daemon: length-prefixed framing
//! plus the CBOR control-message schema exchanged inside `Control`
//! frames. Shared, dependency-light crate consumed by both `daemon`
//! (server side) and `cli` (client side).

mod control;
mod error;
mod frame;

pub use control::{
    decode_control, encode_control, ControlMsg, SessionEvent, SessionInfo, SessionSpec,
    SessionState, PROTOCOL_VERSION,
};
pub use error::ProtoError;
pub use frame::{Frame, FrameReader, FrameType, FrameWriter, MAX_FRAME_LEN};
