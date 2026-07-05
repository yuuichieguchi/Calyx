//! Shared harness for the daemon's integration tests: spawns a real
//! `Daemon` (per `daemon::Daemon::bind`/`run_until_idle`) against a
//! scratch runtime/state directory and talks to it over a real
//! `UnixStream`, exactly as a real `calyx-session` CLI process would.
//!
//! Every helper here is timeout-bounded so that a daemon bug (failing
//! to bind, accepting but never replying) surfaces as a normal,
//! bounded-time test failure rather than hanging the suite.

// This module is compiled once per test binary that includes it via
// `mod common;`; each binary only exercises a subset of these helpers,
// so per-binary dead-code warnings here are expected noise rather than
// a real signal.
#![allow(dead_code)]

use std::io;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use daemon::{Daemon, DaemonConfig, DaemonError};
use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter,
    PROTOCOL_VERSION,
};
use tempfile::TempDir;

/// Read/write timeout applied to every connected `UnixStream`, so a
/// daemon that accepts a connection but never responds fails a test
/// instead of hanging it.
pub const IO_TIMEOUT: Duration = Duration::from_secs(3);
/// Bound on how long `connect`/`connect_with_timeout` retry before
/// giving up.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// A `Daemon` bound and running against a scratch directory, so tests
/// never touch a real user's `~/.calyx`.
pub struct ScratchDaemon {
    pub tempdir: TempDir,
    pub runtime_dir: PathBuf,
    pub state_dir: PathBuf,
    pub socket_path: PathBuf,
    // Kept so the background thread's JoinHandle doesn't get detached
    // silently; never actually joined (the daemon thread outlives each
    // test on purpose: it only exits after its idle linger).
    #[allow(dead_code)]
    handle: Option<JoinHandle<Result<(), DaemonError>>>,
}

impl ScratchDaemon {
    /// Spawns `Daemon::bind(..).run_until_idle()` on a background
    /// thread. Does not block on the daemon actually being ready;
    /// callers should use `connect` (bounded retry) rather than
    /// assuming readiness immediately after this returns.
    pub fn spawn() -> ScratchDaemon {
        let tempdir = tempfile::tempdir().expect("create scratch tempdir for a test daemon");
        let runtime_dir = tempdir.path().join("run");
        let state_dir = tempdir.path().join("state");
        let socket_path = runtime_dir.join("sessiond.sock");

        let config = DaemonConfig {
            runtime_dir: runtime_dir.clone(),
            state_dir: state_dir.clone(),
        };
        let handle = thread::spawn(move || Daemon::bind(config)?.run_until_idle());

        ScratchDaemon {
            tempdir,
            runtime_dir,
            state_dir,
            socket_path,
            handle: Some(handle),
        }
    }

    /// Connects to this daemon's socket, retrying with backoff up to
    /// `CONNECT_TIMEOUT`.
    pub fn connect(&self) -> io::Result<UnixStream> {
        connect_with_timeout(&self.socket_path, CONNECT_TIMEOUT)
    }
}

/// Connects to `socket_path`, retrying with a short backoff until
/// `timeout` elapses, rather than failing on the first attempt (the
/// daemon's background thread may not have bound the socket yet).
pub fn connect_with_timeout(socket_path: &Path, timeout: Duration) -> io::Result<UnixStream> {
    let deadline = Instant::now() + timeout;
    let mut last_err = None;
    while Instant::now() < deadline {
        match UnixStream::connect(socket_path) {
            Ok(stream) => {
                stream.set_read_timeout(Some(IO_TIMEOUT))?;
                stream.set_write_timeout(Some(IO_TIMEOUT))?;
                return Ok(stream);
            }
            Err(e) => {
                last_err = Some(e);
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
    Err(last_err
        .unwrap_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "daemon socket never appeared")))
}

/// Polls `path` for non-empty content up to `timeout`, for asserting on
/// the ledger file (`sessions.json`) without racing the daemon's write.
pub fn read_with_retry(path: &Path, timeout: Duration) -> io::Result<String> {
    let deadline = Instant::now() + timeout;
    let mut last_err = None;
    while Instant::now() < deadline {
        match std::fs::read_to_string(path) {
            Ok(contents) if !contents.is_empty() => return Ok(contents),
            Ok(_) => {}
            Err(e) => last_err = Some(e),
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(last_err.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::TimedOut, "file never appeared with content")
    }))
}

/// Sends `msg` as a single `Control` frame and reads frames until a
/// non-event `Control` frame arrives, decoding it as a `ControlMsg`.
///
/// Mirrors `cli::commands::client::DaemonClient::request`: on an
/// attached connection, `Input`/`Output`/`Replay` frames (and pushed
/// `Event`s) can be interleaved with control replies — most notably,
/// `Attach` now pushes its `Replay` frame immediately, so even a `List`
/// sent right after `Attach` can see a `Replay` frame first. Only valid
/// for requests that have a dedicated reply (i.e. not `Resize`, which
/// is fire-and-forget per the protocol contract); see `write_control`
/// for those.
pub fn roundtrip(
    stream: &UnixStream,
    msg: &ControlMsg,
) -> Result<ControlMsg, Box<dyn std::error::Error>> {
    write_control(stream, msg)?;
    let mut reader = FrameReader::new(stream.try_clone()?);
    loop {
        let frame = reader.read_frame()?;
        if frame.frame_type == FrameType::Control {
            let reply = decode_control(&frame.payload)?;
            if matches!(reply, ControlMsg::Event(_)) {
                continue;
            }
            return Ok(reply);
        }
    }
}

/// Sends `msg` as a single `Control` frame without waiting for a reply.
pub fn write_control(
    stream: &UnixStream,
    msg: &ControlMsg,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut writer = FrameWriter::new(stream.try_clone()?);
    writer.write_frame(FrameType::Control, &encode_control(msg)?)?;
    Ok(())
}

/// Performs the mandatory `Hello`/`HelloOk` handshake with the current
/// protocol version, panicking (failing the calling test) if it
/// doesn't succeed. Every other test helper here assumes the handshake
/// has already happened on `stream`.
pub fn hello(stream: &UnixStream) {
    let reply = roundtrip(
        stream,
        &ControlMsg::Hello {
            version: PROTOCOL_VERSION,
        },
    )
    .expect("Hello handshake round-trip");
    assert_eq!(
        reply,
        ControlMsg::HelloOk {
            version: PROTOCOL_VERSION
        },
        "expected HelloOk during test setup handshake"
    );
}
