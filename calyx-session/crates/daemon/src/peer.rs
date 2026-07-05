//! Peer-credential verification for connections accepted on the
//! session socket.
//!
//! The runtime directory (`DaemonConfig::runtime_dir`) is expected to
//! be user-private (mode `0700`), but that alone doesn't stop another
//! local user from connecting if, e.g., a misconfigured deployment
//! points `runtime_dir` at a shared location. Every accepted connection
//! is therefore also checked at the credential level before any
//! protocol bytes are trusted.

use std::os::unix::net::UnixStream;

use crate::error::DaemonError;

/// Verifies that `stream`'s peer has the same effective uid as this
/// process, returning [`DaemonError::PeerUidMismatch`] otherwise.
pub fn verify_peer_uid(stream: &UnixStream) -> Result<(), DaemonError> {
    let peer_uid = peer_uid_of(stream)?;
    let expected_uid = nix::unistd::geteuid().as_raw();
    if peer_uid != expected_uid {
        return Err(DaemonError::PeerUidMismatch {
            peer_uid,
            expected_uid,
        });
    }
    Ok(())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn peer_uid_of(stream: &UnixStream) -> Result<u32, DaemonError> {
    let creds = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::LocalPeerCred)
        .map_err(|e| DaemonError::Io(std::io::Error::from(e)))?;
    Ok(creds.uid())
}

#[cfg(target_os = "linux")]
fn peer_uid_of(stream: &UnixStream) -> Result<u32, DaemonError> {
    let creds = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
        .map_err(|e| DaemonError::Io(std::io::Error::from(e)))?;
    Ok(creds.uid())
}
