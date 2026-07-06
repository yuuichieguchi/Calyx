//! Configuration for [`crate::Daemon::bind`].

use std::path::PathBuf;

/// Directories the daemon reads/writes. Both are caller-supplied (never
/// hardcoded to `~/.calyx`) so tests can point them at a scratch
/// directory and never touch a real user's home directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonConfig {
    /// Holds the listening socket (`sessiond.sock`) and, in the real
    /// CLI, the daemonization lock file. Created with mode `0700` if it
    /// does not already exist.
    pub runtime_dir: PathBuf,
    /// Holds the session ledger (`sessions.json`). Created with mode
    /// `0700` if it does not already exist.
    pub state_dir: PathBuf,
    /// Bind-time default for opt-in on-disk history persistence
    /// (`state_dir/history/<id>.raw`; see the daemon module doc). `false`
    /// (herdr parity: default off, secrets caution) unless the caller
    /// opts in, e.g. via the CLI's `daemon --persist-history` flag.
    /// Sessions created while this is `false` never touch the history
    /// directory at all. Overridable for the daemon's remaining
    /// lifetime via `ControlMsg::SetHistoryEnabled`, which affects only
    /// sessions created after it is processed.
    pub history_enabled: bool,
}
