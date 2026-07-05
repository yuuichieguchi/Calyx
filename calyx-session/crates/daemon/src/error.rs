//! Error type returned by the `daemon` crate's public API.

use std::fmt;
use std::io;

/// Errors surfaced by [`crate::Daemon`].
#[derive(Debug)]
pub enum DaemonError {
    Io(io::Error),
    /// The connecting peer's uid did not match this process's own uid
    /// (see [`crate::peer::verify_peer_uid`]).
    PeerUidMismatch {
        peer_uid: u32,
        expected_uid: u32,
    },
}

impl fmt::Display for DaemonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DaemonError::Io(e) => write!(f, "daemon: io error: {e}"),
            DaemonError::PeerUidMismatch {
                peer_uid,
                expected_uid,
            } => write!(
                f,
                "daemon: rejected peer uid {peer_uid} (expected {expected_uid})"
            ),
        }
    }
}

impl std::error::Error for DaemonError {}

impl From<io::Error> for DaemonError {
    fn from(e: io::Error) -> Self {
        DaemonError::Io(e)
    }
}
