// GrokCLIVersion.swift
// Calyx
//
// The installed Grok CLI's version, used to decide whether Grok's IPC
// config may use `bearer_token_file` (C-D17, V3-3: present in 1.0.52,
// absent in 1.0.34).

import Foundation
import os

struct GrokCLIVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// First Grok version known to read `bearer_token_file`.
    static let bearerTokenFileMinimum = GrokCLIVersion(major: 1, minor: 0, patch: 52)

    var supportsBearerTokenFile: Bool { self >= Self.bearerTokenFileMinimum }

    static func < (lhs: GrokCLIVersion, rhs: GrokCLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The first `<digits>.<digits>.<digits>` triple in `output`, or nil.
    static func parse(_ output: String) -> GrokCLIVersion? {
        guard let match = output.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        return GrokCLIVersion(major: major, minor: minor, patch: patch)
    }

    /// Directories searched for `grok`, in order. A GUI app launched by
    /// launchd inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
    /// so the directories Grok's installer and Homebrew use are added
    /// explicitly.
    private static func searchDirectories() -> [String] {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fromPath = environmentPath.split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        return fromPath + [home + "/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    private static let timeout: TimeInterval = 3

    /// Runs `grok --version` and parses its output. Only `--version` is
    /// ever run, because `grok` may auto-update itself on an ordinary
    /// launch. Returns nil when the binary cannot be located, cannot be
    /// launched, exits non-zero, does not finish within 3 s (it is then
    /// terminated), or prints no version triple; nil means the caller
    /// keeps the baked-in Authorization form, which works with every
    /// Grok version.
    static func detect() -> GrokCLIVersion? {
        let fm = FileManager.default
        guard let executable = searchDirectories()
            .map({ ($0 as NSString).appendingPathComponent("grok") })
            .first(where: { fm.isExecutableFile(atPath: $0) })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe concurrently so a chatty child cannot block on a
        // full pipe before it exits.
        let reader = OutputReader(handle: output.fileHandleForReading)
        reader.start()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        // A descendant that inherited the pipe could keep it open after
        // `grok` exits; bound the read by the same timeout.
        guard process.terminationStatus == 0,
              let data = reader.waitForData(timeout: timeout)
        else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}

/// Reads a pipe to EOF on a background thread.
private final class OutputReader: Sendable {
    private let handle: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private let box = DataBox()

    init(handle: FileHandle) { self.handle = handle }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            box.set(handle.readDataToEndOfFile())
            done.signal()
        }
    }

    func waitForData(timeout: TimeInterval) -> Data? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }
}

private final class DataBox: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: Data())
    func set(_ data: Data) { storage.withLock { $0 = data } }
    func get() -> Data { storage.withLock { $0 } }
}
