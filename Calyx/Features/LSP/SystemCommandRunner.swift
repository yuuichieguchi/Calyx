//
//  SystemCommandRunner.swift
//  Calyx
//
//  Production-side `LSPCommandRunner` that drives `Process` to invoke
//  real binaries. Used by `CalyxMCPServer.startLSP()` to install /
//  locate language servers on the host machine. Tests inject
//  `MockCommandRunner` instead.
//

import Foundation

/// `LSPCommandRunner` backed by `/usr/bin/which` and `/usr/bin/env`.
/// Stateless and Sendable.
struct SystemCommandRunner: LSPCommandRunner {

    init() {}

    // MARK: - LSPCommandRunner

    func locate(_ executable: String) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        let process = Process()

        // Absolute path → spawn directly. Bare name → defer to
        // `/usr/bin/env` so PATH lookup still resolves the binary.
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environment {
            process.environment = environment
        } else {
            process.environment = ProcessInfo.processInfo.environment
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
