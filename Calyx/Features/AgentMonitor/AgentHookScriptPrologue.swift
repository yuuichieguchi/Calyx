// AgentHookScriptPrologue.swift
// Calyx
//
// The opening section all three Calyx hook scripts start with:
// `calyx-agent-hook` (AgentHookScript.swift), `calyx-approval-hook`
// (ApprovalHookScript.swift) and `calyx-ipc-wake-hook`
// (IPCWakeHookScript.swift). Any future Calyx hook script must start
// with it too. It decides whether this hook invocation belongs to a
// Calyx pane at all, and if so resolves which local IPC endpoint to talk
// to. Written once here and interpolated into each script's body, so the
// guards cannot drift apart between scripts.
//
// Properties each script relies on:
// - Every path out of the prologue is `exit 0`: a hook that has
//   nothing to do must never break the user's hook chain.
// - Falling through it leaves three shell variables set: `kind` (the
//   agent kind, `$1` defaulting to `claude-code`), and `port` and
//   `token` (both non-empty, read from agent-endpoint.json), and only
//   when the Calyx process that wrote the file is alive and is the same
//   process (`pid`/`pidStart`). The positional parameters no longer
//   hold the script's arguments.
// - The text is two constants: `guards` (this file) and
//   `AgentEndpointFile.shellResolution` (the endpoint resolution and the
//   liveness check, spec Feature C, G1), joined by a blank line. The
//   liveness check runs `set -- $(ps ...)`, which clobbers the
//   positional parameters, so `kind` (from `$1`) must be -- and is --
//   read in `guards`, before `shellResolution` runs.
// - It runs no network call, sets no trap and creates no file, so a
//   script is free to do its own posting, signal handling and temp
//   files after it.

import Foundation

enum AgentHookScriptPrologue {

    /// The shared `/bin/sh` text: `guards`, a blank line, then
    /// `AgentEndpointFile.shellResolution`, with no leading or trailing
    /// newline. Three fail-open guards plus the kind default (`guards`),
    /// then the endpoint resolution and liveness check, in this order:
    ///
    /// 1. Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset: the pane
    ///    wasn't launched by Calyx at all.
    /// 2. `HERDR_PANE_ID` non-empty: the shell is herdr-managed and its
    ///    Calyx IDs are inherited, stale ones -- see `AgentHookScript`'s
    ///    doc comment for why only `HERDR_PANE_ID` is that signal.
    /// 3. `kind` resolved to `claude-code` while `GROK_HOOK_EVENT` is
    ///    set: a Claude Code hook entry that Grok picked up from
    ///    `~/.claude/settings.json`. What would go wrong without this
    ///    guard differs per script and is documented on each script's
    ///    own `scriptBody`.
    /// 4. agent-endpoint.json missing, or without a port or token: no
    ///    Calyx server to reach. The file is re-read on every
    ///    invocation (rather than baked in at install time) so a server
    ///    restart or token rotation never leaves a hook using a stale
    ///    port/token.
    /// 5. The writing Calyx is not alive, or is not the same process
    ///    (`AgentEndpointFile.shellResolution`).
    static let body: String = guards + "\n\n" + AgentEndpointFile.shellResolution

    /// Guards 1-3 and `kind="${1:-claude-code}"`. `kind` must be read
    /// here: `shellResolution`'s `set --` clobbers `$1`.
    static let guards: String = """
    if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then
        exit 0
    fi

    # A herdr server started from inside a Calyx pane can spawn shells
    # that inherit that pane's CALYX_SURFACE_ID/CALYX_SESSION_ID -- a
    # non-empty HERDR_PANE_ID means this shell is herdr-managed, so skip
    # posting under that stale, misattributed surface identity. Other
    # HERDR_-prefixed variables (e.g. HERDR_SOCKET_PATH) are NOT this
    # signal: a user may export HERDR_SOCKET_PATH in their own shell
    # profile from inside an ordinary Calyx pane herdr never touched, so
    # only HERDR_PANE_ID itself is checked here.
    if [ -n "$HERDR_PANE_ID" ]; then
        exit 0
    fi

    kind="${1:-claude-code}"

    # Grok scans ~/.claude/settings.json for hooks by default, so Calyx's
    # Claude Code entries -- which pass no kind argument and therefore
    # resolve to claude-code -- also fire inside a Grok session, where
    # a hook shaped for Claude Code must do nothing. GROK_HOOK_EVENT is a
    # reserved variable Grok's hook runner injects into every hook
    # process, so it is set for Calyx's own Grok entries too; those pass
    # an explicit kind and are unaffected. The user's own [compat.*]
    # settings are never touched.
    if [ "$kind" = "claude-code" ] && [ -n "$GROK_HOOK_EVENT" ]; then
        exit 0
    fi
    """
}
