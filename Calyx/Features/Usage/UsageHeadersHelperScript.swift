// UsageHeadersHelperScript.swift
// Calyx
//
// `calyx-usage-headers`: the headers helper Claude Code's OTEL exporter
// runs (`otelHeadersHelper` in Claude Code's settings file) to obtain the
// usage route's Authorization header (spec Feature C, G5: J16-J19 / C-D19).
// The sibling of `MCPHeadersHelperScript` for the usage route.

import Foundation

enum UsageHeadersHelperScript {

    static let fileName = "calyx-usage-headers"

    /// Prints the bytes of `usage-otel-credential.json` (next to
    /// agent-endpoint.json) when agent-endpoint.json passes
    /// `AgentEndpointFile.shellResolution` (readable, port/token, writer
    /// alive) and names the port given as the first argument, otherwise
    /// `{}`; always exits 0 with empty stderr.
    static let scriptBody: String = """
    #!/bin/sh
    # calyx-usage-headers: run by Claude Code's OTEL exporter
    # (`otelHeadersHelper` in Claude Code's settings file) to obtain the
    # Authorization header for Calyx's usage route.
    #
    # Why liveness and the port are checked: a Claude Code session started
    # before a token rotation keeps the old endpoint URL. The previous
    # helper (a plain `cat` of the headers file) handed the usage token to
    # whatever process held that old port, both while Calyx was down and
    # after Calyx moved to another port. This helper prints the token only
    # while the Calyx that wrote agent-endpoint.json is alive and still
    # serves the port the settings file was written for.
    #
    # Every failure path prints `{}`: the exporter then sends without
    # Authorization, the route answers 401, and nothing leaks.
    # shellResolution ends every failure with a bare `exit 0` and no
    # stdout; the EXIT trap turns each of those into `{}`.
    #
    # The token travels only file -> cat -> stdout: it never enters any
    # child process's argv or environment (cat receives the file's path).
    #
    # Edge cases: (a) if stdout is closed, cat fails, but `emitted=1`
    # still runs (no `set -e`), so nothing else is printed and the script
    # exits 0. (b) A signal arriving between cat and `emitted=1` makes the
    # EXIT trap append `{}`; the output `{"Authorization":...}{}` is
    # invalid JSON, so no Authorization is sent and the route answers
    # 401: the window fails closed. (c) A read error part-way through
    # the file makes cat print truncated output and fail; `emitted=1`
    # still runs (no `set -e`), so the trap adds nothing, and the
    # truncated JSON makes Claude Code send no Authorization: fails closed.
    #
    # The credential file is usage-otel-credential.json, a name only this
    # helper reads: sessions started under an older build still run the
    # legacy helper (a plain `cat` of usage-otel-headers.json), and Calyx
    # removes that file so they print `{}` and never see a renewed token.
    #
    # Port binding: the settings file passes the port it was written for
    # as the first argument. It is captured before shellResolution, whose
    # `set --` replaces the positional parameters. A missing or empty
    # argument fails closed. This assumes Claude Code reads
    # otelHeadersHelper and the endpoint env together at session start
    # (unverified; the same assumption as calyx-mcp-headers).
    exec 2>/dev/null
    emitted=0
    trap 'if [ "$emitted" != 1 ]; then printf "{}"; fi' EXIT
    expected_port="$1"
    if [ -z "$expected_port" ]; then
        exit 0
    fi
    \(AgentEndpointFile.shellResolution)
    if [ "$port" != "$expected_port" ]; then
        exit 0
    fi
    usage_file="${endpoint_file%/*}/\(UsageIngestCredentialStore.fileName)"
    if [ ! -r "$usage_file" ]; then
        exit 0
    fi
    cat "$usage_file"
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
