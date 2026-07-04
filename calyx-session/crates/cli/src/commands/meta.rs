use std::path::PathBuf;

use proto::ControlMsg;

use crate::cli::{MetaArgs, MetaCommand};
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

/// Gets or sets session metadata (via `ControlMsg::MetaGet`/`MetaSet`).
pub fn run(runtime_dir: &Option<PathBuf>, args: MetaArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    let request = match args.command {
        MetaCommand::Set {
            id,
            kv: (key, value),
        } => ControlMsg::MetaSet { id, key, value },
        MetaCommand::Get { id } => ControlMsg::MetaGet { id },
    };
    match client.request(&request)? {
        ControlMsg::MetaOk { meta } => {
            for (key, value) in &meta {
                println!("{key}={value}");
            }
            Ok(0)
        }
        ControlMsg::Err { code, msg } => Err(server_err(code, msg)),
        other => Err(unexpected(&other)),
    }
}
