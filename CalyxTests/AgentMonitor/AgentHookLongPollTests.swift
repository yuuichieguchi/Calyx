//
//  AgentHookLongPollTests.swift
//  CalyxTests
//
//  Covers AgentHookLongPoll (spec C.3 G4, J12): the long-poll lines shared
//  by `calyx-approval-hook` and `calyx-ipc-wake-hook`. Three constants,
//  `setup` (signalled/curl_pid init and the TERM/HUP/INT trap),
//  `guardBeforeCurl` (the signalled check right before curl) and
//  `afterCurl` (curl_pid capture, re-check, wait, exit code, reset). Each
//  script interpolates each constant exactly once, in the order
//  setup < guardBeforeCurl < curl line < afterCurl.
//
//  "Executable lines" are lines trimmed of whitespace with blank lines and
//  `#` comment lines dropped.
//

import XCTest
@testable import Calyx

final class AgentHookLongPollTests: XCTestCase {

    // MARK: - Helpers

    private func executableLines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private var scripts: [(name: String, body: String)] {
        [("calyx-approval-hook", ApprovalHookScript.scriptBody), ("calyx-ipc-wake-hook", IPCWakeHookScript.scriptBody)]
    }

    private var constants: [(name: String, text: String)] {
        [
            ("setup", AgentHookLongPoll.setup),
            ("guardBeforeCurl", AgentHookLongPoll.guardBeforeCurl),
            ("afterCurl", AgentHookLongPoll.afterCurl),
        ]
    }

    // MARK: - Exact lines

    func test_setup_executableLinesAreExact() {
        XCTAssertEqual(executableLines(of: AgentHookLongPoll.setup), [
            "signalled=0",
            "curl_pid=",
            #"trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT"#,
        ])
    }

    func test_guardBeforeCurl_executableLinesAreExact() {
        XCTAssertEqual(executableLines(of: AgentHookLongPoll.guardBeforeCurl), [
            #"if [ "$signalled" = 1 ]; then"#,
            "exit 0",
            "fi",
        ])
    }

    func test_afterCurl_executableLinesAreExact() {
        XCTAssertEqual(executableLines(of: AgentHookLongPoll.afterCurl), [
            "curl_pid=$!",
            #"if [ "$signalled" = 1 ]; then"#,
            #"kill "$curl_pid" 2>/dev/null"#,
            "exit 0",
            "fi",
            #"wait "$curl_pid""#,
            "curl_exit=$?",
            "curl_pid=",
        ])
    }

    func test_constants_haveNoLeadingOrTrailingNewline_andStartAtColumnZero() {
        for constant in constants {
            XCTAssertFalse(constant.text.isEmpty, constant.name)
            XCTAssertFalse(constant.text.hasPrefix("\n"), "\(constant.name) has no leading newline")
            XCTAssertFalse(constant.text.hasSuffix("\n"), "\(constant.name) has no trailing newline")
            XCTAssertFalse(constant.text.first?.isWhitespace ?? true, "\(constant.name) starts at column 0")
        }
    }

    func test_setup_termTrapRemovesNoFile() {
        let traps = executableLines(of: AgentHookLongPoll.setup).filter { $0.hasPrefix("trap ") }
        XCTAssertEqual(traps.count, 1)
        XCTAssertFalse(traps.contains { $0.contains("rm -f") }, "the EXIT trap of each script removes its files")
    }

    func test_afterCurl_endsWithTheCurlPIDReset() {
        XCTAssertEqual(executableLines(of: AgentHookLongPoll.afterCurl).last, "curl_pid=")
        XCTAssertTrue(AgentHookLongPoll.afterCurl.hasSuffix("curl_pid="))
    }

    // MARK: - Both scripts

    func test_eachConstantAppearsVerbatimExactlyOnceInBothScripts() {
        for script in scripts {
            for constant in constants {
                XCTAssertEqual(occurrences(of: constant.text, in: script.body), 1,
                               "\(script.name) interpolates AgentHookLongPoll.\(constant.name) exactly once")
            }
        }
    }

    func test_order_setup_guard_curl_afterCurl_inBothScripts() throws {
        for script in scripts {
            let body = script.body
            let setup = try XCTUnwrap(body.range(of: AgentHookLongPoll.setup), script.name)
            let guardRange = try XCTUnwrap(body.range(of: AgentHookLongPoll.guardBeforeCurl), script.name)
            let curl = try XCTUnwrap(body.range(of: "\ncurl "), script.name)
            let after = try XCTUnwrap(body.range(of: AgentHookLongPoll.afterCurl), script.name)
            XCTAssertLessThanOrEqual(setup.upperBound, guardRange.lowerBound, "\(script.name): setup < guardBeforeCurl")
            XCTAssertLessThanOrEqual(guardRange.upperBound, curl.lowerBound, "\(script.name): guardBeforeCurl < curl")
            XCTAssertLessThan(curl.upperBound, after.lowerBound, "\(script.name): curl < afterCurl")
        }
    }

    func test_adjacency_curlFollowsGuard_andCurlPIDFollowsTheBackgroundedLine_inBothScripts() throws {
        for script in scripts {
            let lines = executableLines(of: script.body)
            let curl = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("curl ") }, script.name)
            XCTAssertGreaterThanOrEqual(curl, 3, script.name)
            XCTAssertEqual(Array(lines[(curl - 3)..<curl]), executableLines(of: AgentHookLongPoll.guardBeforeCurl),
                           "\(script.name): the line after guardBeforeCurl's fi is the curl line")
            let url = try XCTUnwrap(lines.firstIndex { $0.hasSuffix(#"> "$response_file" &"#) }, script.name)
            XCTAssertEqual(lines.dropFirst(url + 1).first, "curl_pid=$!",
                           "\(script.name): the line after the &-terminated line is curl_pid=$!")
        }
    }
}
