//! Shared client-side plumbing: connect to the daemon socket, perform
//! the `Hello` handshake, and exchange single request/reply pairs.

use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter,
    PROTOCOL_VERSION,
};

use crate::commands::CommandError;

/// Bound on how long a simple command waits for a daemon reply.
const IO_TIMEOUT: Duration = Duration::from_secs(10);

pub(crate) struct DaemonClient {
    pub(crate) stream: UnixStream,
}

impl DaemonClient {
    /// Connects and completes the `Hello` handshake.
    pub(crate) fn connect(socket: &Path) -> Result<DaemonClient, CommandError> {
        let stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(IO_TIMEOUT))?;
        stream.set_write_timeout(Some(IO_TIMEOUT))?;
        let client = DaemonClient { stream };
        client.hello()?;
        Ok(client)
    }

    fn hello(&self) -> Result<(), CommandError> {
        match self.request(&ControlMsg::Hello {
            version: PROTOCOL_VERSION,
        })? {
            ControlMsg::HelloOk { .. } => Ok(()),
            ControlMsg::HelloErr { reason } => Err(CommandError::Server {
                code: "hello-err".to_string(),
                msg: reason,
            }),
            other => Err(unexpected(&other)),
        }
    }

    /// Sends one control message and reads control frames until a
    /// reply arrives (skipping any non-control frames, which can only
    /// appear on an attached connection).
    pub(crate) fn request(&self, msg: &ControlMsg) -> Result<ControlMsg, CommandError> {
        let mut writer = FrameWriter::new(&self.stream);
        writer.write_frame(FrameType::Control, &encode_control(msg)?)?;
        let mut reader = FrameReader::new(&self.stream);
        loop {
            let frame = reader.read_frame()?;
            if frame.frame_type == FrameType::Control {
                let reply = decode_control(&frame.payload)?;
                // Server-pushed events are not replies; skip them.
                if matches!(reply, ControlMsg::Event(_)) {
                    continue;
                }
                return Ok(reply);
            }
        }
    }
}

pub(crate) fn unexpected(reply: &ControlMsg) -> CommandError {
    CommandError::Io(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("unexpected daemon reply: {reply:?}"),
    ))
}

/// Maps a `ControlMsg::Err` reply into `CommandError::Server`.
pub(crate) fn server_err(code: String, msg: String) -> CommandError {
    CommandError::Server { code, msg }
}
