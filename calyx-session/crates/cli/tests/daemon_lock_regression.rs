//! Regression guard for the ORDINARY (non-handoff) daemon start's
//! single-daemon lock collapse behavior: `commands::daemon::run_daemonized`
//! opens+flocks `runtime_dir/sessiond.lock` exclusively and
//! non-blockingly before ever binding the control socket, so a second
//! concurrent `calyx-session daemon` invocation against the same
//! `runtime_dir` must collapse (its grandchild `_exit(0)`s on the
//! conflicting flock) rather than replace the first daemon.
//!
//! Pinned here as an explicit regression guard for P6 review E5 (Live
//! Handoff's un-transferred single-daemon lock): E5's fix touches this
//! same lock file's *transfer* path for `run_handoff_receiver`
//! (`crate::daemon::handoff`), and this test's job is to prove the
//! ORDINARY, non-handoff path (`run_daemonized`, untouched by that
//! work) still behaves exactly as before.
//!
//! `wait_for_socket`/`bin`/`run_cli` duplicate `smoke.rs`'s and
//! `history_cli.rs`'s own copies of the same small helpers rather than
//! sharing them, matching this crate's existing precedent for this
//! situation (see `history_cli.rs`'s header) at the time this test was
//! written.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

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

fn run_cli(runtime_dir: &Path, state_dir: &Path, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(args)
        .stdin(Stdio::null())
        .output()
        .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
}

/// R4 (P6 review E5, regression guard): a second concurrent, real
/// (double-forking, backgrounded) `daemon` start against the same
/// `runtime_dir`/`state_dir` must collapse instead of replacing the
/// first daemon. Proven behaviorally rather than via the launching
/// CLI process's own exit code: `commands::daemon::run` always
/// returns `Ok(0)` from the *original* invoking process regardless of
/// whether its detached grandchild wins or loses the flock (the
/// collapse/`_exit(0)` happens in that grandchild, which the
/// original process never waits on) -- so the observable here is
/// whether a session created against the first daemon is still
/// reachable through its LIVE registry (via `kill`) after the second
/// invocation, which only holds if the first daemon is still the one
/// actually serving the socket.
#[test]
fn second_concurrent_daemon_start_collapses_and_the_first_keeps_serving() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");

    let first = run_cli(&runtime_dir, &state_dir, &["daemon"]);
    assert!(
        first.status.success(),
        "first `daemon` invocation should succeed, got {first:?}"
    );
    let socket_path = runtime_dir.join("sessiond.sock");
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "the first daemon should create {} within 5s",
        socket_path.display()
    );

    // A long-lived session: if a rogue second daemon replaced the
    // first, it would start with an empty in-memory live registry (it
    // never inherited this session's PTY fd or session thread), so
    // `kill` against it would not succeed the way it does against the
    // real owning daemon's live registry.
    let new_result = run_cli(&runtime_dir, &state_dir, &["new", "--argv", "/bin/cat"]);
    assert!(
        new_result.status.success(),
        "new should succeed against the first daemon, got {new_result:?}"
    );
    let id = String::from_utf8_lossy(&new_result.stdout)
        .trim()
        .to_string();
    assert!(!id.is_empty(), "new should print the created session's id");

    // Second concurrent `daemon` invocation against the SAME dirs:
    // this must collapse (the single-daemon lock's job) rather than
    // replace the first daemon's listener/registry. By the time the
    // first daemon's socket exists (already awaited above), it has
    // definitely already acquired the flock (lock acquisition happens
    // before the socket bind in `run_daemonized`), so this second
    // attempt is guaranteed to lose, not win, the race.
    let second = run_cli(&runtime_dir, &state_dir, &["daemon"]);
    assert!(
        second.status.success(),
        "a second concurrent `daemon` invocation should still exit 0 (the launching \
         CLI process always returns quickly regardless of which grandchild wins the \
         lock); got {second:?}"
    );

    // Give any losing grandchild a moment to actually collapse
    // (`_exit(0)` on the conflicting flock) before checking who is
    // still serving.
    std::thread::sleep(Duration::from_millis(300));

    let kill_result = run_cli(&runtime_dir, &state_dir, &["kill", &id]);
    assert!(
        kill_result.status.success(),
        "killing the session created before the second daemon start should still \
         succeed against the ORIGINAL daemon's live registry, proving the second \
         invocation collapsed instead of replacing it; got {kill_result:?}"
    );
}
