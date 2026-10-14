// AgentHookLongPoll.swift
// Calyx
//
// Shell fragments shared by the two Calyx hook scripts that long-poll
// the local IPC endpoint: `calyx-approval-hook` (ApprovalHookScript.swift)
// and `calyx-ipc-wake-hook` (IPCWakeHookScript.swift). Both run curl in
// the background under a TERM/HUP/INT trap so that a signal to the
// script also ends curl instead of orphaning it. The two scripts used to
// carry their own copies of these lines and had drifted apart (only one
// checked for a signal before starting curl, and only one reset
// `curl_pid` after `wait`), so the lines now live here once and each
// script interpolates them at column 0.
//
// Contract of `AgentHookLongPoll`:
// - `setup` runs after the script has emptied its temp-file variables
//   and set its own EXIT trap, and before any file is created. It
//   initialises `signalled` and `curl_pid` (so no trap reads an
//   inherited environment value) and sets the TERM/HUP/INT trap. That
//   trap removes no file: its `exit 0` runs the script's EXIT trap,
//   which removes the script's temp files.
// - `guardBeforeCurl` sits on the lines right before `curl`, so a signal
//   received earlier (for example while stdin is drained) never starts
//   curl.
// - `afterCurl` sits right after the `&`-terminated curl line. It leaves
//   `curl_exit` set and `curl_pid` empty again.
//
// Contract of `AgentHookProof`:
// - `readBlocks` needs `endpoint_file` (set by AgentHookScriptPrologue)
//   and leaves `proof_inner` and `proof_outer` non-empty, or exits 0.
// - `nonce` leaves `nonce` set to a fresh uppercase uuidgen value, or
//   exits 0.
//
// Every constant has no leading or trailing newline and contains no
// comment line; the explanations live here and in each script's doc
// comment.

import Foundation

enum AgentHookLongPoll {

    /// `signalled=0`, `curl_pid=` and the TERM/HUP/INT trap. The trap
    /// always records `signalled=1`, but kills curl and exits 0 only once
    /// `curl_pid` is known; an earlier signal is acted on by
    /// `guardBeforeCurl` or by the re-check in `afterCurl`.
    static let setup: String = #"""
    signalled=0
    curl_pid=
    trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT
    """#

    /// Exits 0 when a signal arrived before curl was started.
    static let guardBeforeCurl: String = #"""
    if [ "$signalled" = 1 ]; then
        exit 0
    fi
    """#

    /// Captures curl's pid, kills curl and exits 0 when a signal landed
    /// between the `&` and the capture, then waits for curl, keeps its
    /// exit status in `curl_exit` and empties `curl_pid` so a later
    /// signal does not target a finished pid.
    static let afterCurl: String = #"""
    curl_pid=$!
    if [ "$signalled" = 1 ]; then
        kill "$curl_pid" 2>/dev/null
        exit 0
    fi
    wait "$curl_pid"
    curl_exit=$?
    curl_pid=
    """#
}

enum AgentHookProof {

    /// Reads the two HMAC key blocks (hex) from the endpoint file into
    /// `proof_inner` and `proof_outer`; exits 0 when either is missing.
    static let readBlocks: String = #"""
    proof_inner=$(sed -n 's/.*"wakeProofInner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")
    proof_outer=$(sed -n 's/.*"wakeProofOuter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")
    if [ -z "$proof_inner" ] || [ -z "$proof_outer" ]; then
        exit 0
    fi
    """#

    /// A fresh nonce per request in `nonce`, in the canonical uppercase
    /// form the server accepts; exits 0 when uuidgen fails or yields
    /// nothing.
    static let nonce: String = #"""
    nonce=$(uuidgen) || exit 0
    nonce=$(printf '%s' "$nonce" | tr 'abcdef' 'ABCDEF')
    if [ -z "$nonce" ]; then
        exit 0
    fi
    """#
}
