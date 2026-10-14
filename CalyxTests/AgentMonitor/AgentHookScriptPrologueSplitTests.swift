//
//  AgentHookScriptPrologueSplitTests.swift
//  CalyxTests
//
//  Spec Feature C, C.3 G1: AgentHookScriptPrologue.body is split into
//  `guards` (environment, HERDR, kind, Grok) and
//  `AgentEndpointFile.shellResolution` (endpoint file, port, token,
//  liveness check), with `body = guards + "\n\n" + shellResolution`.
//  Slice 4 reuses `shellResolution` inside `calyx-mcp-headers`, which
//  prints `{}` on every failure path, so `shellResolution` must never
//  write to stdout itself and must end only through `exit 0`.
//
//  Coverage:
//  - body is exactly guards + blank line + shellResolution
//  - guards resolves `kind` from `$1`; shellResolution never reads `$1`
//    (it clobbers the positional parameters with `set --`)
//  - shellResolution: no stdout write (printf/echo), no curl/trap/mktemp,
//    every exit is `exit 0`
//  - guards holds no endpoint resolution, shellResolution no guards
//

import XCTest
@testable import Calyx

final class AgentHookScriptPrologueSplitTests: XCTestCase {

    private func executableLines(of script: String) -> [String] {
        script
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func test_body_isGuardsThenABlankLineThenShellResolution() {
        XCTAssertFalse(AgentHookScriptPrologue.guards.isEmpty)
        XCTAssertFalse(AgentEndpointFile.shellResolution.isEmpty)
        XCTAssertEqual(
            AgentHookScriptPrologue.body,
            AgentHookScriptPrologue.guards + "\n\n" + AgentEndpointFile.shellResolution
        )
    }

    func test_guards_executableLinesAreTheFourGuardsOnly() {
        XCTAssertEqual(executableLines(of: AgentHookScriptPrologue.guards), [
            #"if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then"#,
            "exit 0",
            "fi",
            #"if [ -n "$HERDR_PANE_ID" ]; then"#,
            "exit 0",
            "fi",
            #"kind="${1:-claude-code}""#,
            #"if [ "$kind" = "claude-code" ] && [ -n "$GROK_HOOK_EVENT" ]; then"#,
            "exit 0",
            "fi",
        ])
    }

    func test_shellResolution_executableLinesAreEndpointResolutionThenTheLivenessCheck() {
        XCTAssertEqual(executableLines(of: AgentEndpointFile.shellResolution), [
            "endpoint_file=\"${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}\"",
            #"if [ ! -f "$endpoint_file" ]; then"#,
            "exit 0",
            "fi",
            #"port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$endpoint_file")"#,
            #"token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"if [ -z "$port" ] || [ -z "$token" ]; then"#,
            "exit 0",
            "fi",
            #"pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$endpoint_file")"#,
            #"pid_start=$(sed -n 's/.*"pidStart"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"if [ -z "$pid" ] || [ -z "$pid_start" ]; then"#,
            "exit 0",
            "fi",
            #"if ! kill -0 "$pid" 2>/dev/null; then"#,
            "exit 0",
            "fi",
            #"set -- $(TZ=UTC LC_ALL=C ps -p "$pid" -o lstart=)"#,
            #"if [ "$*" != "$pid_start" ]; then"#,
            "exit 0",
            "fi",
        ])
    }

    func test_kindIsResolvedInGuardsBeforeShellResolutionClobbersThePositionalParameters() {
        XCTAssertTrue(AgentHookScriptPrologue.guards.contains(#"kind="${1:-claude-code}""#))
        let resolution = executableLines(of: AgentEndpointFile.shellResolution)
        XCTAssertTrue(resolution.contains { $0.hasPrefix("set -- ") }, "precondition: shellResolution uses set --")
        XCTAssertEqual(resolution.filter { $0.contains("$1") || $0.contains("${1") }, [String](),
                       "shellResolution must not read $1: its own `set --` clobbers it")
    }

    func test_shellResolution_writesNothingToStdout_andEndsOnlyThroughExit0() {
        let lines = executableLines(of: AgentEndpointFile.shellResolution)
        XCTAssertFalse(lines.isEmpty)
        for forbidden in ["printf", "echo", "curl", "trap", "mktemp", ">&1"] {
            XCTAssertEqual(lines.filter { $0.contains(forbidden) }, [String](),
                           "shellResolution must not use \(forbidden): calyx-mcp-headers prints {} on failure " +
                           "and only its own caller writes stdout")
        }
        let exits = lines.filter { $0 == "exit" || $0.hasPrefix("exit ") || $0.contains(" exit ") }
        XCTAssertFalse(exits.isEmpty)
        XCTAssertEqual(exits.filter { $0 != "exit 0" }, [String](), "every failure path must be exactly `exit 0`")
        XCTAssertEqual(lines.filter { $0.hasPrefix("return") }, [String]())
    }
}
