// AgentEndpointFile.swift
// Calyx
//
// Writes/removes `agent-endpoint.json` (port + token) so the
// calyx-agent-hook script can always reach the current IPC server, even
// after a restart or token rotation.

import Foundation

enum AgentEndpointFile {

    private static let fileName = "agent-endpoint.json"

    /// Default directory: `~/Library/Application Support/Calyx`.
    static var defaultDirectory: String {
        AppSupportDirectory.path
    }

    /// Writes `agent-endpoint.json` (0600) to `directory` with the given
    /// `port` and `token`. Uses `ConfigFileUtils.atomicWrite` (temp file +
    /// rename) rather than a direct `Data.write` so a reader — the
    /// `calyx-agent-hook` script, invoked concurrently from every active
    /// pane's hooks — never observes a partially-written file.
    static func write(port: Int, token: String, directory: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let dict: [String: Any] = ["port": port, "token": token]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        try ConfigFileUtils.atomicWrite(data: data, to: filePath, lockPath: filePath + ".lock")
    }

    /// Removes `agent-endpoint.json` from `directory`, if present.
    static func remove(directory: String) {
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
