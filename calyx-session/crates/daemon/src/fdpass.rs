//! Raw file-descriptor passing over a Unix domain socket via
//! `SCM_RIGHTS`, used only by the experimental Live Handoff feature
//! (see `crate::handoff`'s module doc for the full contract this
//! plumbs).
//!
//! Deliberately not part of `proto`'s length-prefixed CBOR framing:
//! that wire format has no ancillary-data carrier, and extending it to
//! sometimes carry fds would leak a process-lineage-specific concern
//! into the format every ordinary client (attach, ls, kill, ...) also
//! has to parse. `std`'s own ancillary-data support
//! (`UnixStream::send_vectored_with_ancillary`) is still gated behind
//! the unstable `unix_socket_ancillary_data` feature on this
//! toolchain, so this goes through `nix::sys::socket::{sendmsg,
//! recvmsg}` instead (the `uio` nix feature they require is enabled
//! workspace-wide for exactly this).
//!
//! EXPERIMENTAL (P6, Live Handoff). Wire shape: a `u32` big-endian
//! length prefix and the sidecar bytes as plain stream data, then one
//! `sendmsg` whose single data byte ([`FD_PAYLOAD_MARKER`], present
//! because an `SCM_RIGHTS`-only message with no data bytes is not
//! reliably deliverable) carries every fd in one `SCM_RIGHTS` control
//! message.

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;

use nix::sys::socket::{recvmsg, sendmsg, ControlMessage, ControlMessageOwned, MsgFlags};

use crate::error::DaemonError;

/// The single data byte the fd-carrying `sendmsg` is attached to. Also
/// serves as a cheap desync check on the receiving side: any other
/// value there means the peer is not speaking this exchange.
const FD_PAYLOAD_MARKER: u8 = 0x06;

/// Upper bound on a received sidecar's declared length. The handoff
/// endpoint is uid-checked and mode-0600, so this is a robustness
/// bound against a buggy peer, not a security boundary; it comfortably
/// covers many sessions' worth of 8 MiB-scrollback replays.
const MAX_SIDECAR_BYTES: usize = 1024 * 1024 * 1024;

/// Sends `sidecar` (a length-prefixed blob; `crate::handoff` uses this
/// for a CBOR-encoded `HandoffManifest`) as plain stream bytes, then
/// every fd in `fds` via one `sendmsg` call carrying them all in a
/// single `SCM_RIGHTS` control message (nix's own docs warn that a
/// *second* `ScmRights` message in the same call may be dropped or
/// rejected, so exactly one control message carries every fd this call
/// needs to move), so `recv_fds` returns them in the same order.
pub(crate) fn send_fds(
    stream: &UnixStream,
    sidecar: &[u8],
    fds: &[RawFd],
) -> Result<(), DaemonError> {
    let len = u32::try_from(sidecar.len()).map_err(|_| {
        DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "handoff sidecar of {} bytes exceeds the u32 length prefix",
                sidecar.len()
            ),
        ))
    })?;
    let mut writer: &UnixStream = stream;
    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(sidecar)?;

    let marker = [FD_PAYLOAD_MARKER];
    let iov = [std::io::IoSlice::new(&marker)];
    let cmsgs: &[ControlMessage] = if fds.is_empty() {
        &[]
    } else {
        &[ControlMessage::ScmRights(fds)]
    };
    loop {
        match sendmsg::<()>(stream.as_raw_fd(), &iov, cmsgs, MsgFlags::empty(), None) {
            // The payload is one byte, so a successful non-EINTR send
            // is all-or-nothing.
            Ok(_) => return Ok(()),
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => return Err(DaemonError::Io(std::io::Error::from(e))),
        }
    }
}

/// Reads back what `send_fds` sent: the sidecar blob, then up to
/// `max_fds` file descriptors recovered from the trailing `sendmsg`'s
/// `SCM_RIGHTS` ancillary data, in the order they were sent. Each
/// returned `OwnedFd` is this process's own, independent duplicate
/// (recvmsg's usual SCM_RIGHTS semantics): closing it does not affect
/// the sender's copy. Every returned fd has `FD_CLOEXEC` set here
/// (macOS has no `MSG_CMSG_CLOEXEC`), so an adopted PTY master can
/// never leak into children this daemon forks later, the same
/// discipline `session::spawn_session` applies to the fds it creates.
///
/// A sender that packed more than `max_fds` fds overflows the control
/// buffer and fails here with `ENOBUFS`; the kernel-installed fds are
/// unrecoverable in that case (nix refuses to parse a truncated
/// control buffer), so callers must size `max_fds` at the protocol's
/// agreed maximum, not a guess.
pub(crate) fn recv_fds(
    stream: &UnixStream,
    max_fds: usize,
) -> Result<(Vec<u8>, Vec<OwnedFd>), DaemonError> {
    let mut reader: &UnixStream = stream;
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_SIDECAR_BYTES {
        return Err(DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("handoff sidecar length {len} exceeds the {MAX_SIDECAR_BYTES}-byte bound"),
        )));
    }
    let mut sidecar = vec![0u8; len];
    // read_exact loops internally, so short reads (the sidecar can be
    // many socket buffers long) are already handled.
    reader.read_exact(&mut sidecar)?;

    let mut marker = [0u8; 1];
    let mut iov = [std::io::IoSliceMut::new(&mut marker)];
    // SAFETY: CMSG_SPACE is a pure size computation.
    let cmsg_len = unsafe {
        libc::CMSG_SPACE((max_fds * std::mem::size_of::<RawFd>()) as libc::c_uint) as usize
    };
    let mut cmsg_buf = vec![0u8; cmsg_len];
    let (bytes, fds) = loop {
        match recvmsg::<()>(
            stream.as_raw_fd(),
            &mut iov,
            Some(&mut cmsg_buf),
            MsgFlags::empty(),
        ) {
            Ok(msg) => {
                let mut fds: Vec<OwnedFd> = Vec::new();
                for cmsg in msg.cmsgs().map_err(|e| {
                    DaemonError::Io(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("handoff control data truncated (more than {max_fds} fds?): {e}"),
                    ))
                })? {
                    if let ControlMessageOwned::ScmRights(received) = cmsg {
                        for raw in received {
                            // SAFETY: SCM_RIGHTS receipt just installed
                            // `raw` in this process's fd table and
                            // nothing else refers to it yet.
                            fds.push(unsafe { OwnedFd::from_raw_fd(raw) });
                        }
                    }
                }
                break (msg.bytes, fds);
            }
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => return Err(DaemonError::Io(std::io::Error::from(e))),
        }
    };
    if bytes == 0 {
        return Err(DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "handoff peer closed before sending its fd payload",
        )));
    }
    if marker[0] != FD_PAYLOAD_MARKER {
        return Err(DaemonError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "unexpected handoff fd-payload marker byte {:#04x}",
                marker[0]
            ),
        )));
    }
    for fd in &fds {
        nix::fcntl::fcntl(
            fd,
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )
        .map_err(|e| DaemonError::Io(std::io::Error::from(e)))?;
    }
    Ok((sidecar, fds))
}

#[cfg(test)]
mod tests {
    use std::os::fd::{AsFd, AsRawFd};

    use super::*;

    /// R1 (P6 RED3): `send_fds`/`recv_fds` must round-trip real fds
    /// over a real Unix-domain socketpair -- verified by writing
    /// through a *received* fd and reading the bytes back via the
    /// original pipe's read end, which only succeeds if the received
    /// fd genuinely names the same open file description rather than,
    /// say, a fresh unrelated fd of the same number -- plus a sidecar
    /// blob, and must preserve the order of multiple fds sent
    /// together in one call.
    #[test]
    fn send_fds_recv_fds_round_trip_over_a_socketpair_preserves_order() {
        let (a, b) = nix::sys::socket::socketpair(
            nix::sys::socket::AddressFamily::Unix,
            nix::sys::socket::SockType::Stream,
            None,
            nix::sys::socket::SockFlag::empty(),
        )
        .expect("create scratch socketpair for the handoff channel");
        let sender = UnixStream::from(a);
        let receiver = UnixStream::from(b);

        // Two scratch pipes stand in for "real fds" a handoff would
        // carry (a listener fd, a PTY master fd, ...): each pipe's
        // write end is what travels through send_fds/recv_fds; each
        // read end stays here so this test can observe what a write
        // through the *received* fd actually delivers.
        let (read_end_1, write_end_1) = nix::unistd::pipe().expect("create scratch pipe 1");
        let (read_end_2, write_end_2) = nix::unistd::pipe().expect("create scratch pipe 2");

        let sidecar = b"handoff-manifest-sidecar".to_vec();
        let fds = [write_end_1.as_raw_fd(), write_end_2.as_raw_fd()];

        let sidecar_for_sender = sidecar.clone();
        let send_thread = std::thread::spawn(move || {
            send_fds(&sender, &sidecar_for_sender, &fds).expect("send_fds should succeed");
        });

        let (received_sidecar, received_fds) =
            recv_fds(&receiver, 2).expect("recv_fds should succeed");
        send_thread
            .join()
            .expect("the sending thread must not panic");

        assert_eq!(
            received_sidecar, sidecar,
            "the sidecar blob must round-trip byte-for-byte"
        );
        assert_eq!(received_fds.len(), 2, "both fds must be received");

        // Ordering: write a distinct marker through each received fd,
        // then read it back from the *original* pipe's read end.
        nix::unistd::write(received_fds[0].as_fd(), b"first").expect("write through received fd 0");
        nix::unistd::write(received_fds[1].as_fd(), b"second")
            .expect("write through received fd 1");

        let mut buf = [0u8; 6];
        let n1 = nix::unistd::read(read_end_1.as_fd(), &mut buf)
            .expect("read back through pipe 1's original read end");
        assert_eq!(
            &buf[..n1],
            b"first",
            "fds[0] (pipe 1's write end) must arrive as received_fds[0]"
        );

        let n2 = nix::unistd::read(read_end_2.as_fd(), &mut buf)
            .expect("read back through pipe 2's original read end");
        assert_eq!(
            &buf[..n2],
            b"second",
            "fds[1] (pipe 2's write end) must arrive as received_fds[1]"
        );
    }
}
