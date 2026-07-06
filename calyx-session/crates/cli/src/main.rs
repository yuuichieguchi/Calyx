//! `calyx-session`: thin CLI client for the session daemon.

mod cli;
mod commands;

use std::process::ExitCode;

use clap::Parser;

use cli::{Cli, Command};

fn main() -> ExitCode {
    let parsed = Cli::parse();
    let result = match parsed.command {
        Command::Daemon(args) => {
            commands::daemon::run(&parsed.runtime_dir, &parsed.state_dir, args)
        }
        Command::Attach(args) => {
            commands::attach::run(&parsed.runtime_dir, &parsed.state_dir, args)
        }
        Command::New(args) => commands::new::run(&parsed.runtime_dir, args),
        Command::Ls(args) => commands::ls::run(&parsed.runtime_dir, args),
        Command::Kill(args) => commands::kill::run(&parsed.runtime_dir, args),
        Command::Meta(args) => commands::meta::run(&parsed.runtime_dir, args),
        Command::History(args) => commands::history::run(&parsed.runtime_dir, args),
        Command::RemoteInstall(args) => {
            commands::remote_install::run(&parsed.runtime_dir, &parsed.state_dir, args)
        }
    };
    match result {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("calyx-session: {e}");
            ExitCode::from(1)
        }
    }
}
