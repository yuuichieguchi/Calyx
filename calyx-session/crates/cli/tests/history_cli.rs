//! `calyx-session history <on|off|status>`: exercises the daemon-wide
//! on-disk history-persistence toggle CLI surface end to end, against
//! a real `calyx-session daemon --foreground` (mirrors smoke.rs's
//! `spawn_foreground_daemon`/`run_cli` harness; duplicated here rather
//! than shared, since smoke.rs is this crate's only other integration
//! test file so far -- see this codebase's "introduce an abstraction
//! only at the third duplication" convention).
//!
//! TDD Red phase, P6 RED2: `commands::history::run` is
//! `unimplemented!()` (see that module's own header), so calling it at
//! all -- regardless of which subcommand or whether a daemon is even
//! reachable -- panics the CLI process (exit code 101, stderr naming
//! the stub). Every test below currently fails for that reason: the
//! `on`/`off`/`status` tests via their exit-code/stdout assertions, and
//! the daemon-unreachable test via its exact exit-code-1 assertion
//! (101 != 1) and exact stderr-prefix assertion (a panic message does
//! not start with "calyx-session: ") -- deliberately NOT a bare
//! `!success()` check, which would trivially pass against either exit
//! code and prove nothing about which failure mode occurred.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct DaemonGuard(Child);

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_calyx-session"))
}

fn wait_for_socket(path: &Path, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn spawn_foreground_daemon(runtime_dir: &Path, state_dir: &Path) -> DaemonGuard {
    let child = Command::new(bin())
        .args([
            "--runtime-dir".as_ref(),
            runtime_dir.as_os_str(),
            "--state-dir".as_ref(),
            state_dir.as_os_str(),
            "daemon".as_ref(),
            "--foreground".as_ref(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let guard = DaemonGuard(child);

    let socket_path = runtime_dir.join("sessiond.sock");
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "daemon --foreground should create {} within 5s",
        socket_path.display()
    );
    guard
}

fn run_cli(runtime_dir: &Path, state_dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
}

/// R-A1: `history on` sends `SetHistoryEnabled { enabled: true }` and
/// prints the confirmed state (`SetHistoryEnabledOk`'s echoed value)
/// as a bare `on` line.
#[test]
fn history_on_enables_and_prints_confirmed_state() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let result = run_cli(&runtime_dir, &state_dir, &["history", "on"]);
    assert!(
        result.status.success(),
        "history on should succeed, got {result:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&result.stdout).trim(),
        "on",
        "history on should print the confirmed state as a bare `on` line"
    );
}

/// R-A2: `history off` mirrors R-A1 with `enabled: false`.
#[test]
fn history_off_disables_and_prints_confirmed_state() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    // Flip on first so `off` is an observable transition, not a no-op
    // against the bind-time default (already off).
    let on_result = run_cli(&runtime_dir, &state_dir, &["history", "on"]);
    assert!(
        on_result.status.success(),
        "history on should succeed, got {on_result:?}"
    );

    let result = run_cli(&runtime_dir, &state_dir, &["history", "off"]);
    assert!(
        result.status.success(),
        "history off should succeed, got {result:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&result.stdout).trim(),
        "off",
        "history off should print the confirmed state as a bare `off` line"
    );
}

/// R-A3: `history status` reports the current state without mutating
/// it -- two consecutive `status` calls must both report the same
/// value.
#[test]
fn history_status_reports_without_mutating() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let initial = run_cli(&runtime_dir, &state_dir, &["history", "status"]);
    assert!(
        initial.status.success(),
        "history status should succeed, got {initial:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&initial.stdout).trim(),
        "off",
        "bind-time default is off, and status must report it unchanged"
    );

    let on_result = run_cli(&runtime_dir, &state_dir, &["history", "on"]);
    assert!(
        on_result.status.success(),
        "history on should succeed, got {on_result:?}"
    );

    let after_on = run_cli(&runtime_dir, &state_dir, &["history", "status"]);
    assert_eq!(
        String::from_utf8_lossy(&after_on.stdout).trim(),
        "on",
        "status should reflect the prior `on`, got {after_on:?}"
    );

    // A second, immediately repeated `status` must report the exact
    // same value: status must never itself be the thing that flips
    // state.
    let after_on_again = run_cli(&runtime_dir, &state_dir, &["history", "status"]);
    assert_eq!(
        String::from_utf8_lossy(&after_on_again.stdout).trim(),
        "on",
        "a second consecutive status must not have changed anything, got {after_on_again:?}"
    );
}

/// R-A4: with no daemon reachable at `runtime_dir`, `history status`
/// (representative of all three subcommands, which share one connect
/// path) exits via the crate's standard error convention: exit code 1,
/// stderr prefixed `"calyx-session: "` (`CommandError::Io` from a
/// failed `DaemonClient::connect`, printed by `main`) -- the same path
/// `kill`/`meta` already rely on with no daemon running.
#[test]
fn history_status_daemon_unreachable_exits_with_standard_error_convention() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    std::fs::create_dir_all(&runtime_dir).expect("create empty scratch runtime dir");

    let result = run_cli(&runtime_dir, &state_dir, &["history", "status"]);
    assert_eq!(
        result.status.code(),
        Some(1),
        "history status with no daemon reachable should exit code 1 (main's standard CommandError::Io \
         path), got {result:?}"
    );
    let stderr = String::from_utf8_lossy(&result.stderr);
    assert!(
        stderr.starts_with("calyx-session: "),
        "stderr should use the crate's standard error prefix, got {stderr:?}"
    );
}
