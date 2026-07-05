// SessionSpawnPlanner.swift
// Calyx
//
// Decides, per new terminal surface, whether to launch the user's
// ordinary shell (`.passthrough`, today's behavior) or a
// `calyx-session attach --create` command that survives ghostty
// surface teardown (`.persistent`). Gated off by default via
// `SessionSettings.persistentSessionsEnabled`.

import Foundation

/// Where a surface is being spawned. QuickTerminal panes are excluded
/// from persistent sessions by default: they're meant to be ephemeral
/// scratch panes, and reconnect/restore semantics for a
/// summon-on-demand window are out of scope for the initial rollout.
/// `.quickTerminal` itself is currently unreachable — no call site
/// constructs a `SessionSpawnContext` with it yet, since
/// `QuickTerminalController` never routes through `SessionSpawnPlanner`
/// at all — but the case (and `plan(for:)`'s guard against it) is kept
/// as a deliberate tripwire for whenever QuickTerminal *does* get
/// wired through this planner, so that integration starts excluded by
/// default rather than silently persistent.
enum SessionSpawnOrigin: Sendable, Equatable {
    case tab
    case quickTerminal
}

struct SessionSpawnContext: Sendable, Equatable {
    /// The tab's own last-known working directory (`Tab.pwd` /
    /// `TabSnapshot.pwd`), `nil` if never set.
    let cwd: String?
    /// The cwd inherited from the pane a new split was created from
    /// (e.g. the origin pane's live pwd at split time), which takes
    /// priority over `cwd` when present — a new split should land in
    /// the directory it was split from, even if the tab's own
    /// last-persisted pwd is stale.
    let inheritedCwd: String?
    let name: String?
    /// The remote ssh host to spawn this session against, `nil` for a
    /// local session (every existing call site, unchanged). Non-nil
    /// makes `plan(for:)` synthesize via
    /// `SessionCommandSynthesizer.remoteAttachCommand` instead of the
    /// local-only `attachCommand`, and skip the local binary-
    /// resolvability guard entirely (see `plan(for:)`'s doc comment).
    let host: String?
    let origin: SessionSpawnOrigin

    init(cwd: String? = nil, inheritedCwd: String? = nil, name: String? = nil, host: String? = nil, origin: SessionSpawnOrigin = .tab) {
        self.cwd = cwd
        self.inheritedCwd = inheritedCwd
        self.name = name
        self.host = host
        self.origin = origin
    }
}

enum SpawnPlan: Sendable, Equatable {
    /// Launch the surface's default shell directly, exactly as today.
    case passthrough
    /// Launch `calyx-session attach --create` for `sessionID`, running
    /// `command` (built by `SessionCommandSynthesizer`).
    case persistent(sessionID: String, command: String)
}

enum SessionSpawnPlanner {

    /// `.passthrough` when the feature is off, `context.origin` is
    /// `.quickTerminal` (QuickTerminal panes are always excluded, see
    /// `SessionSpawnOrigin`'s doc comment -- this exclusion wins even
    /// with `context.host` set), or (LOCAL context only) `resolver`
    /// can't find the calyx-session binary at all (a `nil` resolution
    /// must not fall back to a hardcoded `"calyx-session"` literal that
    /// assumes `PATH` availability -- see `SessionBinaryResolver`'s doc
    /// comment). Otherwise generates a fresh ULID session ID and the
    /// matching attach command, using `inheritedCwd ?? cwd ?? home` as
    /// the effective working directory (a new split should land in the
    /// directory it was split from, even when the tab's own
    /// last-persisted `cwd` is stale or absent).
    ///
    /// P5 (remote sessions): `context.host != nil` skips the LOCAL
    /// binary-resolvability guard entirely -- a remote session's daemon
    /// lives on the remote machine, so the LOCAL calyx-session binary's
    /// presence or absence says nothing about whether a remote spawn can
    /// proceed -- and synthesizes via
    /// `SessionCommandSynthesizer.remoteAttachCommand` instead of
    /// `attachCommand`. `remoteAttachCommand` never returns `nil`
    /// (`SSHBinaryResolver` always resolves to a path, see its own doc
    /// comment), so a remote `.persistent` plan can never itself fail to
    /// produce a command the way a local one degrading to `.passthrough`
    /// can. The fresh-ULID and cwd-priority contracts apply identically
    /// to both paths.
    static func plan(for context: SessionSpawnContext, resolver: SessionBinaryResolverProtocol = SessionBinaryResolver()) -> SpawnPlan {
        guard SessionSettings.persistentSessionsEnabled, context.origin != .quickTerminal else {
            return .passthrough
        }

        let sessionID = ULID.generate()
        let effectiveCwd = context.inheritedCwd ?? context.cwd ?? NSHomeDirectory()

        if let host = context.host {
            let command = SessionCommandSynthesizer.remoteAttachCommand(
                host: host,
                sessionID: sessionID,
                cwd: effectiveCwd,
                name: context.name
            )
            return .persistent(sessionID: sessionID, command: command)
        }

        guard let binaryPath = resolver.resolve() else {
            return .passthrough
        }
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath,
            sessionID: sessionID,
            cwd: effectiveCwd,
            name: context.name
        )
        return .persistent(sessionID: sessionID, command: command)
    }
}

/// Minimal ULID (Universally Unique Lexicographically Sortable
/// Identifier) generator: a 48-bit millisecond timestamp followed by 80
/// bits of randomness, both encoded in Crockford's base32 (no
/// third-party dependency — this feature's only consumer is
/// `SessionSpawnPlanner`). Monotonicity within the same millisecond is
/// not required here (see `SessionSpawnPlannerTests
/// .test_plan_enabledTabOrigin_distinctCallsProduceDistinctSessionIDs`,
/// which only asserts distinctness, satisfied by the 80 random bits),
/// so plain per-call randomness is sufficient.
enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        let timestampMS = UInt64(Date().timeIntervalSince1970 * 1000)
        var randomBytes = [UInt8](repeating: 0, count: 10)
        for i in randomBytes.indices {
            randomBytes[i] = UInt8.random(in: 0...255)
        }
        return encodeTimestamp(timestampMS)
            + encode40Bits(randomBytes[0..<5])
            + encode40Bits(randomBytes[5..<10])
    }

    /// Encodes a 48-bit timestamp into 10 base32 characters (50 bits of
    /// capacity; the top 2 bits are always 0 for any millisecond
    /// timestamp before the year 10889, matching the standard ULID
    /// encoding).
    private static func encodeTimestamp(_ ms: UInt64) -> String {
        var chars = [Character](repeating: "0", count: 10)
        for i in 0..<10 {
            let shift = (9 - i) * 5
            chars[i] = alphabet[Int((ms >> UInt64(shift)) & 0x1F)]
        }
        return String(chars)
    }

    /// Encodes exactly 5 bytes (40 bits) into 8 base32 characters — an
    /// even multiple of 5-bit groups, so two calls cover the ULID's
    /// full 80 bits of randomness with no partial group to carry over.
    private static func encode40Bits(_ bytes: ArraySlice<UInt8>) -> String {
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        var chars = [Character](repeating: "0", count: 8)
        for i in 0..<8 {
            let shift = (7 - i) * 5
            chars[i] = alphabet[Int((value >> UInt64(shift)) & 0x1F)]
        }
        return String(chars)
    }
}
