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
    let mut env = shell_integration_env(
        &shell_path,
        resources_dir.as_deref(),
        original_zdotdir.as_deref(),
    );
    let zsh = is_zsh(&shell_path);

    // When ghostty's own integration doesn't apply at all (no resources
    // dir -- e.g. ghostty integration disabled, or attach running
    // outside a ghostty-launched surface entirely), `shell_integration_env`
    // above returned nothing at all, INCLUDING no ZDOTDIR -- so even if
    // the attach client's own env already has ZDOTDIR pointed at Calyx's
    // own installed zsh dir (CalyxShellIntegrationEnvironment.apply,
    // independent of ghostty), that value would never reach the
    // persistent-session daemon's spawned shell. Relay it verbatim
    // (unmodified -- NOT remapped to a ghostty bundle path, since there
    // is none) in that case, zsh shells only: matches the plan's own
    // "ghostty統合が無効な環境ではzshがCalyxの.zshenvを直接読み、同じコード
    // が単独で成立する" design -- Calyx's own chain must stand alone
    // without any ghostty involvement. Gated on `resources_dir.is_none()`
    // specifically so this never collides with the ZDOTDIR
    // `shell_integration_env` already pushed above when a resources dir
    // IS present (that's the ghostty-bundle-path ZDOTDIR, a different
    // value serving a different chain).
    if resources_dir.is_none() && zsh {
        if let Some(zdotdir) = &original_zdotdir {
            env.push(("ZDOTDIR".to_string(), zdotdir.clone()));
        }
    }

    // Calyx's own zsh command-log shell integration
    // (ShellIntegrationInstaller.swift / CalyxShellIntegrationEnvironment.swift)
    // installs an entirely separate .zshenv-based restore chain, independent
    // of ghostty's own GHOSTTY_ZSH_ZDOTDIR chain above -- so this forwards
    // verbatim, unconditionally on the ghostty-specific resources_dir
    // gating, whenever the attach client's own env has it (inherited from
    // Calyx.app's own process env, set by CalyxShellIntegrationEnvironment
    // .apply). Without this, a persistent-session daemon shell has nothing
    // to read CALYX_ZSH_ZDOTDIR from once execution reaches Calyx's own
    // .zshenv, and falls back to $HOME instead of the user's true original
    // ZDOTDIR. Gated on `is_zsh` (this module's existing convention, same
    // as `shell_integration_env`'s own gate) -- CALYX_ZSH_ZDOTDIR is a
    // zsh-specific concept, a stray env var in a bash/fish shell.
    if zsh {
        if let Some(calyx_zsh_zdotdir) = get_env("CALYX_ZSH_ZDOTDIR") {
            env.push(("CALYX_ZSH_ZDOTDIR".to_string(), calyx_zsh_zdotdir));
        }
    }

    // XDG_DATA_DIRS: fish's own vendor_conf.d discovery mechanism
    // (CalyxShellIntegrationEnvironment.apply also appends Calyx's own
    // root to it), entirely orthogonal to ghostty's zsh-specific ZDOTDIR
    // chain above -- forwarded verbatim, unconditionally on shell type
    // AND on resources_dir, whenever the client's own env has it. Without
    // this, a persistent-session daemon's fish shell never sees Calyx's
    // fish vendor_conf.d entry at all, even though an ordinary (non-
    // persistent, directly ghostty-launched) fish pane picks it up fine
    // via plain process-env inheritance -- this closes that gap for the
    // daemon-hosted case specifically.
    if let Some(xdg_data_dirs) = get_env("XDG_DATA_DIRS") {
        env.push(("XDG_DATA_DIRS".to_string(), xdg_data_dirs));
    }

    env
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

    // ==================== P4: CALYX_ZSH_ZDOTDIR forwarding ====================
    // Calyx's own zsh command-log shell integration installs its own
    // .zshenv-based restore chain (ShellIntegrationInstaller.swift /
    // CalyxShellIntegrationEnvironment.swift on the Swift side), entirely
    // distinct from ghostty's own GHOSTTY_ZSH_ZDOTDIR chain exercised
    // above. THE BUG: a persistent-session pane's attach client never
    // forwards CALYX_ZSH_ZDOTDIR into the daemon-hosted shell's own env,
    // so Calyx's own restore chain (see the P4 plan's zsh ZDOTDIR relay
    // design) has nothing to read from in that shell and can never
    // restore the user's real ZDOTDIR there. Gated on is_zsh (review
    // finding #8) -- this test's $SHELL is already zsh, so that gate
    // doesn't change this test's own expectation; the negative variant
    // right below it is what actually pins the gate.

    #[test]
    fn resolve_shell_integration_env_forwards_calyx_zsh_zdotdir_verbatim_when_present() {
        let fake_env: BTreeMap<&str, &str> = [
            ("GHOSTTY_RESOURCES_DIR", "/opt/ghostty-resources"),
            ("SHELL", "/bin/zsh"),
            ("ZDOTDIR", "/Users/alice/.config/zsh"),
            ("CALYX_ZSH_ZDOTDIR", "/Users/alice/.config/calyx-zsh"),
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
            (
                "CALYX_ZSH_ZDOTDIR".to_string(),
                "/Users/alice/.config/calyx-zsh".to_string(),
            ),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            as_map(result),
            expected,
            "CALYX_ZSH_ZDOTDIR must be forwarded verbatim alongside the existing ghostty zsh env, so \
             Calyx's own zsh integration restore chain has somewhere to read from in a persistent-session \
             daemon shell -- today it is dropped entirely"
        );
    }

    #[test]
    fn resolve_shell_integration_env_does_not_forward_calyx_zsh_zdotdir_for_non_zsh_shell() {
        let fake_env: BTreeMap<&str, &str> = [
            ("SHELL", "/usr/bin/fish"),
            ("CALYX_ZSH_ZDOTDIR", "/Users/alice/.config/calyx-zsh"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert!(
            as_map(result).get("CALYX_ZSH_ZDOTDIR").is_none(),
            "CALYX_ZSH_ZDOTDIR is a zsh-specific concept; a non-zsh $SHELL (fish here) must never \
             receive it as a stray env var"
        );
    }

    // ==================== P4 review: ZDOTDIR relay without ghostty ====================
    // THE BUG: with no GHOSTTY_RESOURCES_DIR at all (ghostty integration
    // disabled, or attach running outside ghostty), shell_integration_env
    // returns nothing -- including no ZDOTDIR -- so even though the
    // attach client's own env already has ZDOTDIR pointed at Calyx's own
    // installed zsh dir (CalyxShellIntegrationEnvironment.apply, which
    // runs independently of ghostty), that value never reached the
    // persistent-session daemon's spawned shell. Calyx's own chain is
    // supposed to stand alone without ghostty involvement (per the plan),
    // so this relays the client's own ZDOTDIR verbatim in that case.

    #[test]
    fn resolve_shell_integration_env_relays_client_zdotdir_verbatim_when_no_resources_dir_for_zsh() {
        let fake_env: BTreeMap<&str, &str> = [
            ("SHELL", "/bin/zsh"),
            ("ZDOTDIR", "/Users/alice/Library/Application Support/Calyx/shell-integration/zsh"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert_eq!(
            as_map(result).get("ZDOTDIR").map(String::as_str),
            Some("/Users/alice/Library/Application Support/Calyx/shell-integration/zsh"),
            "with no ghostty resources dir, Calyx's own chain must still stand alone: the client's \
             own ZDOTDIR (already pointed at Calyx's installed zsh dir) must relay verbatim into a \
             persistent-session daemon shell's env, unmodified -- there is no ghostty bundle path to \
             remap it to"
        );
    }

    #[test]
    fn resolve_shell_integration_env_does_not_relay_zdotdir_for_non_zsh_shell_without_resources_dir() {
        let fake_env: BTreeMap<&str, &str> = [
            ("SHELL", "/usr/bin/fish"),
            ("ZDOTDIR", "/Users/alice/Library/Application Support/Calyx/shell-integration/zsh"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert!(
            as_map(result).get("ZDOTDIR").is_none(),
            "the ZDOTDIR relay (no resources dir case) is zsh-specific -- ZDOTDIR means nothing to \
             fish, so a non-zsh $SHELL must not receive it"
        );
    }

    // ==================== P4 review: XDG_DATA_DIRS forwarding ====================
    // Fish's own vendor_conf.d discovery mechanism -- entirely orthogonal
    // to ghostty's zsh-specific ZDOTDIR chain, so forwarded unconditionally
    // on shell type AND on resources_dir, whenever present.

    #[test]
    fn resolve_shell_integration_env_forwards_xdg_data_dirs_verbatim_alongside_zsh_env() {
        let fake_env: BTreeMap<&str, &str> = [
            ("GHOSTTY_RESOURCES_DIR", "/opt/ghostty-resources"),
            ("SHELL", "/bin/zsh"),
            ("XDG_DATA_DIRS", "/opt/calyx/shell-integration:/usr/local/share:/usr/share"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert_eq!(
            as_map(result).get("XDG_DATA_DIRS").map(String::as_str),
            Some("/opt/calyx/shell-integration:/usr/local/share:/usr/share"),
            "XDG_DATA_DIRS must forward verbatim alongside the existing ghostty zsh env when present"
        );
    }

    #[test]
    fn resolve_shell_integration_env_forwards_xdg_data_dirs_for_fish_persistent_panes_without_resources_dir() {
        // THE BUG this specific case fixes: a persistent-session fish
        // pane has no GHOSTTY_RESOURCES_DIR at all (fish never went
        // through ghostty's zsh-specific setup to begin with), so before
        // this fix XDG_DATA_DIRS -- the ONLY mechanism fish uses to
        // discover Calyx's vendor_conf.d entry -- was never forwarded,
        // leaving a persistent-session daemon's fish shell with no
        // command-log integration at all, even though an ordinary
        // (non-persistent) ghostty-launched fish pane picks it up fine
        // via plain process-env inheritance.
        let fake_env: BTreeMap<&str, &str> = [
            ("SHELL", "/usr/bin/fish"),
            ("XDG_DATA_DIRS", "/opt/calyx/shell-integration:/usr/local/share:/usr/share"),
        ]
        .into_iter()
        .collect();

        let result = resolve_shell_integration_env(|key| fake_env.get(key).map(|v| v.to_string()));

        assert_eq!(
            as_map(result).get("XDG_DATA_DIRS").map(String::as_str),
            Some("/opt/calyx/shell-integration:/usr/local/share:/usr/share"),
            "XDG_DATA_DIRS must forward for a fish persistent-session pane even with no ghostty \
             resources dir at all -- fixes fish persistent panes never picking up Calyx's own \
             vendor_conf.d entry"
        );
    }
}
