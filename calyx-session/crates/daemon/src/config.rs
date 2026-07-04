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
}
