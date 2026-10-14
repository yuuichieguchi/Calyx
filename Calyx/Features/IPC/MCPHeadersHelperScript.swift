// MCPHeadersHelperScript.swift
// Calyx
//
// `calyx-mcp-headers`: the headers helper Claude Code (`headersHelper`)
// and Codex (`http_headers_helper`) run to obtain the IPC bearer header,
// so a renewed token reaches them without a config rewrite or a restart
// (spec Feature C, J6 / C-D3 / C-D17).

import Foundation

enum MCPHeadersHelperScript {

    static let fileName = "calyx-mcp-headers"

    /// Prints `{"Authorization":"Bearer <token>"}` when agent-endpoint.json
    /// passes `AgentEndpointFile.shellResolution` (readable, port/token,
    /// writer alive), otherwise `{}`; always exits 0 with empty stderr.
    static let scriptBody: String = """
    #!/bin/sh
    # calyx-mcp-headers: run by Claude Code (`headersHelper` in
    # ~/.claude.json) and Codex (`http_headers_helper` in
    # ~/.codex/config.toml) to obtain the Calyx IPC Authorization header.
    #
    # Every failure path prints `{}`: Claude Code then sends the request
    # without Authorization (V3-2), the server answers 401, and the user
    # sees an auth error rather than a broken config. shellResolution ends
    # every failure with a bare `exit 0` and no stdout; the EXIT trap turns
    # each of those into `{}`.
    #
    # No surface guard: Claude Code outside Calyx (e.g. Terminal.app)
    # also uses calyx-ipc, so the header is printed whenever the endpoint
    # file's writer is alive.
    #
    # The token is 64 lowercase hex characters, so the JSON needs no
    # escaping. It is printed with the builtin printf, so it never enters
    # any child process's argv or environment.
    #
    # Edge cases: (a) if stdout is closed, the token printf fails, but
    # `emitted=1` still runs (no `set -e`), so nothing else is printed and
    # the script exits 0. (b) A signal arriving between the token printf
    # and `emitted=1` makes the EXIT trap append `{}`; the output
    # `{"Authorization":...}{}` is invalid JSON, so (V3-2) Claude Code
    # sends no Authorization and the server answers 401: the window fails
    # closed.
    exec 2>/dev/null
    emitted=0
    trap 'if [ "$emitted" != 1 ]; then printf "{}"; fi' EXIT
    \(AgentEndpointFile.shellResolution)
    printf '{"Authorization":"Bearer %s"}' "$token"
    emitted=1
    exit 0

    """

    /// Installs the script (0755) into `directory`, returning its path.
    static func install(toDirectory directory: String) throws -> String {
        try AgentHookScript.installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }

    /// Removes the script from `directory`. Best-effort: an absent file
    /// or directory is the expected state after a previous removal.
    static func remove(fromDirectory directory: String) {
        let path = (directory as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: path)
    }
}
