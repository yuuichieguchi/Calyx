use std::path::PathBuf;

use proto::{ControlMsg, SessionSpec};

use crate::cli::NewArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

/// Creates a new session (via `ControlMsg::New`) without attaching to
/// it, printing the resulting session id. No daemon auto-start: only
/// `attach` does that.
pub fn run(runtime_dir: &Option<PathBuf>, args: NewArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    let (cols, rows) = crate::commands::attach::tty_size().unwrap_or((80, 24));
    let spec = SessionSpec {
        id: ulid::Ulid::new().to_string(),
        name: args.name,
        cwd: args.cwd,
        argv: (!args.argv.is_empty()).then_some(args.argv),
        // Unlike attach.rs, no resolve_shell_integration_env here: no
        // production caller synthesizes sessions via `new`, so wiring
        // the ghostty shell-integration env in is deferred.
        env: vec![],
        cols,
        rows,
    };
    match client.request(&ControlMsg::New { spec })? {
        ControlMsg::NewOk { info } => {
            println!("{}", info.id);
            Ok(0)
        }
        ControlMsg::Err { code, msg } => Err(server_err(code, msg)),
        other => Err(unexpected(&other)),
    }
}
