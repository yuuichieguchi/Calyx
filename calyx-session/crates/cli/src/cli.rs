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
    /// Enable/disable/query the daemon-wide on-disk history-persistence
    /// default (via `ControlMsg::SetHistoryEnabled`/`GetHistoryEnabled`).
    History(HistoryArgs),
    /// Deploy the session daemon (and, optionally, the ghostty terminfo
    /// entry) to a remote host over ssh.
    RemoteInstall(RemoteInstallArgs),
    /// (EXPERIMENTAL) Migrate the running daemon to a new daemon binary
    /// without killing any session: PTY master fds and the listening
    /// socket are handed off via SCM_RIGHTS. See `daemon::handoff`'s
    /// module doc for the full contract and its known limitations
    /// (notably: an adopted session's exit code cannot be a real
    /// `waitpid` status).
    Upgrade(UpgradeArgs),
}

#[derive(Args, Debug)]
pub struct DaemonArgs {
    /// Run in the foreground instead of double-forking into the
    /// background.
    #[arg(long)]
    pub foreground: bool,
    /// Enable opt-in on-disk history persistence by default for
    /// sessions created by this daemon process (default off; see
    /// `daemon::DaemonConfig::history_enabled`). Overridable for the
    /// daemon's remaining lifetime without restarting it, via a future
    /// `history` subcommand that sends `ControlMsg::SetHistoryEnabled`.
    #[arg(long)]
    pub persist_history: bool,
    /// (EXPERIMENTAL, internal) Run as a Live Handoff receiver:
    /// connect to PATH (a preparing daemon's handoff endpoint), adopt
    /// its sessions and control listener, then serve in its place.
    /// Spawned by `calyx-session upgrade`; not meant for direct use.
    #[arg(long, value_name = "PATH")]
    pub handoff_connect: Option<PathBuf>,
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
    /// Include exited sessions (full ledger view via `ListAll`).
    #[arg(long)]
    pub all: bool,
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

#[derive(Args, Debug)]
pub struct HistoryArgs {
    #[command(subcommand)]
    pub command: HistoryCommand,
}

#[derive(Subcommand, Debug)]
pub enum HistoryCommand {
    /// Enable on-disk history persistence for sessions created after
    /// this point (sends `ControlMsg::SetHistoryEnabled { enabled:
    /// true }`).
    On,
    /// Disable it (sends `ControlMsg::SetHistoryEnabled { enabled:
    /// false }`).
    Off,
    /// Report whether it is currently enabled, without changing it
    /// (sends `ControlMsg::GetHistoryEnabled`).
    Status,
}

#[derive(Args, Debug)]
pub struct RemoteInstallArgs {
    /// The remote host, exactly as `ssh` itself would accept it (an
    /// `~/.ssh/config` alias, a bare hostname, or `user@host`).
    pub host: String,
    /// Local path to a Linux x86_64 calyx-session build. Required only
    /// when `ssh <host> uname -sm` detects a Linux x86_64 remote.
    #[arg(long = "payload-x86-64")]
    pub payload_x86_64: Option<PathBuf>,
    /// Local path to a Linux aarch64 calyx-session build. Required only
    /// when detection reports a Linux aarch64 remote.
    #[arg(long = "payload-aarch64")]
    pub payload_aarch64: Option<PathBuf>,
    /// Local path to this Mac's own calyx-session binary, reused as-is
    /// for a Darwin arm64 remote (no separate cross-build exists for
    /// that target: it is this machine's own build). Required only
    /// when detection reports a Darwin arm64 remote.
    #[arg(long = "host-binary")]
    pub host_binary: Option<PathBuf>,
    /// Local path to the ghostty terminfo entry to install remotely at
    /// `$HOME/.terminfo/x/xterm-ghostty`. Optional: a failure to
    /// install it is reported as a warning, not an error, since the
    /// session still works remotely with `TERM=xterm-256color`.
    #[arg(long = "terminfo")]
    pub terminfo: Option<PathBuf>,
}

#[derive(Args, Debug)]
pub struct UpgradeArgs {
    /// Path to the new daemon binary to hand sessions off to (default:
    /// this CLI's own executable path, i.e. upgrading in place to
    /// whatever `calyx-session` binary is currently installed).
    #[arg(long)]
    pub binary: Option<PathBuf>,
}

fn parse_kv(s: &str) -> Result<(String, String), String> {
    match s.split_once('=') {
        Some((k, v)) => Ok((k.to_string(), v.to_string())),
        None => Err(format!("expected key=value, got `{s}`")),
    }
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;

    use super::*;

    /// R6 (P6 RED3): `upgrade` parses with no flags, defaulting
    /// `binary` to `None` (resolved by `commands::upgrade::run` to
    /// `std::env::current_exe()`).
    #[test]
    fn upgrade_parses_with_default_binary_none() {
        let cli = Cli::try_parse_from(["calyx-session", "upgrade"])
            .expect("upgrade should parse with no flags");
        match cli.command {
            Command::Upgrade(args) => assert_eq!(args.binary, None),
            other => panic!("expected Command::Upgrade, got {other:?}"),
        }
    }

    /// R6: `upgrade --binary <path>` overrides the default.
    #[test]
    fn upgrade_parses_an_explicit_binary_path() {
        let cli = Cli::try_parse_from([
            "calyx-session",
            "upgrade",
            "--binary",
            "/tmp/new-calyx-session",
        ])
        .expect("upgrade --binary should parse");
        match cli.command {
            Command::Upgrade(args) => {
                assert_eq!(args.binary, Some(PathBuf::from("/tmp/new-calyx-session")));
            }
            other => panic!("expected Command::Upgrade, got {other:?}"),
        }
    }

    /// R6: the `upgrade` subcommand's help text calls out that the
    /// feature is experimental, so a user invoking it (or reading
    /// `calyx-session help`) is not surprised by its known limitations
    /// (see `daemon::handoff`'s module doc).
    #[test]
    fn upgrade_subcommand_help_is_marked_experimental() {
        let cmd = Cli::command();
        let upgrade = cmd
            .find_subcommand("upgrade")
            .expect("upgrade subcommand should be registered");
        let about = upgrade
            .get_about()
            .map(|s| s.to_string())
            .unwrap_or_default();
        assert!(
            about.to_uppercase().contains("EXPERIMENTAL"),
            "upgrade's help text should call out that it is experimental, got: {about:?}"
        );
    }
}
