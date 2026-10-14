// IPCWakeHookScript.swift
// Calyx
//
// The `calyx-ipc-wake-hook` shell script, the third Calyx hook script
// next to `calyx-agent-hook` (AgentHookScript.swift) and
// `calyx-approval-hook` (ApprovalHookScript.swift). It long-polls
// `POST /ipc-wake` (`CalyxMCPServer.routeIPCWake`) for its pane and,
// only when the answer is signed by the running Calyx, turns the
// server's note into exit status 2 with that note on stderr. That exit
// status is the single exception to the hook scripts' fail-open "every
// path is exit 0" rule, and the condition it is tied to is the most
// important string invariant in this file. It is run by the hook entries
// `ClaudeHooksConfigManager` writes for Claude Code's `Stop` and
// `SessionStart` events, and the file itself is written by
// `AgentHooksCoordinator`'s Claude Code leg.

import Foundation

enum IPCWakeHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager`
    /// to recognize its own `command` entries by path, alongside
    /// `AgentHookScript.fileName` and `ApprovalHookScript.fileName`.
    static let fileName = "calyx-ipc-wake-hook"

    /// The script opens with `exec 3>&2 2>/dev/null`, then
    /// `AgentHookScriptPrologue.body`, the section shared by every Calyx
    /// hook script: the fail-open guards and the endpoint resolution live
    /// there, not in this literal. After it, the script reads the two
    /// HMAC blocks of the server's `IPCWakeProofKey` from the endpoint
    /// file, asks `POST /ipc-wake` once whether the peer bound to this
    /// pane has messages the pane was not told about, and waits for the
    /// answer. It is run by the wake entry `ClaudeHooksConfigManager`
    /// writes for `Stop` and `SessionStart`, with no arguments, so `kind`
    /// resolves to `claude-code`.
    ///
    /// Why the exit status matters: Claude Code runs a hook entry marked
    /// `asyncRewake` in the background, and exit status 2 from it wakes
    /// an idle session and shows the hook's stderr to the model. So when
    /// the server answers with a signed note, this script prints that
    /// note via `printf '%s'` to fd 3 (the hook's original stderr), with
    /// no newline added, and exits 2. Nothing is ever printed on stdout.
    /// A wake that arrives while a turn is in progress is not dropped:
    /// Claude Code folds it into that turn right after the running tool
    /// finishes, and creates no new turn. The model sees the note as
    /// `Stop hook blocking error from command "Stop": <note>`.
    ///
    /// That `exit 2` is the single exception to the fail-open rule (see
    /// `ApprovalHookScript.scriptBody`), it appears once, and it is
    /// taken on exactly one condition: curl exited 0, AND the body is
    /// exactly two lines, AND line 2 matches `IPCWakeResponse.notePattern`
    /// as a whole, AND the HMAC the script computes over the nonce and
    /// line 2 is 64 lowercase hex digits equal to line 1. Every other
    /// path is `exit 0` with nothing printed: a curl error, a non-2xx
    /// answer (turned into a curl error by `--fail`, so the body of a
    /// failed request is never read), a timeout, a body over
    /// `--max-filesize`, the server's empty 204, and any body that fails
    /// a check. `IPCWakeResponse.responseBody(proof:note:)` builds the
    /// body the server sends.
    ///
    /// Response authentication: the endpoint file (0600) holds the key's
    /// inner and outer blocks (`IPCWakeProofKey.innerBlockHex`,
    /// `outerBlockHex`), so the script computes
    /// `SHA256(outer || SHA256(inner || nonce "\n" note))`, which is
    /// `IPCWakeProofKey.proof(nonce:note:)`. The nonce is a fresh
    /// `uuidgen` per poll, uppercased because the server accepts only a
    /// canonical uppercase UUID, and sent as `IPCWakeResponse.nonceHeader`;
    /// it binds the proof to this poll. A process that answers on the
    /// endpoint's port without knowing the key therefore cannot make
    /// this script exit 2, whatever it returns. The blocks only ever
    /// travel from the shell builtin `printf` through pipes into `xxd`
    /// and `openssl`: never as a process argument, an environment
    /// variable or a file, and the script uses no here-document, no
    /// `export` and no `eval`. `openssl`, `xxd` and `uuidgen` are
    /// required: without them, or when the computed value is not 64 hex
    /// digits, the script never wakes the pane (fail-open). The 64-hex
    /// check is needed because a failing tool yields an empty or short
    /// value that would otherwise equal an empty or short line 1.
    ///
    /// Why exactly two lines: `grep -x` accepts multi-line input when
    /// any single line matches, so the line count is checked first
    /// (`sed -n '$='`; one trailing newline is still two lines). Every
    /// `grep` runs under `LC_ALL=C`, so the bracket ranges of the
    /// pattern are byte ranges in any locale. `--max-filesize` bounds the
    /// bandwidth and the temp file a bogus responder can use; correctness
    /// rests on the HMAC.
    ///
    /// Why `exec 3>&2 2>/dev/null`: from the first executable line on,
    /// the noise of every tool goes nowhere and the note written to fd 3
    /// is the only thing that can reach the hook's stderr, which Claude
    /// Code shows the model. Starting with fd 2 closed is outside the
    /// contract (Claude Code always passes a stderr pipe); `exec 3>&2`
    /// then fails, and no guard is added for it.
    ///
    /// `stop_hook_active` is not read, and stdin is discarded unread:
    /// the server hands out a wake only for messages the pane was not
    /// told about yet, and each message causes at most one wake (see
    /// `IPCWakeCoordinator`'s header comment), so a woken turn ending
    /// cannot re-trigger the same wake. Neither a new prompt nor Esc
    /// stops a running hook, so the poll of an earlier turn can run
    /// alongside the poll of a later one; the server ends the older one
    /// with 204 when the newer registers, and a wake the older one
    /// receives is folded into the current turn.
    ///
    /// `cat > /dev/null` returns once the CLI has closed the hook's
    /// stdin after writing the event to it. That the CLI does close it
    /// is the same assumption `calyx-agent-hook` and
    /// `calyx-approval-hook` make when they read stdin to its end.
    ///
    /// The request has no body and no `Content-Type`: the route takes
    /// the pane's identity from the headers alone. The
    /// `X-Calyx-Surface-ID` value is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}` for the reason given on
    /// `AgentHookScript`'s doc comment. curl's `-m` deadline is
    /// `IPCWakeHookTiming.curlTimeoutSeconds`, interpolated so the
    /// nesting invariant that type documents cannot drift from this
    /// script.
    ///
    /// curl runs BACKGROUNDED, with a `trap` on TERM/HUP/INT that kills
    /// it and exits 0, for the reason documented on
    /// `ApprovalHookScript.scriptBody`: a foregrounded curl would
    /// outlive a killed script and keep the long-poll open. The same
    /// `signalled` / `curl_pid` handshake is used here, from the same
    /// lines: `AgentHookLongPoll.setup`, `guardBeforeCurl` and
    /// `afterCurl`, and the block read and nonce come from
    /// `AgentHookProof`, all shared with the approval script. The trap only
    /// records `signalled=1` while `curl_pid` is empty, and the script
    /// checks `signalled` once before curl is started and again on the
    /// line right after `curl_pid=$!`. `curl_pid` is emptied again once
    /// `wait` has returned, so a late signal cannot `kill` a pid that is
    /// no longer curl's. From then on a TERM/HUP/INT only records
    /// `signalled=1` and the checks below still run, so a signed note
    /// curl already received is still delivered with exit 2 rather than
    /// dropped: the server committed that wake when it answered.
    /// `SIGKILL` cannot be trapped: in that case curl lives on until the
    /// server answers or curl's own `-m` deadline passes.
    ///
    /// The response goes through the script's only temp file, created by
    /// `mktemp` from the template `${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX`:
    /// `TMPDIR` is honoured when set (macOS's bare `mktemp` ignores it),
    /// `/tmp` is used otherwise, and the file name starts with
    /// `calyx-ipc-wake.`. A failing `mktemp` ends the script with
    /// `exit 0` before curl is started. The file is removed by the `EXIT`
    /// trap on every exit path, including the signal trap's `exit 0`;
    /// that trap's body is an `if`, so its own status can never replace
    /// the script's exit status.
    ///
    /// Grok guard: `kind` resolved to `claude-code` while
    /// `GROK_HOOK_EVENT` is set means Grok picked this entry up from
    /// `~/.claude/settings.json` (see `AgentHookScriptPrologue`). Without
    /// the guard this script would hold a long-poll as if the pane were
    /// Claude Code, and could answer a wake with exit status 2, a status
    /// only Claude Code's `asyncRewake` gives that meaning to.
    ///
    /// At-most-once boundary: a wake the server already handed over is
    /// not repeated if this script dies, or rejects the answer, before
    /// it exits 2 (see `IPCWakeCoordinator`'s header comment).
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-ipc-wake-hook -- long-polls Calyx's local IPC endpoint (POST
    # /ipc-wake) for this pane. When the server answers with a note that
    # carries a valid proof, the note is printed to the hook's stderr and
    # the script exits 2: Claude Code runs a hook entry marked
    # asyncRewake in the background, and exit status 2 from it wakes an
    # idle session (or joins the running turn after its current tool)
    # and shows the hook's stderr to the model. That is the only path
    # that is not exit 0. Run by the hook entries ClaudeHooksConfigManager
    # writes for Stop and SessionStart; the file is written by
    # AgentHooksCoordinator's Claude Code leg.
    #
    # The proof is HMAC-SHA256, under a key the running Calyx keeps in
    # memory, over this poll's nonce and the note. The endpoint file
    # (0600) holds the key's inner and outer blocks; they reach openssl
    # and xxd only through pipes from the builtin printf, never as an
    # argument, an environment variable or a file. Without openssl, xxd
    # or uuidgen the pane is simply never woken. See IPCWakeHookScript's
    # doc comment for the reason behind each check.
    #
    # stop_hook_active is not read: each message causes at most one
    # wake, so a woken turn cannot re-trigger the same wake.
    #
    # curl runs backgrounded with a TERM/HUP/INT trap that kills it and
    # exits 0, as in calyx-approval-hook. SIGKILL cannot be trapped; curl
    # then lives on until its own -m deadline.

    # fd 3 keeps the hook's stderr; fd 2 is discarded, so the note
    # written to fd 3 is the only thing that can reach stderr.
    exec 3>&2 2>/dev/null
    \(AgentHookScriptPrologue.body)
    # The key's two HMAC blocks (hex). Without both, do not even ask.
    \(AgentHookProof.readBlocks)
    # Emptied before the EXIT trap is set, so that it never reads a value
    # inherited from the environment.
    response_file=
    # Written as an `if` so the trap's own status can never replace the
    # script's exit status.
    trap 'if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT
    # Shared with calyx-approval-hook (AgentHookLongPoll.setup): the TERM
    # trap kills and exits only once curl_pid is known; an earlier signal
    # just records signalled=1 for the two checks below. The trap's exit
    # runs the EXIT trap, which removes the response file.
    \(AgentHookLongPoll.setup)
    # The event on stdin is not used.
    cat > /dev/null
    # A fresh nonce per poll, in the canonical uppercase form the server
    # accepts.
    \(AgentHookProof.nonce)
    response_file=$(mktemp "${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX") || exit 0
    \(AgentHookLongPoll.guardBeforeCurl)
    curl -s -m \(IPCWakeHookTiming.curlTimeoutSeconds) \\
        --max-filesize 1024 \\
        --fail \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "\(IPCWakeResponse.nonceHeader): $nonce" \\
        "http://127.0.0.1:$port/ipc-wake" > "$response_file" &
    \(AgentHookLongPoll.afterCurl)
    # The body of a failed request is never read.
    if [ "$curl_exit" != 0 ]; then
        exit 0
    fi
    # Exactly two lines: grep -x passes multi-line input when any one
    # line matches.
    if [ "$(sed -n '$=' "$response_file")" != 2 ]; then
        exit 0
    fi
    proof=$(sed -n '1p' "$response_file")
    note=$(sed -n '2p' "$response_file")
    # LC_ALL=C makes the bracket ranges byte ranges.
    if ! printf '%s\\n' "$note" | LC_ALL=C grep -Eqx '\(IPCWakeResponse.notePattern)'; then
        exit 0
    fi
    # HMAC-SHA256 = SHA256(outer || SHA256(inner || nonce "\\n" note)).
    computed=$(
        {
            printf '%s' "$proof_outer" | xxd -r -p
            {
                printf '%s' "$proof_inner" | xxd -r -p
                printf '%s\\n%s' "$nonce" "$note"
            } | openssl dgst -sha256 -binary
        } | openssl dgst -sha256 -binary | xxd -p -c 64
    )
    # A failing tool leaves an empty or short value that must not match
    # an empty or short proof line.
    if ! printf '%s\\n' "$computed" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then
        exit 0
    fi
    # The one path that is not exit 0.
    if [ "$computed" = "$proof" ]; then
        printf '%s' "$note" >&3
        exit 2
    fi
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
