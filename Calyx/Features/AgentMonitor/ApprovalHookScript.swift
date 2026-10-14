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

    /// The script opens with `AgentHookScriptPrologue.body`, the section
    /// shared by every Calyx hook script: the guards and the endpoint
    /// resolution described below live there, not in this literal.
    ///
    /// Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset means this
    /// pane wasn't launched by Calyx at all (e.g. a plain Terminal.app
    /// tab running `claude`) -- exit immediately, through the shared
    /// prologue's first guard, so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token.
    ///
    /// Second fail-open guard, herdr environment contamination: exits
    /// immediately whenever `HERDR_PANE_ID` is set to a non-empty value
    /// (`[ -n "$HERDR_PANE_ID" ]`). This is the shared prologue's
    /// guard, the same one `AgentHookScript` runs -- see
    /// `AgentHookScript`'s doc comment for the fuller rationale,
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
    /// Third fail-open guard, Grok: `kind` resolved to `claude-code`
    /// while `GROK_HOOK_EVENT` is set means Grok picked this entry up
    /// from `~/.claude/settings.json` (see `AgentHookScriptPrologue`).
    /// Without the guard this script's stdout would become Grok's
    /// decision in a vocabulary (Claude Code's nested
    /// `hookSpecificOutput.decision`) Grok does not recognize.
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
    /// read. These long-poll lines are shared with `calyx-ipc-wake-hook`
    /// and live in `AgentHookLongPoll` (`setup`, `guardBeforeCurl`,
    /// `afterCurl`); the endpoint file's HMAC block read and the nonce
    /// come from `AgentHookProof` (`readBlocks`, `nonce`). The trap always
    /// sets `signalled=1` but only kills and exits once `curl_pid` is
    /// non-empty (both are initialized empty/0 first, so an inherited
    /// environment value can't leak in): a signal landing after
    /// `curl ... &` but before `curl_pid=$!` would otherwise run `kill ""`
    /// (a no-op), exit, and orphan curl. Instead the script carries on to
    /// the assignment, and an `if [ "$signalled" = 1 ]` re-check
    /// immediately after it kills the now-known curl and exits 0. A
    /// signal that lands before curl is started at all (for example
    /// while stdin is still being drained) is caught by the same check on
    /// the lines right before `curl`, so curl never starts. Once `wait`
    /// returns, `curl_pid=` empties the pid again, so a late signal
    /// cannot `kill` a pid that is no longer curl's.
    ///
    /// Temp files: `payload_file` and `response_file` are emptied first,
    /// then one EXIT trap removes whichever of them exists, on every exit
    /// path. The TERM/HUP/INT trap removes no file itself: its `exit 0`
    /// runs the EXIT trap. The trap is written as `if ...; then rm -f`
    /// rather than `[ ... ] && rm -f` so its own status can never replace
    /// the script's exit status. Both traps are set before either file
    /// is created, and each file comes from a templated
    /// `mktemp "${TMPDIR:-/tmp}/calyx-approval-<payload|response>.XXXXXX"`
    /// (honouring `TMPDIR`), each failing safe with `|| exit 0`: the EXIT
    /// trap removes whatever was already created. No path removes the
    /// files explicitly.
    ///
    /// The first executable line is `exec 2>/dev/null`: this script's
    /// stderr is never meaningful to the CLI, so tool noise and the
    /// shell's own "command not found" messages (for example a missing
    /// `uuidgen`) are discarded rather than shown to the user.
    ///
    /// A `SIGKILL` to this script bypasses the trap entirely (no process
    /// can catch it) and still orphans curl exactly as before --
    /// that residual path is why `CalyxMCPServer.routeAgentEvent`'s
    /// Stop-hook-settles-to-idle fallback stays in place as a last
    /// resort, not removed by this fix.
    ///
    /// Nonce and verification: `AgentHookProof.nonce` makes a fresh
    /// uppercase UUID, sent as `ApprovalHookResponse.nonceHeader`. A
    /// nonce-carrying request is answered `<64 hex proof> LF <decision>`
    /// (`ApprovalHookResponse.signedBody`), where the proof is
    /// HMAC-SHA256 over `approval\n<nonce>\n<decision>` under this
    /// Calyx start's key. After curl exits the script checks, in order:
    /// curl's exit code is 0; the first 64 bytes are 64 lowercase hex
    /// digits; byte 65 is LF; the HMAC computed through `openssl` from
    /// the endpoint file's inner and outer blocks (passed only through
    /// builtin `printf` pipes, never as arguments) equals the proof. Only
    /// then is the decision written to stdout byte for byte with
    /// `tail -c +66`; the body never enters a shell variable, so no byte
    /// is lost or reinterpreted. Positions are bytes, not lines, because
    /// a signed empty decision is exactly 65 bytes.
    ///
    /// Any failed check, and every curl failure (7 connection refused,
    /// for example a dead port left in the endpoint file after a crash;
    /// 22 a non-2xx answer rejected by `--fail`; 28 timeout; 63 a body
    /// over `--max-filesize`), produces no output at all, for every CLI
    /// kind. PermissionRequest has no interactive-fallback body to
    /// fabricate (`"ask"` is not a valid `decision.behavior` there), and
    /// Calyx never invents a decision: silence lets the CLI's own
    /// confirmation prompt take over exactly as with no Calyx hook
    /// installed. This script must never print `"allow"` from its own
    /// text, on any path.
    ///
    /// `--max-filesize` is `ApprovalHookResponse.maxSignedResponseBytes`,
    /// 65 + 4 * 262144: an `.answered` decision echoes the whole
    /// `tool_input` back, so the decision may be up to four times the
    /// request cap. It bounds the temp file a bogus responder can fill;
    /// correctness rests on the HMAC.
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
    # hook's stdin JSON, with a fresh nonce, to Calyx's local Agent
    # Monitor IPC endpoint. Calyx answers "<64 hex proof> LF <decision>";
    # the decision is printed byte for byte (tail -c +66) only when the
    # proof is HMAC-SHA256 over "approval\\n<nonce>\\n<decision>" under the
    # key blocks in agent-endpoint.json, and it IS the CLI's permission
    # decision. No output at all (any curl failure, Calyx unreachable, a
    # proof line that is not 64 hex digits, no LF at byte 65, an HMAC
    # mismatch, missing HMAC key blocks or tools, or uuidgen failing) is
    # the correct fail-safe for every CLI kind: it lets the CLI's own
    # confirmation prompt take over; Calyx never invents a decision.
    # Installed and removed by ClaudeHooksConfigManager /
    # CodexHooksConfigManager.
    #
    # curl runs backgrounded with a TERM/HUP/INT trap that kills it and
    # exits 0: if this script is killed (e.g. because the user answered
    # this same permission prompt directly in the CLI instead of waiting
    # on Calyx), a FOREGROUNDED curl would survive as an orphan and keep
    # its long-poll connection open for up to its own -m deadline. A
    # signal arriving before curl_pid is assigned only sets signalled=1;
    # the checks right before curl and right after curl_pid=$! then exit
    # (killing curl if it runs). One EXIT trap removes both temp files on
    # every path. Only SIGKILL bypasses this (no process can trap it) --
    # see ApprovalHookScript's own doc comment for the full empirical
    # writeup and the residual-path fallback that covers it.

    # stderr is discarded so tool noise never reaches the CLI.
    exec 2>/dev/null

    \(AgentHookScriptPrologue.body)

    payload_file=
    response_file=
    # One EXIT trap removes both temp files on every path, including the
    # TERM trap's exit 0.
    trap 'if [ -n "$payload_file" ]; then rm -f "$payload_file"; fi; if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT
    \(AgentHookLongPoll.setup)
    payload_file=$(mktemp "${TMPDIR:-/tmp}/calyx-approval-payload.XXXXXX") || exit 0
    response_file=$(mktemp "${TMPDIR:-/tmp}/calyx-approval-response.XXXXXX") || exit 0

    cat > "$payload_file"

    \(AgentHookProof.readBlocks)
    \(AgentHookProof.nonce)
    \(AgentHookLongPoll.guardBeforeCurl)
    curl -s -m \(ApprovalHookTiming.curlTimeoutSeconds) \\
        --max-filesize \(ApprovalHookResponse.maxSignedResponseBytes) \\
        --fail \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        -H "\(ApprovalHookResponse.nonceHeader): $nonce" \\
        --data-binary @"$payload_file" \\
        "http://127.0.0.1:$port/approval-request" > "$response_file" &
    \(AgentHookLongPoll.afterCurl)
    if [ "$curl_exit" != 0 ]; then
        exit 0
    fi
    proof=$(head -c 64 "$response_file")
    if ! printf '%s\\n' "$proof" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then
        exit 0
    fi
    if [ "$(head -c 65 "$response_file" | tail -c 1 | xxd -p)" != "0a" ]; then
        exit 0
    fi
    computed=$(
        {
            printf '%s' "$proof_outer" | xxd -r -p
            {
                printf '%s' "$proof_inner" | xxd -r -p
                printf 'approval\\n%s\\n' "$nonce"
                tail -c +66 "$response_file"
            } | openssl dgst -sha256 -binary
        } | openssl dgst -sha256 -binary | xxd -p -c 64
    )
    if ! printf '%s\\n' "$computed" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then
        exit 0
    fi
    if [ "$computed" != "$proof" ]; then
        exit 0
    fi
    tail -c +66 "$response_file"
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
