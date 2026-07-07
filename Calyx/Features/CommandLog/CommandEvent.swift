// CommandEvent.swift
// Calyx
//
// Decoded form of a shell integration's command-lifecycle event, delivered
// over the /command-event control-socket path (JSON, snake_case, with
// base64-encoded free-text fields) -- mirrors AgentEvent's lenient
// JSONSerialization decode convention (see AgentEvent.decode(from:)).

import Foundation

struct CommandEvent: Sendable {
    enum Phase: String, Sendable, Equatable {
        case start, end
    }

    let phase: Phase
    let cmdID: String
    /// Decoded from the base64 JSON key `command_b64`. Mandatory for a
    /// `.start` event; absent for `.end`.
    let command: String?
    /// Decoded from the base64 JSON key `cwd_b64`.
    let cwd: String?
    /// JSON key `exit_code`.
    let exitCode: Int32?
    /// JSON key `ts`, epoch milliseconds.
    let ts: Date?

    /// Decodes a shell integration's stdin/socket JSON payload.
    /// `phase` and `cmd_id` are mandatory; a `.start` event additionally
    /// requires `command_b64` to decode as valid base64. Unknown fields
    /// are tolerated.
    static func decode(from data: Data) -> CommandEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phaseRaw = object["phase"] as? String,
              let phase = Phase(rawValue: phaseRaw),
              let cmdID = object["cmd_id"] as? String else {
            return nil
        }

        let command: String?
        if let commandB64 = object["command_b64"] as? String {
            guard let decoded = decodeBase64String(commandB64) else { return nil }
            command = decoded
        } else {
            // command_b64 is only mandatory on a .start event; an .end
            // event carries no command of its own.
            guard phase != .start else { return nil }
            command = nil
        }

        let cwd: String?
        if let cwdB64 = object["cwd_b64"] as? String {
            guard let decoded = decodeBase64String(cwdB64) else { return nil }
            cwd = decoded
        } else {
            cwd = nil
        }

        var exitCode: Int32?
        if let rawExitCode = object["exit_code"] as? Int {
            exitCode = Int32(exactly: rawExitCode)
        }

        // JSON numbers arrive as either Int or Double depending on how
        // JSONSerialization bridged the literal (same dual-cast as
        // LSPSession's request-id decode).
        var ts: Date?
        if let tsMillis = object["ts"] as? Int, Double(tsMillis) >= Self.minimumPlausibleTsMillis {
            ts = Date(timeIntervalSince1970: Double(tsMillis) / 1000)
        } else if let tsMillis = object["ts"] as? Double, tsMillis >= Self.minimumPlausibleTsMillis {
            ts = Date(timeIntervalSince1970: tsMillis / 1000)
        }

        return CommandEvent(phase: phase, cmdID: cmdID, command: command, cwd: cwd, exitCode: exitCode, ts: ts)
    }

    /// A `ts` below this (1e11 epoch-millisecond) threshold is
    /// implausible for a real "now" -- most plausibly an accidental
    /// epoch-SECONDS value (~1.7e9 for a current date) rather than
    /// milliseconds, which would otherwise decode into a bogus
    /// early-1970s `Date`. Treated as if `ts` were absent, so ingest
    /// falls back to `CommandLogStore.now()`.
    private static let minimumPlausibleTsMillis: Double = 100_000_000_000

    private static func decodeBase64String(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
