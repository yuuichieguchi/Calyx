// DaemonLedgerReader.swift
// CalyxUITests
//
// Shared daemon-ledger read/poll helper for the E2E suites added
// alongside SessionPersistenceE2ETests (E2E-1/E2E-2/E2E-3): reads the
// same on-disk file that suite already established as the only
// sandbox-safe verification channel available to a sandboxed XCUITest
// runner (see SessionPersistenceE2ETests.swift's header comment for the
// full rationale -- the runner is App-Sandboxed and cannot open a new
// unix-domain-socket connection to the daemon, so `calyx-session ls`
// spawned directly from here always returns empty stdout even while
// the daemon is alive).
//
// Deliberately NOT merged into SessionPersistenceE2ETests.swift itself
// (which keeps its own private copy of the same logic): that file is
// outside this task's assignment, and duplicating a read-only helper
// is a smaller, safer diff than refactoring a file another change
// might be touching concurrently.

import Foundation

/// Reads `$HOME/.calyx/state/sessions.json` (see
/// `calyx-session/crates/daemon/src/ledger.rs`) directly from disk and
/// polls it for an expected condition. One instance per test, pointed
/// at that test's own isolated `HOME` override.
struct DaemonLedgerReader {
    let homeDir: String

    /// Reads and parses the ledger. Returns an empty session array
    /// (never fails the caller directly) if the file doesn't exist yet
    /// or isn't a parseable JSON array of objects -- the daemon only
    /// writes it atomically after its first registry change, so a
    /// missing file just means nothing has registered yet. `raw` is
    /// the exact bytes this read parsed (or a placeholder describing
    /// why parsing failed), so a caller's failure message always
    /// describes the SAME read its assertion failed against.
    func read() -> (sessions: [[String: Any]], raw: String) {
        let ledgerURL = URL(fileURLWithPath: "\(homeDir)/.calyx/state/sessions.json")
        guard let data = try? Data(contentsOf: ledgerURL) else {
            return ([], "<no ledger file at \(ledgerURL.path)>")
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-UTF8 ledger, \(data.count) bytes>"
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let sessions = jsonObject as? [[String: Any]] else {
            return ([], raw)
        }
        return (sessions, raw)
    }

    /// True if `session`'s `"state"` field is the bare string
    /// `"Running"` (as opposed to `{"Exited": {"code": n}}`, which
    /// decodes as a dictionary, not a string; see `SessionState`'s
    /// serde derive in `calyx-session/crates/proto/src/control.rs`).
    func isRunning(_ session: [String: Any]) -> Bool {
        (session["state"] as? String) == "Running"
    }

    /// True if `session`'s `"state"` field is the `{"Exited": {...}}`
    /// dictionary shape.
    func isExited(_ session: [String: Any]) -> Bool {
        (session["state"] as? [String: Any])?["Exited"] != nil
    }

    /// `session["id"]`, or `nil` if missing/wrong type.
    func id(of session: [String: Any]) -> String? {
        session["id"] as? String
    }

    /// `session["attached_clients"]`, or `nil` if missing/wrong type.
    func attachedClients(of session: [String: Any]) -> Int? {
        session["attached_clients"] as? Int
    }

    /// `session["meta"]` (a `BTreeMap<String, String>` in
    /// `SessionInfo`, `calyx-session/crates/proto/src/control.rs`,
    /// serialized as a plain JSON object of string values), or an
    /// empty dictionary if missing/wrong type -- the daemon persists
    /// this same `SessionInfo` into the ledger on every registry
    /// change, so a `calyx-session meta set` reaches this file without
    /// needing a separate `meta get` round-trip to confirm it.
    func meta(of session: [String: Any]) -> [String: String] {
        (session["meta"] as? [String: String]) ?? [:]
    }

    /// Finds the one session in `sessions` (a prior `read()`/`poll`
    /// result) whose `"id"` equals `id`, or `nil` if absent.
    func session(withID id: String, in sessions: [[String: Any]]) -> [String: Any]? {
        sessions.first { ($0["id"] as? String) == id }
    }

    /// Polls `read()` (up to `timeoutAttempts` reads, sleeping
    /// `sleepInterval` between each), transforming every raw read via
    /// `transform`, until `isDone` accepts the transformed value.
    /// Checks BEFORE sleeping, so a caller whose expected state is
    /// already true on the first read returns immediately. Always
    /// returns the LAST transformed value and the raw ledger text it
    /// came from, whether or not `isDone` ever matched, so a caller
    /// that times out can still build a failure message describing
    /// the exact read that failed.
    func poll<T>(
        timeoutAttempts: Int,
        sleepInterval: TimeInterval,
        transform: ([[String: Any]]) -> T,
        until isDone: (T) -> Bool
    ) -> (value: T, raw: String) {
        var (sessions, raw) = read()
        var value = transform(sessions)
        var attempt = 1
        while !isDone(value) && attempt < timeoutAttempts {
            Thread.sleep(forTimeInterval: sleepInterval)
            (sessions, raw) = read()
            value = transform(sessions)
            attempt += 1
        }
        return (value, raw)
    }
}
