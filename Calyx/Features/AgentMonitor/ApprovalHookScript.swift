// ApprovalHookScript.swift
// Calyx
//
// The `calyx-approval-hook` shell script installed under
// `~/Library/Application Support/Calyx/bin/`, alongside
// `calyx-agent-hook` (see AgentHookScript.swift). Unlike
// calyx-agent-hook's fire-and-forget async POST to /agent-event, this
// script is invoked *synchronously* by a PermissionRequest hook entry --
// fired only once the CLI has already decided it needs to show a
// confirmation prompt -- and its stdout becomes Claude Code's / Codex's
// actual permission decision. Its fail-safe behavior (never printing
// "allow", always exiting 0, and staying completely silent on any
// failure so the CLI's own confirmation prompt takes over) is the
// single most safety-critical string invariant in this file.

import Foundation

enum ApprovalHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` /
    /// `CodexHooksConfigManager` to recognize its own `command` entries
    /// by path, alongside `AgentHookScript.fileName`.
    static let fileName = "calyx-approval-hook"

    /// Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset means this
    /// pane wasn't launched by Calyx at all (e.g. a plain Terminal.app
    /// tab running `claude`) -- exit immediately, exactly like
    /// `AgentHookScript`'s identical guard, so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token.
    ///
    /// Second fail-open guard, herdr environment contamination: exits
    /// immediately whenever `HERDR_PANE_ID` is set to a non-empty value
    /// (`[ -n "$HERDR_PANE_ID" ]`), exactly like `AgentHookScript`'s
    /// identical guard -- see its doc comment for the fuller rationale,
    /// including why `HERDR_PANE_ID` specifically (not any
    /// `HERDR_`-prefixed variable name, and not a text-based
    /// environment scan) is the only reliable herdr-managed-pane
    /// signal, which applies identically here.
    ///
    /// Known residual path (tracked, not closable by this guard): see
    /// `AgentHookScript`'s identical doc comment -- Claude Code's own
    /// MCP client config substitutes a stale `CALYX_SURFACE_ID` inside
    /// the agent binary itself, a code path this hook script never runs
    /// in and cannot intercept.
    ///
    /// `$1` defaults `kind` to `claude-code` for the same reason as
    /// `AgentHookScript`: Claude Code's own hook `command` entries
    /// (installed by `ClaudeHooksConfigManager`) invoke this script with
    /// no arguments, while `CodexHooksConfigManager` installs Codex's
    /// entries as `"<scriptPath>" codex` to pass `codex` explicitly.
    ///
    /// The `X-Calyx-Surface-ID` header value is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}`: a persistent-session
    /// pane's calyx-session ID survives ghostty surface re-creation
    /// (reconnect) while `CALYX_SURFACE_ID` does not, so `CALYX_SESSION_ID`
    /// is preferred whenever set, falling back to the ordinary
    /// `CALYX_SURFACE_ID` otherwise -- see `AgentHookScript`'s doc
    /// comment for the fuller rationale, which applies identically here.
    ///
    /// curl's `-m` deadline is `ApprovalHookTiming.curlTimeoutSeconds`
    /// (585s), derived by string interpolation rather than a separately
    /// hardcoded literal, so the nesting invariant `ApprovalHookTiming`
    /// documents -- Calyx's own server answers by 570s, strictly before
    /// curl gives up at 585s, strictly before the CLI's own hook-entry
    /// timeout kills the whole hook process at 600s -- can't silently
    /// drift out of sync with this script. `--fail` makes curl treat any
    /// non-2xx server response as a curl error too, so it's routed
    /// through the same silent no-output path as any other curl
    /// failure, rather than printed to the CLI as if it were a real
    /// permission decision.
    ///
    /// curl runs BACKGROUNDED, with a `trap` on TERM/HUP/INT that kills
    /// it and exits 0 -- not foregrounded and left to inherit signals on
    /// its own. Empirically confirmed (see the task that added this):
    /// when Claude Code decides it no longer needs this hook (the user
    /// answered the SAME permission prompt directly in the CLI while
    /// this script was still blocked in its long-poll) and kills the
    /// hook process, that's `SIGTERM` delivered to this script's own
    /// `/bin/sh` process, not to its process group -- a foregrounded
    /// `curl` in `response=$(curl ...)` is a child of a subshell the
    /// signal never reaches, so it survives as an orphan (reparented to
    /// PID 1) and keeps its long-poll connection to Calyx open until
    /// curl's OWN `-m` deadline, up to 585s later. Calyx's own
    /// connection-drop detection (`CalyxMCPServer.dispatchRoute`'s
    /// sentinel receive, `routeApprovalRequest`'s own doc comment point
    /// (c)) only ever notices a closed socket -- an orphaned curl still
    /// holding it open is invisible to it. So: `curl` writes to a temp
    /// file in the background (`&`), stdin is drained into a SEPARATE
    /// temp file first and curl reads `--data-binary @"$payload_file"`
    /// rather than `@-` (a backgrounded command's stdin is NOT the
    /// script's own by default under POSIX sh job-control rules --
    /// empirically confirmed: `--data-binary @-` on a backgrounded curl
    /// silently posts an EMPTY body), the trap kills curl's pid and
    /// exits 0 on TERM/HUP/INT, and `wait` blocks for curl's own exit
    /// (interruptible by the same trap) before the response file is
    /// read. The trap always sets `signalled=1` but only kills and exits
    /// once `curl_pid` is non-empty (both are initialized empty/0 first,
    /// so an inherited environment value can't leak in): a signal landing
    /// after `curl ... &` but before `curl_pid=$!` would otherwise run
    /// `kill ""` (a no-op), exit, and orphan curl. Instead the script
    /// carries on to the assignment, and an `if [ "$signalled" = 1 ]`
    /// re-check immediately after it kills the now-known curl, removes
    /// both temp files, and exits 0. A `SIGKILL` to this script bypasses
    /// the trap entirely (no process can catch it) and still orphans curl
    /// exactly as before --
    /// that residual path is why `CalyxMCPServer.routeAgentEvent`'s
    /// Stop-hook-settles-to-idle fallback stays in place as a last
    /// resort, not removed by this fix.
    ///
    /// The curl exit code is then switched on:
    /// - `0` (success): the server's response body is printed verbatim
    ///   via `printf '%s'` -- never `echo`, which can mangle a body
    ///   starting with `-` or containing backslash escape sequences.
    /// - `7` (connection refused): silent, no output at all. After
    ///   Calyx crashes, `agent-endpoint.json` is left behind pointing at
    ///   a now-dead port, so every subsequent permission prompt would
    ///   otherwise land in this branch -- producing no output leaves the
    ///   hook inert, so the CLI's own confirmation prompt takes over
    ///   exactly as it would with no Calyx hook installed at all, rather
    ///   than a stale endpoint file silently degrading every tool call's
    ///   UX.
    /// - anything else (timeout, DNS failure, a non-2xx response
    ///   rejected by `--fail`, etc.): also silent, no output at all.
    ///   PermissionRequest, unlike the older PreToolUse contract, has no
    ///   interactive-fallback body to fabricate here -- `"ask"` is not a
    ///   valid `decision.behavior` under this hook. Producing no output
    ///   IS the correct fail-safe: the CLI's own confirmation prompt
    ///   takes over exactly as it would with no Calyx hook installed at
    ///   all. This script must never print `"allow"` anywhere, on any
    ///   path.
    ///
    /// Every exit path is `exit 0`: whatever curl did or didn't return,
    /// this script itself must never exit nonzero and break the user's
    /// hook chain. The `trap ... TERM HUP INT` branch's `exit 0` is no
    /// exception -- it fires when THIS script is being killed, so its
    /// own exit status is moot to whatever killed it, but it's still
    /// written as `exit 0` for the same "never nonzero" discipline as
    /// every other path here.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-approval-hook -- synchronously forwards a PermissionRequest
    # hook's stdin JSON to Calyx's local Agent Monitor IPC endpoint and
    # prints its response verbatim; the response body IS the CLI's
    # permission decision. No output at all (any curl failure, or Calyx
    # unreachable) is the correct fail-safe: it lets the CLI's own
    # confirmation prompt take over. Installed and removed by
    # ClaudeHooksConfigManager / CodexHooksConfigManager.
    #
    # curl runs backgrounded with a TERM/HUP/INT trap that kills it and
    # exits 0: if this script is killed (e.g. because the user answered
    # this same permission prompt directly in the CLI instead of waiting
    # on Calyx), a FOREGROUNDED curl would survive as an orphan and keep
    # its long-poll connection open for up to its own -m deadline. A
    # signal arriving before curl_pid is assigned only sets signalled=1;
    # the re-check right after curl_pid=$! then kills curl and exits. Only
    # SIGKILL bypasses this (no process can trap it) -- see
    # ApprovalHookScript's own doc comment for the full empirical
    # writeup and the residual-path fallback that covers it.

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
    # this script's stdout would become Grok's decision in a vocabulary
    # (Claude Code's nested hookSpecificOutput.decision) Grok does not
    # recognize. GROK_HOOK_EVENT is a reserved variable Grok's hook
    # runner injects into every hook process, so it is set for Calyx's
    # own Grok entries too; those pass an explicit kind and are
    # unaffected. The user's own [compat.*] settings are never touched.
    if [ "$kind" = "claude-code" ] && [ -n "$GROK_HOOK_EVENT" ]; then
        exit 0
    fi

    # CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController alongside
    # CALYX_SURFACE_ID, scoped to wherever this Calyx process actually
    # wrote agent-endpoint.json (a --calyx-path-root scratch directory
    # under test, the real Application Support directory otherwise). The
    # literal fallback covers a pane launched before that injection
    # existed, or a shell that stripped the variable.
    endpoint_file="${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    payload_file=$(mktemp) || exit 0
    response_file=$(mktemp) || { rm -f "$payload_file"; exit 0; }
    # The trap only kills and exits once curl_pid is known; a signal
    # arriving earlier -- including between curl's `&` and the
    # `curl_pid=$!` assignment, when kill would have no pid to target --
    # just records signalled=1, and the re-check right after that
    # assignment kills the now-known curl and exits instead.
    signalled=0
    curl_pid=
    trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; rm -f "$payload_file" "$response_file"; exit 0; fi' TERM HUP INT

    cat > "$payload_file"

    curl -s -m \(ApprovalHookTiming.curlTimeoutSeconds) \\
        --fail \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        --data-binary @"$payload_file" \\
        "http://127.0.0.1:$port/approval-request" > "$response_file" &
    curl_pid=$!
    if [ "$signalled" = 1 ]; then
        kill "$curl_pid" 2>/dev/null
        rm -f "$payload_file" "$response_file"
        exit 0
    fi
    wait "$curl_pid"
    curl_exit=$?

    response=$(cat "$response_file")
    rm -f "$payload_file" "$response_file"

    case "$curl_exit" in
        0) printf '%s' "$response" ;;
        7) exit 0 ;;
        *) ;;
    esac

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path. Shares its actual write-then-chmod logic with
    /// `AgentHookScript.install(toDirectory:)` via
    /// `AgentHookScript.installScript(body:fileName:toDirectory:)`.
    static func install(toDirectory directory: String) throws -> String {
        try AgentHookScript.installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }
}
