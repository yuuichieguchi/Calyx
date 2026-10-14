//
//  TestHostLiveness.swift
//  CalyxTests
//
//  The test host's own liveness identifier (spec Feature C, J1), derived
//  independently of production code: `/bin/ps -p <getpid()> -o lstart=`
//  run with `TZ=UTC LC_ALL=C`, whitespace runs collapsed to one space and
//  the ends trimmed -- exactly what every reader (the hook prologue,
//  zsh/fish, OpenCode/pi) compares against. Every test fixture that
//  writes agent-endpoint.json writes these values (C-D16): without them
//  the prologue's liveness check exits before curl and every positive
//  script test would go silent. `EndpointLivenessTests` pins
//  `EndpointLiveness.current()` to these same values, so the fixtures
//  and production agree by test, not by assumption.
//
//  `writeTestEndpointFile` is the single funnel every existing test uses
//  to call `AgentEndpointFile.write`, so the required `liveness:`
//  argument is supplied in exactly one place.
//

import Foundation
@testable import Calyx

enum TestHostLiveness {

    /// The test host's pid.
    static let pid: Int32 = getpid()

    /// The test host's normalised `ps -o lstart=` text in UTC / C locale.
    static let startText: String = startText(ofPid: getpid()) ?? ""

    /// `TZ=UTC LC_ALL=C /bin/ps -p <pid> -o lstart=`, normalised, or nil
    /// when ps prints nothing (no such process) or fails.
    static func startText(ofPid pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.environment = ["TZ": "UTC", "LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = normalizeIndependently(String(decoding: data, as: UTF8.self))
        return text.isEmpty ? nil : text
    }

    /// Splits on any whitespace and joins with one space: the J1
    /// normalisation, written here without reference to production code.
    static func normalizeIndependently(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }
}

/// Writes agent-endpoint.json through `AgentEndpointFile.write` with the
/// test host's own liveness identifier (C-D16).
func writeTestEndpointFile(port: Int, token: String, wakeProofKey: IPCWakeProofKey, directory: String) throws {
    try AgentEndpointFile.write(
        port: port, token: token, wakeProofKey: wakeProofKey,
        liveness: EndpointLiveness(pid: TestHostLiveness.pid, startText: TestHostLiveness.startText),
        directory: directory
    )
}
