//! Test 19 (spec): `calyx-session daemon --foreground` serves `new` /
//! `ls --json` / `kill` against scratch directories, plus a smoke test
//! for `attach`'s exit-code contract (raw-tty bridging itself is not
//! automatable, per spec, so this only covers the immediate-exit case).
//!
//! `wait_for_socket` bounds the wait for the daemon's socket so a
//! daemon that fails to start surfaces as a bounded-time failure
//! instead of hanging the suite.

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

/// Spawns `calyx-session --runtime-dir <dir> --state-dir <dir> daemon
/// --foreground` and waits (bounded) for its socket to appear.
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

#[test]
fn daemon_foreground_serves_new_ls_kill_over_scratch_dirs() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let run_cli = |args: &[&str]| {
        Command::new(bin())
            .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
            .args(["--state-dir", state_dir.to_str().unwrap()])
            .args(args)
            .output()
            .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
    };

    let ls_empty = run_cli(&["ls", "--json"]);
    assert!(
        ls_empty.status.success(),
        "ls --json should succeed, got {ls_empty:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&ls_empty.stdout).trim(),
        "[]",
        "ls --json should start empty"
    );

    let new_result = run_cli(&["new"]);
    assert!(
        new_result.status.success(),
        "new should succeed, got {new_result:?}"
    );

    let ls_after_new = run_cli(&["ls", "--json"]);
    assert!(
        ls_after_new.status.success(),
        "ls --json (after new) should succeed, got {ls_after_new:?}"
    );
    let sessions: Vec<serde_json::Value> = serde_json::from_slice(&ls_after_new.stdout)
        .expect("ls --json output should be valid JSON after `new`");
    assert_eq!(
        sessions.len(),
        1,
        "ls --json should report exactly 1 session after `new`, got {sessions:?}"
    );
    let id = sessions[0]
        .get("id")
        .and_then(|v| v.as_str())
        .expect("each ls --json entry should have a string `id` field")
        .to_string();

    let kill_result = run_cli(&["kill", &id]);
    assert!(
        kill_result.status.success(),
        "kill should succeed, got {kill_result:?}"
    );

    let ls_after_kill = run_cli(&["ls", "--json"]);
    assert_eq!(
        String::from_utf8_lossy(&ls_after_kill.stdout).trim(),
        "[]",
        "ls --json should be empty again after kill"
    );
}

/// Regression test (P3 review): the Swift side currently approximates
/// "absent from `ls` == exited(code: 0)", since the CLI has no way to
/// read a session's *real* exit code from the ledger (the `ListAll`
/// protocol message exists in the daemon since P2, but no CLI flag
/// reaches it). `ls --all --json` should report the full ledger view
/// (running *and* exited sessions, the latter with their real exit
/// code), matching `ListAllOk`'s `SessionInfo` serialization — the same
/// shape `ls --json` already uses for `ListOk`.
///
/// `--all` doesn't exist on the current CLI, so this fails at clap's
/// argument parsing before ever reaching the daemon.
#[test]
fn ls_all_reports_exited_sessions_with_their_real_exit_code() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let run_cli = |args: &[&str]| {
        Command::new(bin())
            .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
            .args(["--state-dir", state_dir.to_str().unwrap()])
            .args(args)
            .output()
            .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
    };

    let new_result = run_cli(&[
        "new", "--argv", "/bin/sh", "--argv", "-c", "--argv", "exit 7",
    ]);
    assert!(
        new_result.status.success(),
        "new should succeed, got {new_result:?}"
    );
    let id = String::from_utf8_lossy(&new_result.stdout)
        .trim()
        .to_string();
    assert!(!id.is_empty(), "new should print the created session's id");

    // Deterministic wait for exit: poll the *existing* `ls --json`
    // (unaffected by this test's --all addition) until the session's
    // exit removes it from the live registry view.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let ls_live = run_cli(&["ls", "--json"]);
        assert!(
            ls_live.status.success(),
            "ls --json should succeed, got {ls_live:?}"
        );
        let sessions: Vec<serde_json::Value> =
            serde_json::from_slice(&ls_live.stdout).expect("ls --json output should be valid JSON");
        let still_live = sessions
            .iter()
            .any(|s| s.get("id").and_then(|v| v.as_str()) == Some(id.as_str()));
        if !still_live {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "session {id} should exit within 5s, still in ls --json: {sessions:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let ls_live_after = run_cli(&["ls", "--json"]);
    let live_sessions: Vec<serde_json::Value> = serde_json::from_slice(&ls_live_after.stdout)
        .expect("ls --json output should be valid JSON");
    assert!(
        !live_sessions
            .iter()
            .any(|s| s.get("id").and_then(|v| v.as_str()) == Some(id.as_str())),
        "an exited session should not appear in plain `ls --json`, got {live_sessions:?}"
    );

    let ls_all = run_cli(&["ls", "--all", "--json"]);
    assert!(
        ls_all.status.success(),
        "ls --all --json should succeed, got {ls_all:?}"
    );
    let all_sessions: Vec<serde_json::Value> = serde_json::from_slice(&ls_all.stdout)
        .expect("ls --all --json output should be valid JSON");
    let entry = all_sessions
        .iter()
        .find(|s| s.get("id").and_then(|v| v.as_str()) == Some(id.as_str()))
        .unwrap_or_else(|| {
            panic!("ls --all --json should include the exited session {id}, got {all_sessions:?}")
        });
    assert_eq!(
        entry.get("state"),
        Some(&serde_json::json!({"Exited": {"code": 7}})),
        "exited session should report state Exited with its real code (7), got {entry:?}"
    );
}

/// `ls --all --json` must report *running* sessions too (a full ledger
/// view, not exited-only).
#[test]
fn ls_all_includes_running_sessions_too() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let run_cli = |args: &[&str]| {
        Command::new(bin())
            .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
            .args(["--state-dir", state_dir.to_str().unwrap()])
            .args(args)
            .output()
            .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
    };

    // /bin/cat never exits on its own within this test.
    let new_result = run_cli(&["new", "--argv", "/bin/cat"]);
    assert!(
        new_result.status.success(),
        "new should succeed, got {new_result:?}"
    );
    let id = String::from_utf8_lossy(&new_result.stdout)
        .trim()
        .to_string();

    let ls_all = run_cli(&["ls", "--all", "--json"]);
    assert!(
        ls_all.status.success(),
        "ls --all --json should succeed, got {ls_all:?}"
    );
    let all_sessions: Vec<serde_json::Value> = serde_json::from_slice(&ls_all.stdout)
        .expect("ls --all --json output should be valid JSON");
    let entry = all_sessions
        .iter()
        .find(|s| s.get("id").and_then(|v| v.as_str()) == Some(id.as_str()))
        .unwrap_or_else(|| {
            panic!(
                "ls --all --json should include the still-running session {id}, \
                 got {all_sessions:?}"
            )
        });
    assert_eq!(
        entry.get("state"),
        Some(&serde_json::json!("Running")),
        "running session should report state Running, got {entry:?}"
    );
}

#[test]
fn attach_to_an_immediately_exiting_session_returns_exit_code_0() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let attach_result = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            "01J-p2-cli-attach-smoke",
            "--create",
            "--argv",
            "/bin/sh",
            "--argv",
            "-c",
            "--argv",
            "exit 0",
        ])
        .stdin(Stdio::null())
        .output()
        .expect("run `calyx-session attach`");

    assert_eq!(
        attach_result.status.code(),
        Some(0),
        "attach to an immediately-exiting session should return exit code 0, got {attach_result:?}"
    );
}
