// SessionPersistenceActor.swift
// Calyx
//
// Serialized session save/restore with atomic writes and file locking.

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SessionPersistence")

actor SessionPersistenceActor {

    private let savePath: URL
    private let backupPath: URL
    private let recoveryMarkerPath: URL
    private let recoverySnapshotPath: URL
    private var pendingSave: Task<Void, Never>?

    static let shared = SessionPersistenceActor()

    init() {
        let calyxDir: URL
        if let testDir = ProcessInfo.processInfo.environment["CALYX_UITEST_SESSION_DIR"] {
            calyxDir = URL(fileURLWithPath: testDir, isDirectory: true)
        } else {
            // SessionRootResolver is the single definition of the session
            // root (see SessionRootResolver.swift); for a normal launch
            // this resolves to the same real home as before. Custom-HOME
            // launches now store snapshots under the resolved root
            // instead (no migration; intentional).
            let homeDir = URL(fileURLWithPath: SessionRootResolver().resolve(), isDirectory: true)
            calyxDir = homeDir.appendingPathComponent(".calyx", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: calyxDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        self.savePath = calyxDir.appendingPathComponent("sessions.json")
        self.backupPath = calyxDir.appendingPathComponent("sessions.json.bak")
        self.recoveryMarkerPath = calyxDir.appendingPathComponent(".recovery")
        self.recoverySnapshotPath = calyxDir.appendingPathComponent("sessions.recovery.json")
    }

    func sessionSavePath() -> URL {
        savePath
    }

    /// Migrate session data from legacy Application Support path to ~/.calyx/.
    /// Returns true if migration was performed.
    @discardableResult
    func migrateFromLegacyPath() -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyPath = appSupport.appendingPathComponent("Calyx/session.json")

        guard FileManager.default.fileExists(atPath: legacyPath.path),
              !FileManager.default.fileExists(atPath: savePath.path) else {
            return false
        }

        do {
            try FileManager.default.copyItem(at: legacyPath, to: savePath)
            logger.info("Migrated session from legacy path")
            return true
        } catch {
            logger.error("Failed to migrate from legacy path: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Save

    func save(_ snapshot: SessionSnapshot) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await performSave(snapshot)
        }
    }

    func saveImmediately(_ snapshot: SessionSnapshot) async {
        pendingSave?.cancel()
        await performSave(snapshot)
    }

    /// Save used ONLY from applicationWillTerminate. Unlike
    /// saveImmediately(_:), refuses to let an EMPTY snapshot replace a
    /// non-empty on-disk snapshot -- teardown ordering can hand this
    /// call an empty snapshot (windowControllers already drained) even
    /// though a good session is still on disk from an earlier save,
    /// and there is no recovery once that file is overwritten. A
    /// user's deliberate "close every window" save keeps going through
    /// saveImmediately(_:) (via AppDelegate.saveImmediately(), called
    /// from windowWillClose), which this method does not change.
    func saveAtTermination(_ snapshot: SessionSnapshot) async {
        if snapshot.windows.isEmpty, let onDisk = loadFromPath(savePath), !onDisk.windows.isEmpty {
            logger.warning("Refusing to overwrite non-empty on-disk session with an empty snapshot at termination")
            return
        }
        await performSave(snapshot)
    }

    private func performSave(_ snapshot: SessionSnapshot) async {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let tmpPath = savePath.appendingPathExtension("tmp")

            try data.write(to: tmpPath, options: .atomic)

            // Set file permissions
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpPath.path
            )

            // Rotate backup
            if FileManager.default.fileExists(atPath: savePath.path) {
                try? FileManager.default.removeItem(at: backupPath)
                try? FileManager.default.moveItem(at: savePath, to: backupPath)
            }

            // Atomic rename
            try FileManager.default.moveItem(at: tmpPath, to: savePath)

            logger.info("Session saved successfully")
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore

    func restore() -> SessionSnapshot? {
        // Try migrating from legacy path first
        migrateFromLegacyPath()

        if let snapshot = loadFromPath(savePath) {
            return snapshot
        }

        logger.warning("Primary session file failed, trying backup")
        return loadFromPath(backupPath)
    }

    private func loadFromPath(_ path: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: path) else { return nil }

        do {
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)

            if snapshot.schemaVersion > SessionSnapshot.currentSchemaVersion {
                logger.warning("Unknown schema version \(snapshot.schemaVersion), discarding")
                return nil
            }

            // Apply migration pipeline
            return SessionSnapshot.migrate(snapshot)
        } catch {
            logger.error("Failed to decode session from \(path.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Recovery Preservation

    /// Moves whatever is CURRENTLY on disk at savePath aside to the
    /// recovery path, so the next launch's own saves (which only ever
    /// touch savePath/backupPath) cannot clobber it. Takes no snapshot
    /// parameter deliberately: it preserves the RAW on-disk file,
    /// whatever its content -- including one restore() itself failed to
    /// decode (corrupt JSON, unknown future schema version) -- since
    /// something is still worth keeping in that case too. A no-op when
    /// savePath does not exist (nothing was ever saved, or a prior
    /// preserve already moved it -- e.g. a second consecutive bad
    /// launch keeps only the MOST RECENT preserved snapshot, an
    /// explicit simplification, not an oversight: this call site only
    /// ever fires once per launch and the caller (AppDelegate) is
    /// responsible for not calling it at all when restore() decoded a
    /// genuinely EMPTY snapshot). Returns whether a file was actually
    /// moved, so the caller can distinguish a real preserve from a no-op.
    @discardableResult
    func preserveSnapshotForRecovery() -> Bool {
        guard FileManager.default.fileExists(atPath: savePath.path) else { return false }
        try? FileManager.default.removeItem(at: recoverySnapshotPath)
        try? FileManager.default.moveItem(at: savePath, to: recoverySnapshotPath)
        return true
    }

    func hasPreservedSnapshot() -> Bool {
        FileManager.default.fileExists(atPath: recoverySnapshotPath.path)
    }

    func loadPreservedSnapshot() -> SessionSnapshot? {
        loadFromPath(recoverySnapshotPath)
    }

    func clearPreservedSnapshot() {
        try? FileManager.default.removeItem(at: recoverySnapshotPath)
    }

    // MARK: - Crash Loop Detection

    func incrementRecoveryCounter() -> Int {
        let count = currentRecoveryCount() + 1
        try? "\(count)".write(to: recoveryMarkerPath, atomically: true, encoding: .utf8)
        return count
    }

    func resetRecoveryCounter() {
        try? FileManager.default.removeItem(at: recoveryMarkerPath)
    }

    func currentRecoveryCount() -> Int {
        guard let content = try? String(contentsOf: recoveryMarkerPath, encoding: .utf8),
              let count = Int(content) else {
            return 0
        }
        return count
    }

    static let maxRecoveryAttempts = 3
}
