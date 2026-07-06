//! `calyx-session history <on|off|status>`: toggles or queries the
//! daemon-wide on-disk history-persistence default (via
//! `ControlMsg::SetHistoryEnabled`/`GetHistoryEnabled` -- see the doc
//! comment on `ControlMsg::SetHistoryEnabled` in `proto` for the full
//! contract of what this changes and does not change).
//!
//! OUTPUT CONTRACT: `on`/`off` print the confirmed state
//! (`SetHistoryEnabledOk`'s echoed value) as a single bare line,
//! `"on"` or `"off"` -- no label prefix -- matching `new`'s existing
//! bare-id-print precedent rather than `meta get`'s `key=value` shape
//! (there is only one value here, not a map). `status` queries via
//! `GetHistoryEnabled` and prints the same bare `"on"`/`"off"` line
//! without ever sending `SetHistoryEnabled`. Daemon-unreachable
//! follows every other subcommand's existing convention unchanged:
//! `DaemonClient::connect`'s `io::Error` propagates via `?` through
//! `CommandError::Io`, and `main`'s `Err(e) => {
//! eprintln!("calyx-session: {e}"); ExitCode::from(1) }` handles the
//! rest -- nothing history-specific needed there.

use std::path::PathBuf;

use proto::ControlMsg;

use crate::cli::{HistoryArgs, HistoryCommand};
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

pub fn run(runtime_dir: &Option<PathBuf>, args: HistoryArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    // Each request is matched against its own reply type (a
    // `HistoryEnabled` answer to a `SetHistoryEnabled` request is a
    // protocol violation, not a success), and the printed value always
    // comes from the reply, never the request: the reply is the state
    // the daemon confirmed to be in effect.
    let enabled = match args.command {
        HistoryCommand::On | HistoryCommand::Off => {
            let enabled = matches!(args.command, HistoryCommand::On);
            match client.request(&ControlMsg::SetHistoryEnabled { enabled })? {
                ControlMsg::SetHistoryEnabledOk { enabled } => enabled,
                ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
                other => return Err(unexpected(&other)),
            }
        }
        HistoryCommand::Status => match client.request(&ControlMsg::GetHistoryEnabled)? {
            ControlMsg::HistoryEnabled { enabled } => enabled,
            ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
            other => return Err(unexpected(&other)),
        },
    };
    println!("{}", if enabled { "on" } else { "off" });
    Ok(0)
}
