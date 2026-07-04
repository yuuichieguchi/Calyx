// SessionCommandSynthesizer.swift
// Calyx
//
// Builds the shell command string used as a ghostty surface's `command`
// config when persistent sessions are enabled. Ghostty runs any command
// with additional arguments through `/bin/sh -c` (see
// `ghostty/src/config/Config.zig`'s `command` doc comment), so every
// token below must be shell-safe on its own — `shSafeToken(_:)` is
// applied to each argument that can contain attacker/user-controlled
// text (the binary path, sessionID, cwd, and name).
//
// Pure function group — no I/O, no actor isolation required.

import Foundation

enum SessionCommandSynthesizer {

    /// Renders `token` as a single safe `/bin/sh -c` word by
    /// unconditionally wrapping it in POSIX single quotes, with each
    /// literal `'` byte replaced by the four bytes `'\''` (close quote,
    /// escaped literal quote, reopen quote). Inside single quotes
    /// nothing is special except `'` itself, so this is structurally
    /// safe for every possible byte — including a raw newline, a bare
    /// carriage return, or a CRLF pair, all of which can legitimately
    /// appear in a cwd derived from OSC 7 if the directory name itself
    /// contains one.
    ///
    /// This never falls back to the shared `ShellEscape.escape` (used
    /// elsewhere in the app for a different purpose — interactive
    /// drag-and-drop keystroke quoting — and deliberately left
    /// untouched).
    ///
    /// Two earlier versions of this function were built on `Character`
    /// (extended-grapheme-cluster) string APIs and were each bypassed in
    /// turn: a conditional `token.contains("\n") || token.contains("\r")`
    /// check missed a pure CRLF payload, because Swift's `Character`
    /// fuses an adjacent CR+LF pair into one grapheme cluster distinct
    /// from either `"\n"` or `"\r"` alone; and the unconditional
    /// successor's `token.replacingOccurrences(of: "'", with: "'\\''")`
    /// missed a `'` immediately followed by a Unicode combining
    /// character (e.g. U+0301 — naturally occurring on APFS, whose
    /// filenames can be NFD-normalized), because that pairing also fuses
    /// into one grapheme cluster distinct from a bare `'`. Both bugs
    /// share one root cause: `/bin/sh` parses raw bytes, not grapheme
    /// clusters, so any safety check expressed in terms of `Character`
    /// can be wrong about what the shell will actually see. This
    /// implementation instead walks `token.utf8` and compares each raw
    /// byte against the ASCII `'` byte value directly — no `Character`,
    /// no `String` substring/contains/replace API is involved at any
    /// point, so there is no grapheme-cluster boundary left for an
    /// adjacent combining mark (or any other combining sequence) to hide
    /// behind.
    private static func shSafeToken(_ token: String) -> String {
        var bytes: [UInt8] = [0x27] // opening '
        for byte in token.utf8 {
            if byte == 0x27 { // '
                bytes.append(contentsOf: [0x27, 0x5C, 0x27, 0x27]) // '\''
            } else {
                bytes.append(byte)
            }
        }
        bytes.append(0x27) // closing '
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Builds `exec <binaryPath> attach <sessionID> --create --cwd
    /// <cwd> [--name <name>]`. `sessionID` is positional, matching the
    /// P2 CLI's `AttachArgs` (`calyx-session/crates/cli/src/cli.rs`),
    /// which has no `--id` flag.
    ///
    /// The leading `exec` replaces the intermediate `/bin/sh` process
    /// with `calyx-session` itself (rather than leaving `sh` as a
    /// surviving parent), so the ghostty surface's child process *is*
    /// `calyx-session attach`, not a shell wrapping it — required for
    /// correct SIGWINCH/SIGTERM delivery and for
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` to reflect the attach
    /// process's own lifetime.
    ///
    /// `sessionID` must be shell-escaped via `shSafeToken(_:)` exactly
    /// like `binaryPath`/`cwd`/`name` — defense in depth against a
    /// corrupted or otherwise attacker-controlled persisted
    /// `SessionRef.sessionID` reaching this function on the restore
    /// path (see `SessionRef.isValidULID(_:)`, which restore should
    /// also reject on before ever reaching here; this escaping is the
    /// second, independent layer). A freshly-generated ULID never
    /// contains a shell-special character, so this has no effect on the
    /// normal spawn path — it only matters for a value that reached
    /// here without going through `ULID.generate()`.
    static func attachCommand(
        binaryPath: String,
        sessionID: String,
        cwd: String,
        name: String? = nil
    ) -> String {
        var command = "exec \(shSafeToken(binaryPath)) attach \(shSafeToken(sessionID)) --create --cwd \(shSafeToken(cwd))"
        if let name {
            command += " --name \(shSafeToken(name))"
        }
        return command
    }

    /// Builds the attach command for re-attaching to an *existing*
    /// `sessionID` (restore, reconnect) using `resolver` to find the
    /// calyx-session binary — as opposed to `SessionSpawnPlanner.plan`,
    /// which additionally decides whether to spawn a brand-new session
    /// at all. Returns `nil` when no binary is resolvable, so callers
    /// degrade to a plain passthrough surface instead of synthesizing a
    /// command around a hardcoded `"calyx-session"` literal that may
    /// not exist on `PATH`. Consolidates what used to be independent
    /// binary-path-then-command-synthesis copies in
    /// `AppDelegate.createSurfaceWithPwd` and
    /// `CalyxWindowController.performReconnect`.
    static func reattachCommand(
        sessionID: String,
        cwd: String,
        resolver: SessionBinaryResolverProtocol = SessionBinaryResolver()
    ) -> String? {
        guard let binaryPath = resolver.resolve() else { return nil }
        return attachCommand(binaryPath: binaryPath, sessionID: sessionID, cwd: cwd)
    }
}
