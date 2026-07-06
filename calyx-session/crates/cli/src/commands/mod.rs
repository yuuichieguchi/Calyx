//! Subcommand implementations.

pub mod attach;
pub(crate) mod client;
pub mod daemon;
pub mod history;
pub mod kill;
pub mod ls;
pub mod meta;
pub mod new;
pub mod remote_install;
pub mod upgrade;

use std::fmt;
use std::path::{Path, PathBuf};

/// Error type returned by every subcommand's `run`.
#[derive(Debug)]
pub enum CommandError {
    Io(std::io::Error),
    Protocol(proto::ProtoError),
    Daemon(::daemon::DaemonError),
    /// The daemon replied with `ControlMsg::Err`.
    Server {
        code: String,
        msg: String,
    },
    RemoteInstall(remote_install::RemoteInstallError),
}

impl fmt::Display for CommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CommandError::Io(e) => write!(f, "{e}"),
            CommandError::Protocol(e) => write!(f, "{e}"),
            CommandError::Daemon(e) => write!(f, "{e}"),
            CommandError::Server { code, msg } => write!(f, "daemon error [{code}]: {msg}"),
            CommandError::RemoteInstall(e) => write!(f, "{e}"),
        }
    }
}

impl From<remote_install::RemoteInstallError> for CommandError {
    fn from(e: remote_install::RemoteInstallError) -> Self {
        CommandError::RemoteInstall(e)
    }
}

impl From<std::io::Error> for CommandError {
    fn from(e: std::io::Error) -> Self {
        CommandError::Io(e)
    }
}

impl From<proto::ProtoError> for CommandError {
    fn from(e: proto::ProtoError) -> Self {
        CommandError::Protocol(e)
    }
}

impl From<::daemon::DaemonError> for CommandError {
    fn from(e: ::daemon::DaemonError) -> Self {
        CommandError::Daemon(e)
    }
}

/// Resolves the runtime directory: `runtime_dir` if given, else
/// `$HOME/.calyx/run`. Every subcommand takes `runtime_dir` from the
/// top-level `Cli` (global flag), so tests always pass an explicit
/// scratch directory here and never hit the `$HOME` fallback.
pub fn resolve_runtime_dir(runtime_dir: &Option<PathBuf>) -> PathBuf {
    runtime_dir
        .clone()
        .unwrap_or_else(|| default_home_subdir("run"))
}

/// Resolves the state directory: `state_dir` if given, else
/// `$HOME/.calyx/state`. See `resolve_runtime_dir`.
pub fn resolve_state_dir(state_dir: &Option<PathBuf>) -> PathBuf {
    state_dir
        .clone()
        .unwrap_or_else(|| default_home_subdir("state"))
}

fn default_home_subdir(leaf: &str) -> PathBuf {
    let home = std::env::var_os("HOME")
        .expect("HOME must be set to resolve the default calyx-session directories");
    Path::new(&home).join(".calyx").join(leaf)
}

/// Where every non-`daemon` subcommand finds the daemon's socket.
pub fn socket_path(runtime_dir: &Option<PathBuf>) -> PathBuf {
    resolve_runtime_dir(runtime_dir).join(::daemon::SOCKET_FILE)
}
