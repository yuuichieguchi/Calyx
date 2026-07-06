//! Computes the ghostty shell-integration environment that `attach`
//! (and, in the future, `new`) forwards into a session's
//! `SessionSpec.env` when creating it.
//!
//! THE BUG this exists to fix: ghostty only injects its shell
//! integration (title, OSC 7 pwd, prompt marks) into a surface's child
//! process when that surface's command is a *recognized shell*
//! (`ghostty/src/termio/shell_integration.zig`'s `setup` ->
//! `detectShell`). A persistent pane's command is `calyx-session attach
//! ...`, not a shell, so ghostty skips integration entirely and the
//! daemon then spawns the user's `$SHELL` with no integration env at
//! all: no title, no OSC 7, no prompt marks, forever. The fix is for
//! the attach client to reproduce ghostty's own zsh setup (the same
//! env a normal ghostty-spawned zsh tab gets) and forward it into
//! `SessionSpec.env`, so the daemon-hosted shell gets integration too.
//!
//! CONTRACT for `shell_integration_env(shell_path, ghostty_resources_dir,
//! original_zdotdir)`, verified against the bundled ghostty scripts and
//! `ghostty/src/termio/shell_integration.zig` /
//! `ghostty/src/termio/Exec.zig` / `ghostty/src/config/Config.zig`:
//!
//! - `ghostty_resources_dir` absent -> empty vec, no injection, no
//!   panic (the attach client isn't running inside a ghostty-
//!   integrated shell, or is running outside ghostty entirely).
//! - `shell_path`'s basename is `zsh` and a resources dir is present:
//!   - `ZDOTDIR` = `"{resources_dir}/shell-integration/zsh"` (the
//!     bundled zsh integration directory; mirrors
//!     `setupZsh`'s `{resource_dir}/shell-integration/zsh` in
//!     `shell_integration.zig`).
//!   - `GHOSTTY_ZSH_ZDOTDIR` = `original_zdotdir`'s value, present
//!     ONLY if `original_zdotdir` is `Some` (so the bundled `.zshenv`
//!     restores it once the shell starts). If `original_zdotdir` is
//!     `None`, this key must be ABSENT (not set to an empty string):
//!     the bundled `.zshenv` treats "GHOSTTY_ZSH_ZDOTDIR unset" and
//!     "GHOSTTY_ZSH_ZDOTDIR set to empty" differently (only the former
//!     falls back to `$HOME`; see `shell-integration/zsh/.zshenv`'s
//!     `[[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]` existence check).
//!   - `GHOSTTY_SHELL_FEATURES` = `"cursor:blink,path,title"`. This is
//!     ghostty's actual DEFAULT `shell-integration-features` value
//!     (`Config.zig`'s `ShellIntegrationFeatures{ cursor: true, sudo:
//!     false, title: true, ssh-env: false, ssh-terminfo: false, path:
//!     true }`, with `cursor_blink` defaulting to `true` per
//!     `Exec.zig`'s `cfg.cursor_blink orelse true`), sorted the same
//!     way `setupFeatures` sorts them (alphabetically by field name).
//!     Only `title` (title escape) and `path` (OSC 7 depends on
//!     `_ghostty_report_pwd`, which fires unconditionally once
//!     `ghostty-integration` is loaded, but the title escape in that
//!     same script IS gated on the `title` feature) are load-bearing
//!     for this bug; `sudo`/`ssh-env`/`ssh-terminfo` are NOT part of
//!     ghostty's default and must not be claimed as such.
//!   - `GHOSTTY_RESOURCES_DIR` = `ghostty_resources_dir`'s value
//!     (forwarded as-is; `ghostty-integration`'s `path`/`sudo` blocks
//!     and a user's own manually-sourced integration both read it).
//! - `shell_path`'s basename is anything other than `zsh` (e.g.
//!   `/bin/bash`) -> empty vec, THIS CYCLE. Scope decision: bash uses
//!   a completely different mechanism (`ENV`/`GHOSTTY_BASH_*`,
//!   `setupBash` in `shell_integration.zig`) and fish/elvish use
//!   `XDG_DATA_DIRS` (`setupXdgDataDirs`); neither is wired here.
//!   Forwarding only `GHOSTTY_RESOURCES_DIR` for an unintegrated shell
//!   was considered and rejected: some of ghostty's own scripts (and
//!   user rc files that manually source them) gate solely on
//!   `-n "$GHOSTTY_RESOURCES_DIR"` before sourcing, so leaking that one
//!   variable without the rest of the integration wired up could
//!   trigger a partial, broken manual-integration attempt in a shell
//!   this fix doesn't otherwise support. Injecting nothing at all is
//!   the safe default until bash/fish/elvish are each wired
//!   individually (extension point: match on `shell_path`'s basename
//!   here and add a `setup_bash`/`setup_xdg_shell`-style branch
//!   alongside `zsh`'s).

use std::path::Path;

/// Pure: computes the ghostty zsh shell-integration environment to
/// forward into a new session's `SessionSpec.env`. See this module's
/// doc comment for the full contract. Zsh-only this cycle; any other
/// shell (or a missing `ghostty_resources_dir`) yields an empty vec.
pub(crate) fn shell_integration_env(
    shell_path: &str,
    ghostty_resources_dir: Option<&str>,
    original_zdotdir: Option<&str>,
) -> Vec<(String, String)> {
    let Some(resources_dir) = ghostty_resources_dir else {
        return Vec::new();
    };
    if !is_zsh(shell_path) {
        // Zsh-only this cycle; the module doc records the extension
        // point for bash (ENV/GHOSTTY_BASH_*) and fish/elvish
        // (XDG_DATA_DIRS), and why injecting nothing is the safe
        // default for them until each is wired individually.
        return Vec::new();
    }
    let mut env = vec![(
        "ZDOTDIR".to_string(),
        format!("{resources_dir}/shell-integration/zsh"),
    )];
    if let Some(original) = original_zdotdir {
        // Present only when the caller had a ZDOTDIR at all: the
        // bundled .zshenv distinguishes unset (fall back to $HOME)
        // from set-to-empty via its `${GHOSTTY_ZSH_ZDOTDIR+X}` check.
        env.push(("GHOSTTY_ZSH_ZDOTDIR".to_string(), original.to_string()));
    }
    env.push((
        "GHOSTTY_SHELL_FEATURES".to_string(),
        "cursor:blink,path,title".to_string(),
    ));
    env.push((
        "GHOSTTY_RESOURCES_DIR".to_string(),
        resources_dir.to_string(),
    ));
    env
}

/// Reads `$SHELL` / `$GHOSTTY_RESOURCES_DIR` / `$ZDOTDIR` through
/// `get_env` (injected so tests don't have to mutate real process env
/// vars, which race across parallel test threads) and delegates to
/// `shell_integration_env`. This is the seam `attach.rs`'s session-
/// creation path calls; production wiring passes
/// `|k| std::env::var(k).ok()`.
pub(crate) fn resolve_shell_integration_env(
    get_env: impl Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let resources_dir = get_env("GHOSTTY_RESOURCES_DIR");
    let shell_path = get_env("SHELL").unwrap_or_default();
    let original_zdotdir = get_env("ZDOTDIR");
    shell_integration_env(
        &shell_path,
        resources_dir.as_deref(),
        original_zdotdir.as_deref(),
    )
}

/// `true` if `shell_path`'s basename is exactly `zsh` (mirrors
/// `detectShell`'s `std.mem.eql(u8, "zsh", exe)` check in
/// `shell_integration.zig`, minus the bash-specific darwin carve-out
/// that doesn't apply here). Exposed so the pure function and its
/// tests agree on exactly one definition of "is a zsh shell".
pub(crate) fn is_zsh(shell_path: &str) -> bool {
    Path::new(shell_path).file_name().and_then(|n| n.to_str()) == Some("zsh")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn as_map(pairs: Vec<(String, String)>) -> BTreeMap<String, String> {
        let map: BTreeMap<String, String> = pairs.into_iter().collect();
        map
    }

    // ==================== R1 ====================
    // zsh + resources dir present + original ZDOTDIR set.

    #[test]
    fn zsh_with_resources_dir_and_original_zdotdir_returns_full_env() {
        let result = shell_integration_env(
            "/bin/zsh",
            Some("/opt/ghostty-resources"),
            Some("/Users/alice/.config/zsh"),
        );

        let expected: BTreeMap<String, String> = [
            (
                "ZDOTDIR".to_string(),
                "/opt/ghostty-resources/shell-integration/zsh".to_string(),
            ),
            (
                "GHOSTTY_ZSH_ZDOTDIR".to_string(),
                "/Users/alice/.config/zsh".to_string(),
            ),
            (
                "GHOSTTY_SHELL_FEATURES".to_string(),
                "cursor:blink,path,title".to_string(),
            ),
            (
                "GHOSTTY_RESOURCES_DIR".to_string(),
                "/opt/ghostty-resources".to_string(),
            ),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            as_map(result),
            expected,
            "zsh + resources dir + an original ZDOTDIR should forward exactly \
             ZDOTDIR (bundle path), GHOSTTY_ZSH_ZDOTDIR (the original), \
             GHOSTTY_SHELL_FEATURES (ghostty's default), and GHOSTTY_RESOURCES_DIR"
        );
    }

    // ==================== R2 ====================
    // zsh + resources dir present + NO original ZDOTDIR.

    #[test]
    fn zsh_with_resources_dir_and_no_original_zdotdir_omits_the_restore_key() {
        let result = shell_integration_env("/bin/zsh", Some("/opt/ghostty-resources"), None);

        let expected: BTreeMap<String, String> = [
            (
                "ZDOTDIR".to_string(),
                "/opt/ghostty-resources/shell-integration/zsh".to_string(),
            ),
            (
                "GHOSTTY_SHELL_FEATURES".to_string(),
                "cursor:blink,path,title".to_string(),
            ),
            (
                "GHOSTTY_RESOURCES_DIR".to_string(),
                "/opt/ghostty-resources".to_string(),
            ),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            as_map(result),
            expected,
            "with no original ZDOTDIR, GHOSTTY_ZSH_ZDOTDIR must be ABSENT (not \
             present-and-empty) so the bundled .zshenv falls back to $HOME, \
             per its `[[ -n \"${{GHOSTTY_ZSH_ZDOTDIR+X}}\" ]]` existence check"
        );
    }

    // ==================== R3 ====================
    // resources dir absent -> no injection, no panic.

    #[test]
    fn missing_resources_dir_returns_empty_vec_without_panicking() {
        let result = shell_integration_env("/bin/zsh", None, Some("/Users/alice/.config/zsh"));
        assert_eq!(
            result,
            Vec::<(String, String)>::new(),
            "an absent ghostty_resources_dir must yield no injection at all, \
             regardless of shell_path or original_zdotdir"
        );
    }

    // ==================== R4 ====================
    // non-zsh shell + resources dir present -> empty vec this cycle
    // (documented zsh-only scope; bash/fish/elvish are a future
    // extension, see this module's doc comment).

    #[test]
    fn non_zsh_shell_with_resources_dir_returns_empty_vec_this_cycle() {
        let result = shell_integration_env(
            "/bin/bash",
            Some("/opt/ghostty-resources"),
            Some("/Users/alice/.config/zsh"),
        );
        assert_eq!(
            result,
            Vec::<(String, String)>::new(),
            "bash (and fish/elvish/nushell) are out of scope this cycle: \
             forwarding only GHOSTTY_RESOURCES_DIR without the rest of a \
             shell's own integration wired up risks a partial, broken \
             manual-integration attempt, so this cycle injects nothing for \
             any non-zsh shell rather than a half-measure"
        );
    }

    // ==================== is_zsh ====================
    // Exercises the shared shell-detection helper directly so its
    // contract is pinned independently of `shell_integration_env`.

    #[test]
    fn is_zsh_matches_only_the_zsh_basename() {
        assert!(is_zsh("/bin/zsh"));
        assert!(is_zsh("zsh"));
        assert!(!is_zsh("/bin/bash"));
        assert!(!is_zsh("/usr/local/bin/zsh-static"));
        assert!(!is_zsh(""));
    }

    // ==================== R5 ====================
    // Wiring seam: resolve_shell_integration_env delegates to
    // shell_integration_env using values read through an injected
    // env-lookup closure (a stand-in for `attach.rs`'s real
    // `std::env::var`), so it carries the zsh env end-to-end for a
    // zsh $SHELL. This is the seam-level substitute for asserting on
    // `attach.rs`'s actual `SessionSpec.env` field: attach.rs's create
    // path (crates/cli/src/commands/attach.rs) calls exactly this
    // function to build that field, and the closure-injection avoids
    // mutating real process env vars (which would race other tests
    // running in parallel in the same process).

    #[test]
    fn resolve_shell_integration_env_carries_the_zsh_env_for_a_zsh_shell() {
        let fake_env: BTreeMap<&str, &str> = [
            ("GHOSTTY_RESOURCES_DIR", "/opt/ghostty-resources"),
            ("SHELL", "/bin/zsh"),
            ("ZDOTDIR", "/Users/alice/.config/zsh"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        let expected: BTreeMap<String, String> = [
            (
                "ZDOTDIR".to_string(),
                "/opt/ghostty-resources/shell-integration/zsh".to_string(),
            ),
            (
                "GHOSTTY_ZSH_ZDOTDIR".to_string(),
                "/Users/alice/.config/zsh".to_string(),
            ),
            (
                "GHOSTTY_SHELL_FEATURES".to_string(),
                "cursor:blink,path,title".to_string(),
            ),
            (
                "GHOSTTY_RESOURCES_DIR".to_string(),
                "/opt/ghostty-resources".to_string(),
            ),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            as_map(result),
            expected,
            "resolve_shell_integration_env should read SHELL/GHOSTTY_RESOURCES_DIR/\
             ZDOTDIR through the injected closure and forward the same env \
             shell_integration_env would compute directly"
        );
    }

    // Confirms the "no GHOSTTY_RESOURCES_DIR -> do not error, inject
    // nothing" robustness requirement holds even for a zsh $SHELL, so
    // attach/new call sites running outside ghostty (every test and CI
    // environment) are unaffected by this seam.
    #[test]
    fn resolve_shell_integration_env_is_a_noop_without_a_resources_dir() {
        let fake_env: BTreeMap<&str, &str> = [("SHELL", "/bin/zsh")].into_iter().collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert_eq!(
            result,
            Vec::<(String, String)>::new(),
            "no GHOSTTY_RESOURCES_DIR in the client's env should inject nothing \
             and must not panic, even for a zsh $SHELL"
        );
    }
}
