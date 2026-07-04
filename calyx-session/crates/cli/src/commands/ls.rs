use std::path::PathBuf;

use proto::{ControlMsg, SessionState};

use crate::cli::LsArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

/// Lists sessions (via `ControlMsg::List`), printed as JSON with
/// `--json` or as a human-readable table otherwise.
pub fn run(runtime_dir: &Option<PathBuf>, args: LsArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    let sessions = match client.request(&ControlMsg::List)? {
        ControlMsg::ListOk { sessions } => sessions,
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    };

    if args.json {
        let json = serde_json::to_string(&sessions)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        println!("{json}");
        return Ok(0);
    }

    for info in &sessions {
        let state = match info.state {
            SessionState::Running => "running".to_string(),
            SessionState::Exited { code } => format!("exited({code})"),
        };
        println!(
            "{}\t{}\tpid={}\tclients={}\t{}",
            info.id,
            state,
            info.pid,
            info.attached_clients,
            info.name.as_deref().unwrap_or("-"),
        );
    }
    Ok(0)
}
