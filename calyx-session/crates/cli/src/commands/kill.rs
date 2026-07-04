use std::path::PathBuf;

use proto::ControlMsg;

use crate::cli::KillArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

/// Kills a session (via `ControlMsg::Kill`).
pub fn run(runtime_dir: &Option<PathBuf>, args: KillArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    match client.request(&ControlMsg::Kill { id: args.id })? {
        ControlMsg::KillOk => Ok(0),
        ControlMsg::Err { code, msg } => Err(server_err(code, msg)),
        other => Err(unexpected(&other)),
    }
}
