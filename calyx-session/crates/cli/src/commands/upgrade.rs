//! `calyx-session upgrade` (EXPERIMENTAL): orchestrates Live Handoff --
//! see `daemon::handoff`'s module doc for the full contract this drives
//! (pause every session on the running daemon, hand off its listener
//! and every session's PTY master fd via SCM_RIGHTS to a freshly
//! spawned daemon process, ack, then exit without running normal
//! per-session teardown).
//!
//! Flow: connect to the running daemon, read its daemon-wide history
//! default (so the next generation inherits it as its own bind-time
//! flag), send `PrepareHandoff`, spawn the new binary as `daemon
//! --handoff-connect <endpoint>` against the same directories, then
//! wait for the outcome on the still-open control connection: the old
//! daemon exiting (the connection drops, success) or a
//! `handoff-failed` error (it keeps serving unchanged). On success the
//! new daemon is verified by listing sessions over the same socket
//! path, which the transferred listener kept serving throughout.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use proto::{decode_control, ControlMsg, FrameReader, FrameType, ProtoError};

use crate::cli::UpgradeArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{resolve_runtime_dir, resolve_state_dir, socket_path, CommandError};

/// Bound on waiting for the handoff outcome (old-daemon exit or a
/// handoff-failed report) after the receiver is spawned. Generous:
/// it must cover the receiver's own accept/receive/adopt budget.
const OUTCOME_TIMEOUT: Duration = Duration::from_secs(30);

/// Bound on verifying that the new daemon answers on the socket after
/// the old one exited.
const VERIFY_TIMEOUT: Duration = Duration::from_secs(5);

pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: UpgradeArgs,
) -> Result<u8, CommandError> {
    let new_binary = match args.binary {
        Some(binary) => binary,
        None => std::env::current_exe()?,
    };
    let socket = socket_path(runtime_dir);
    // No daemon, nothing to upgrade: the connect error is the report.
    let client = DaemonClient::connect(&socket)?;

    let history_enabled = match client.request(&ControlMsg::GetHistoryEnabled)? {
        ControlMsg::HistoryEnabled { enabled } => enabled,
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    };
    let handoff_path = match client.request(&ControlMsg::PrepareHandoff)? {
        ControlMsg::PrepareHandoffOk { path } => path,
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    };

    let mut receiver = std::process::Command::new(&new_binary);
    receiver
        .arg("daemon")
        .arg("--handoff-connect")
        .arg(&handoff_path)
        .arg("--runtime-dir")
        .arg(resolve_runtime_dir(runtime_dir))
        .arg("--state-dir")
        .arg(resolve_state_dir(state_dir));
    if history_enabled {
        receiver.arg("--persist-history");
    }
    // The receiver daemonizes itself, so this child returns promptly;
    // its status only reports the double-fork, never the handoff.
    let status = receiver.status()?;
    if !status.success() {
        return Err(CommandError::Io(std::io::Error::other(format!(
            "spawning the handoff receiver ({}) failed: {status}",
            new_binary.display()
        ))));
    }

    match wait_for_outcome(&client)? {
        Some((code, msg)) => Err(server_err(code, msg)),
        None => {
            let sessions = verify_new_daemon(&socket)?;
            println!(
                "handoff complete: {} session(s) now served by {}",
                sessions,
                new_binary.display()
            );
            Ok(0)
        }
    }
}

/// Reads the old daemon's control connection until the handoff's
/// outcome is unambiguous: `Ok(None)` once the connection drops (the
/// old daemon exited, i.e. the handoff succeeded), `Ok(Some((code,
/// msg)))` for a reported failure. A read timeout is its own error:
/// the outcome is unknown then, and claiming either way would lie.
fn wait_for_outcome(client: &DaemonClient) -> Result<Option<(String, String)>, CommandError> {
    client.stream.set_read_timeout(Some(OUTCOME_TIMEOUT))?;
    let mut reader = FrameReader::new(client.stream.try_clone()?);
    loop {
        match reader.read_frame() {
            Ok(frame) if frame.frame_type == FrameType::Control => {
                match decode_control(&frame.payload)? {
                    ControlMsg::Err { code, msg } => return Ok(Some((code, msg))),
                    // Anything else (pushed events, say) is not the
                    // outcome; keep waiting.
                    _ => continue,
                }
            }
            Ok(_) => continue,
            Err(ProtoError::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err(CommandError::Io(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    format!(
                        "no handoff outcome within {OUTCOME_TIMEOUT:?}; the daemon may still \
                         be serving (check `calyx-session ls`)"
                    ),
                )));
            }
            // EOF/reset: the old daemon's process exit closed this
            // connection, which is the success signal.
            Err(_) => return Ok(None),
        }
    }
}

/// Connects to the (now transferred) control socket and lists live
/// sessions, retrying briefly. The new daemon starts accepting on the
/// transferred listener *before* it acks the handoff (P6 review H5), and
/// the old daemon exits only after receiving that ack, so by the time
/// this runs the accept loop is already up. The short retry therefore
/// only covers connect/listen-backlog jitter, not a genuine
/// not-yet-listening window. Returns the live-session count.
fn verify_new_daemon(socket: &std::path::Path) -> Result<usize, CommandError> {
    let deadline = Instant::now() + VERIFY_TIMEOUT;
    loop {
        let attempt =
            DaemonClient::connect(socket).and_then(|client| client.request(&ControlMsg::List));
        match attempt {
            Ok(ControlMsg::ListOk { sessions }) => return Ok(sessions.len()),
            Ok(ControlMsg::Err { code, msg }) => return Err(server_err(code, msg)),
            Ok(other) => return Err(unexpected(&other)),
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(e),
        }
    }
}
