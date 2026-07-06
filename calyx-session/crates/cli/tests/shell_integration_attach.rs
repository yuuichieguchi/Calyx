//! Execution-based end-to-end test for the ghostty shell-integration
//! fix (see `crates/cli/src/commands/shell_integration.rs`'s module
//! doc for the full bug writeup): with `GHOSTTY_RESOURCES_DIR` present
//! in the attach client's own environment -- exactly what a real
//! ghostty tab sets, unconditionally, before spawning any command
//! (`ghostty/src/termio/Exec.zig`'s `Subprocess.init`) -- a session
//! created via `calyx-session attach --create` running an interactive
//! zsh should now emit ghostty's OSC 7 `kitty-shell-cwd` escape
//! sequence once the shell reaches its first prompt, via the REAL
//! bundled `shell-integration/zsh/{.zshenv,ghostty-integration}`
//! scripts. Those scripts are read from their submodule SOURCE
//! location (`ghostty/src/shell-integration/zsh/`), not a built
//! resources bundle (`zig-out/...`), so this test doesn't depend on a
//! prior `zig build` having run -- only on the `ghostty` submodule
//! being checked out, which `ghostty_zsh_resources_dir` asserts
//! explicitly (a real, actionable failure if it isn't, not a silent
//! skip).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct ChildGuard(Child);

impl Drop for ChildGuard {
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

/// The real ghostty zsh shell-integration scripts, at their submodule
/// SOURCE location. Present in any checkout with the `ghostty`
/// submodule initialized, regardless of build state.
fn ghostty_zsh_resources_dir() -> PathBuf {
    let candidate = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../ghostty/src");
    let dir = candidate.canonicalize().unwrap_or_else(|e| {
        panic!(
            "resolve {} relative to the cli crate: {e}",
            candidate.display()
        )
    });
    let zshenv = dir.join("shell-integration/zsh/.zshenv");
    assert!(
        zshenv.is_file(),
        "expected the ghostty submodule's zsh shell-integration scripts at {}; \
         is the `ghostty` submodule checked out?",
        zshenv.display()
    );
    dir
}

#[test]
fn attach_create_with_ghostty_resources_dir_emits_osc7_for_an_interactive_zsh_session() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");

    let daemon_child = Command::new(bin())
        .args([
            "--runtime-dir".as_ref(),
            runtime_dir.as_os_str(),
            "--state-dir".as_ref(),
            state_dir.as_os_str(),
            "daemon".as_ref(),
            "--foreground".as_ref(),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let _daemon_guard = ChildGuard(daemon_child);

    let socket_path = runtime_dir.join("sessiond.sock");
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "daemon --foreground should create {} within 5s",
        socket_path.display()
    );

    let resources_dir = ghostty_zsh_resources_dir();

    let mut attach_child = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            "01J-p2-shell-integration-osc7",
            "--create",
            "--argv",
            "/bin/zsh",
        ])
        // Mirrors what a real ghostty tab sets in the attach client's
        // own environment before spawning it, plus a zsh-user $SHELL,
        // so `resolve_shell_integration_env`
        // (crates/cli/src/commands/shell_integration.rs) has exactly
        // what it needs to compute the zsh integration env for this
        // session.
        .env("GHOSTTY_RESOURCES_DIR", resources_dir.as_os_str())
        .env("SHELL", "/bin/zsh")
        .env_remove("ZDOTDIR")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session attach --create`");
    let mut stdout = attach_child.stdout.take().expect("attach child stdout");
    let mut stderr = attach_child.stderr.take().expect("attach child stderr");
    let _attach_guard = ChildGuard(attach_child);

    // Read the attach client's stdout (the session's raw PTY output,
    // per `attach.rs`'s `bridge()`) on a background thread, since a
    // live interactive shell never closes it on its own; the main
    // thread polls a bounded snapshot instead of blocking on `read`.
    let acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    {
        let acc = Arc::clone(&acc);
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match stdout.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => acc
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .extend_from_slice(&buf[..n]),
                }
            }
        });
    }
    // Drained so a failing attach client can't block on a full stderr
    // pipe; not asserted on directly, but kept around so a captured
    // error message can be attached to the eventual timeout failure
    // below for a clearer diagnosis.
    let stderr_acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    {
        let stderr_acc = Arc::clone(&stderr_acc);
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match stderr.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => stderr_acc
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .extend_from_slice(&buf[..n]),
                }
            }
        });
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
        if snapshot.windows(4).any(|w| w == b"\x1b]7;") {
            break;
        }
        if Instant::now() >= deadline {
            let stderr_snapshot = stderr_acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
            panic!(
                "expected an OSC 7 (\\x1b]7;kitty-shell-cwd://) escape sequence in \
                 the attached session's output within 5s, got stdout={:?} stderr={:?}",
                String::from_utf8_lossy(&snapshot),
                String::from_utf8_lossy(&stderr_snapshot)
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
