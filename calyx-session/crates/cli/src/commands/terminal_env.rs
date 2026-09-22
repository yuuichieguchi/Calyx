//! Computes the terminal/locale environment that `attach` re-supplies
//! into a new session's `SessionSpec.env` on every attach, to cover
//! the launchd job environment's own gap: launchd supplies only `HOME
//! LOGNAME OSLogRateLimit PATH PWD SHELL SHLVL SSH_AUTH_SOCK TMPDIR
//! USER XPC_FLAGS XPC_SERVICE_NAME` to a job it starts (measured
//! directly against a real LaunchAgent job), never `TERM`/`TERMINFO`/
//! `LANG`/`COLORTERM`/`TERM_PROGRAM`/`MANPATH`/`GHOSTTY_*`/
//! `XDG_DATA_DIRS`. A session shell inherits the daemon's own
//! environment (`session.rs`'s `cmd.env(...)` only overlays
//! `spec.env`), so without this, every shell a launchd-owned daemon
//! spawns loses `TERM` outright.
//!
//! The tests below pin `resolve_terminal_env`'s contract: reading each
//! of `TERM TERMINFO TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM LANG
//! LC_ALL LC_CTYPE PATH MANPATH CALYX_ENDPOINT_FILE` through the
//! injected `lookup` closure and forwarding only the keys present,
//! unchanged.
//!
//! `CALYX_ENDPOINT_FILE` is included for the same reason as `PATH`,
//! not the same reason as the terminal/locale keys: it does not come
//! from the launchd job environment at all. Calyx writes it into every
//! ghostty surface's own environment (including the surface whose
//! command is `calyx-session attach`), scoped to wherever that Calyx
//! process actually wrote `agent-endpoint.json` (the real Application
//! Support directory in production, or a `--calyx-path-root` scratch
//! directory under test). The daemon cannot regenerate that path
//! itself the way it manufactures `CALYX_SESSION_ID`, so the attach
//! client's own copy -- inherited from the surface exactly like this
//! function's other keys -- is the only copy that can ever reach the
//! spawned shell.
//!
//! `SHELL` and `HOME` are deliberately excluded: launchd already
//! supplies both correctly from the user record, and `session.rs`
//! reads the daemon's own `$SHELL` to pick a session's default argv
//! when `spec.argv` is `None`. Putting a client-observed `$SHELL` into
//! `spec.env` could make that default argv diverge from the value
//! `$SHELL` itself reports inside the spawned shell. On macOS this
//! exclusion would be moot for both keys anyway: `login(1)` overwrites
//! `HOME` and `SHELL` from the target user's passwd entry inside every
//! default session that starts through `login(1)`, so a forwarded
//! copy of either could never reach the shell in that case.
//!
//! `PATH` is included on purpose (behavior preservation, not new
//! scope): the attach client's `PATH` is already what a
//! directly-spawned daemon's session shells see today (inherited via
//! the daemon process's own env); under the launchd job environment
//! it would otherwise collapse to `/usr/bin:/bin:/usr/sbin:/sbin`.
//!
//! `lookup` is injected (rather than `resolve_terminal_env` reading
//! `std::env::var` itself) so these tests exercise it as a pure
//! function without mutating real process-wide environment variables,
//! which would race any other test running in parallel in the same
//! `cargo test` process. This is the same seam `shell_integration.rs`'s
//! `resolve_shell_integration_env` already uses for the identical
//! reason.

/// The target keys, in the exact order forwarded when present. See the
/// module doc for why `SHELL`/`HOME` are deliberately excluded.
const TARGET_KEYS: &[&str] = &[
    "TERM",
    "TERMINFO",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "COLORTERM",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "PATH",
    "MANPATH",
    "CALYX_ENDPOINT_FILE",
];

/// Computes the terminal/locale environment `attach` re-supplies into
/// `SessionSpec.env` on every attach. See the module doc for the full
/// contract.
pub(crate) fn resolve_terminal_env(
    lookup: impl Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    TARGET_KEYS
        .iter()
        .filter_map(|key| lookup(key).map(|value| (key.to_string(), value)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn as_map(pairs: Vec<(String, String)>) -> BTreeMap<String, String> {
        pairs.into_iter().collect()
    }

    /// Every target key present in the lookup must pass through
    /// unchanged; this is also the exhaustive list of keys the
    /// function may ever forward per its contract above (asserted via
    /// `assert_eq!` against the full expected map, not a subset check,
    /// so an over-broad implementation that forwards an unlisted key
    /// fails here too).
    #[test]
    fn resolve_terminal_env_passes_through_every_present_target_key_unchanged() {
        let fake_env: BTreeMap<&str, &str> = [
            ("TERM", "xterm-ghostty"),
            ("TERMINFO", "/opt/ghostty/share/terminfo"),
            ("TERM_PROGRAM", "ghostty"),
            ("TERM_PROGRAM_VERSION", "1.2.3"),
            ("COLORTERM", "truecolor"),
            ("LANG", "en_US.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
            ("LC_CTYPE", "en_US.UTF-8"),
            ("PATH", "/usr/local/bin:/usr/bin:/bin"),
            ("MANPATH", "/usr/local/share/man:/usr/share/man"),
            (
                "CALYX_ENDPOINT_FILE",
                "/Users/alice/Library/Application Support/Calyx/agent-endpoint.json",
            ),
        ]
        .into_iter()
        .collect();

        let result = resolve_terminal_env(|key| fake_env.get(key).map(|v| v.to_string()));

        let expected: BTreeMap<String, String> = fake_env
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        assert_eq!(
            as_map(result),
            expected,
            "every one of the eleven target keys should pass through unchanged when present"
        );
    }

    /// A key absent from `lookup` must not appear in the output at
    /// all (not present-with-an-empty-value).
    #[test]
    fn resolve_terminal_env_omits_keys_absent_from_the_lookup() {
        let result = resolve_terminal_env(|key| {
            if key == "TERM" {
                Some("xterm-ghostty".to_string())
            } else {
                None
            }
        });

        let map = as_map(result);
        assert_eq!(
            map.len(),
            1,
            "only the one present key should appear, got {map:?}"
        );
        assert_eq!(map.get("TERM").map(String::as_str), Some("xterm-ghostty"));
    }

    /// `SHELL` and `HOME` must never be forwarded, even when present
    /// in the lookup: launchd already supplies both correctly, and
    /// `session.rs` reads the daemon's own `$SHELL` for a session's
    /// default argv, so relaying a client-observed copy through
    /// `spec.env` risks that value diverging from `$SHELL` as the
    /// spawned shell itself reports it.
    #[test]
    fn resolve_terminal_env_never_forwards_shell_or_home() {
        let fake_env: BTreeMap<&str, &str> = [
            ("SHELL", "/bin/zsh"),
            ("HOME", "/Users/alice"),
            ("TERM", "xterm-ghostty"),
        ]
        .into_iter()
        .collect();

        let result = resolve_terminal_env(|key| fake_env.get(key).map(|v| v.to_string()));
        let map = as_map(result);

        assert!(
            !map.contains_key("SHELL"),
            "SHELL must never be forwarded, got {map:?}"
        );
        assert!(
            !map.contains_key("HOME"),
            "HOME must never be forwarded, got {map:?}"
        );
        assert_eq!(map.get("TERM").map(String::as_str), Some("xterm-ghostty"));
    }

    /// An empty lookup (nothing present at all) must yield an empty
    /// vec without panicking, matching `resolve_shell_integration_env`'s
    /// own no-op-when-nothing-present robustness requirement.
    #[test]
    fn resolve_terminal_env_is_empty_when_nothing_is_present() {
        let result = resolve_terminal_env(|_key| None);
        assert_eq!(result, Vec::<(String, String)>::new());
    }
}
