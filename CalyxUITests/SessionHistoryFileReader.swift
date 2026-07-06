// SessionHistoryFileReader.swift
// CalyxUITests
//
// Reads a session's on-disk history file directly
// (`$HOME/.calyx/state/history/<id>.raw`, see
// `calyx-session/crates/daemon/src/history.rs`'s `active_path`),
// exactly the same sandbox-safe file-read approach
// `DaemonLedgerReader` already uses for the ledger (see that file's
// header for why: the XCUITest runner is App-Sandboxed and cannot open
// a new unix-domain-socket connection to the daemon, so this is the
// only channel available to read a live session's PTY output from
// inside the test runner without touching the accessibility tree --
// which cannot see Ghostty's GPU-rendered pane content at all, see
// `SessionPersistenceE2ETests.swift`'s header comment).
//
// Used by `AgentResumeOfferE2ETests` as the observable side effect of
// `AppDelegate.offerAgentResume`: that method injects text into a
// reattached pane via `GhosttySurfaceController.sendText`, which has
// no dialog, notification, or other UI-level surface at all -- the
// injected bytes just get echoed back out through the session's PTY
// like any other input, and (with history persistence on) land in
// this same file.

import Foundation

struct SessionHistoryFileReader {
    let homeDir: String

    /// `$HOME/.calyx/state/history/<id>.raw`. Rotation to `<id>.raw.1`
    /// (`history.rs`'s `rotated_path`) is out of scope here: a short
    /// test run never approaches the 10 MB rotation cap
    /// (`history::DEFAULT_CAP_BYTES`).
    private func activePath(id: String) -> String {
        "\(homeDir)/.calyx/state/history/\(id).raw"
    }

    /// The active history file's current contents as a UTF-8 string
    /// (history bytes are raw PTY output, which is a superset of valid
    /// UTF-8 for an ordinary shell session; `.isoLatin1` is tried as a
    /// fallback purely so a caller gets SOME diagnosable text back
    /// instead of `nil` if a control sequence ever breaks UTF-8
    /// decoding), or `nil` if the file doesn't exist yet.
    func contents(id: String) -> String? {
        guard let data = FileManager.default.contents(atPath: activePath(id: id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Polls `contents(id:)` (up to `timeoutAttempts` reads, sleeping
    /// `sleepInterval` between each) until `isDone` accepts it. Checks
    /// BEFORE sleeping. Always returns the last-read value (`nil` if
    /// the file never appeared), so a caller that times out can still
    /// report exactly what (if anything) was there.
    func poll(
        timeoutAttempts: Int,
        sleepInterval: TimeInterval,
        id: String,
        until isDone: (String?) -> Bool
    ) -> String? {
        var value = contents(id: id)
        var attempt = 1
        while !isDone(value) && attempt < timeoutAttempts {
            Thread.sleep(forTimeInterval: sleepInterval)
            value = contents(id: id)
            attempt += 1
        }
        return value
    }
}
