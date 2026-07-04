//! Argument parsing for the `calyx-session` binary.

use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "calyx-session", about = "Local PTY session daemon + client")]
pub struct Cli {
    /// Overrides the directory holding the daemon's Unix socket
    /// (default: `$HOME/.calyx/run`). Global so every subcommand, not
    /// just `daemon`, can be pointed at a scratch directory in tests —
    /// no subcommand may ever fall back to a real `~/.calyx` path
    /// implicitly during a test run.
    #[arg(long, global = true)]
    pub runtime_dir: Option<PathBuf>,
    /// Overrides the directory holding the session ledger (default:
    /// `$HOME/.calyx/state`). See `runtime_dir` for why this is global.
    #[arg(long, global = true)]
    pub state_dir: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Run the session daemon.
    Daemon(DaemonArgs),
    /// Attach to a session, creating it first if requested.
    Attach(AttachArgs),
    /// Create a new session without attaching to it.
    New(NewArgs),
    /// List sessions.
    Ls(LsArgs),
    /// Kill a session.
    Kill(KillArgs),
    /// Get/set session metadata.
    Meta(MetaArgs),
}

#[derive(Args, Debug)]
pub struct DaemonArgs {
    /// Run in the foreground instead of double-forking into the
    /// background.
    #[arg(long)]
    pub foreground: bool,
}

#[derive(Args, Debug)]
pub struct AttachArgs {
    pub id: String,
    /// Create the session if `id` doesn't already exist.
    #[arg(long)]
    pub create: bool,
    #[arg(long)]
    pub cwd: Option<String>,
    #[arg(long)]
    pub name: Option<String>,
    /// The command to run when creating a new session (repeat per
    /// argv element, e.g. `--argv /bin/sh --argv -c --argv 'exit 0'`).
    /// Not in the original P2 spec's flag list; added because the CLI
    /// smoke test needs a way to create a session that exits
    /// immediately, which isn't reachable through `--create` alone
    /// (that spawns the daemon's default shell).
    #[arg(long = "argv", allow_hyphen_values = true)]
    pub argv: Vec<String>,
}

#[derive(Args, Debug)]
pub struct NewArgs {
    #[arg(long)]
    pub cwd: Option<String>,
    #[arg(long)]
    pub name: Option<String>,
    #[arg(long = "argv", allow_hyphen_values = true)]
    pub argv: Vec<String>,
}

#[derive(Args, Debug)]
pub struct LsArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Args, Debug)]
pub struct KillArgs {
    pub id: String,
}

#[derive(Args, Debug)]
pub struct MetaArgs {
    #[command(subcommand)]
    pub command: MetaCommand,
}

#[derive(Subcommand, Debug)]
pub enum MetaCommand {
    Set {
        id: String,
        /// `key=value`.
        #[arg(value_parser = parse_kv)]
        kv: (String, String),
    },
    Get {
        id: String,
    },
}

fn parse_kv(s: &str) -> Result<(String, String), String> {
    match s.split_once('=') {
        Some((k, v)) => Ok((k.to_string(), v.to_string())),
        None => Err(format!("expected key=value, got `{s}`")),
    }
}
