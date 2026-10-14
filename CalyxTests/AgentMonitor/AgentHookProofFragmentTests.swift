//
//  AgentHookProofFragmentTests.swift
//  CalyxTests
//
//  Covers AgentHookProof (spec C.3 G4): the proof-related lines shared by
//  `calyx-approval-hook` and `calyx-ipc-wake-hook`. `readBlocks` reads the
//  endpoint file's two HMAC blocks and exits 0 when either is missing;
//  `nonce` makes a fresh uppercase uuidgen nonce and exits 0 when it is
//  empty. Each script interpolates each constant exactly once, before
//  AgentHookLongPoll.guardBeforeCurl.
//

import XCTest
@testable import Calyx

final class AgentHookProofFragmentTests: XCTestCase {

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
        [("readBlocks", AgentHookProof.readBlocks), ("nonce", AgentHookProof.nonce)]
    }

    func test_readBlocks_executableLinesAreExact() {
        XCTAssertEqual(executableLines(of: AgentHookProof.readBlocks), [
            #"proof_inner=$(sed -n 's/.*"wakeProofInner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"proof_outer=$(sed -n 's/.*"wakeProofOuter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"if [ -z "$proof_inner" ] || [ -z "$proof_outer" ]; then"#,
            "exit 0",
            "fi",
        ])
    }

    func test_nonce_executableLinesAreExact() {
        XCTAssertEqual(executableLines(of: AgentHookProof.nonce), [
            "nonce=$(uuidgen) || exit 0",
            #"nonce=$(printf '%s' "$nonce" | tr 'abcdef' 'ABCDEF')"#,
            #"if [ -z "$nonce" ]; then"#,
            "exit 0",
            "fi",
        ])
    }

    func test_constants_haveNoLeadingOrTrailingNewline() {
        for constant in constants {
            XCTAssertFalse(constant.text.isEmpty, constant.name)
            XCTAssertFalse(constant.text.hasPrefix("\n"), constant.name)
            XCTAssertFalse(constant.text.hasSuffix("\n"), constant.name)
            XCTAssertFalse(constant.text.first?.isWhitespace ?? true, "\(constant.name) starts at column 0")
        }
    }

    func test_eachConstantAppearsExactlyOnceInBothScripts_beforeGuardBeforeCurl() throws {
        for script in scripts {
            let guardRange = try XCTUnwrap(script.body.range(of: AgentHookLongPoll.guardBeforeCurl), script.name)
            for constant in constants {
                XCTAssertEqual(occurrences(of: constant.text, in: script.body), 1,
                               "\(script.name) interpolates AgentHookProof.\(constant.name) exactly once")
                let range = try XCTUnwrap(script.body.range(of: constant.text), "\(script.name) \(constant.name)")
                XCTAssertLessThanOrEqual(range.upperBound, guardRange.lowerBound,
                                         "\(script.name): \(constant.name) comes before guardBeforeCurl")
            }
        }
    }
}
