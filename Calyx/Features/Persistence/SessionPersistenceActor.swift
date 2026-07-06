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
        if snapshot.windows.isEmpty {
            let onDiskSavePath = loadFromPath(savePath)
            if let onDiskSavePath, !onDiskSavePath.windows.isEmpty {
                logger.warning("Refusing to overwrite non-empty on-disk session with an empty snapshot at termination")
                return
            }
            if onDiskSavePath == nil, let onDiskBackup = loadFromPath(backupPath), !onDiskBackup.windows.isEmpty {
                logger.warning("Refusing to overwrite non-empty backup (savePath undecodable) with an empty snapshot at termination")
                return
            }
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
    /// savePath does not exist (nothing was ever saved). First-wins when
    /// a preserved file already exists: the older, pre-incident session
    /// is the valuable one (the last snapshot taken before whatever
    /// started going wrong), while everything a crash loop preserves
    /// afterward is just another state of an already-broken run, so an
    /// existing preserved file is kept untouched rather than overwritten.
    /// savePath itself is left in place in that branch too -- it is not
    /// preserved anywhere, but this run's own subsequent saves will
    /// rewrite it regardless, so removing it here would be gratuitous
    /// file I/O with no data-safety benefit. Returns whether a preserved
    /// file exists after the call, whether newly moved by this call or
    /// already present from an earlier one, so the caller
    /// (preserveDiscardedSessionIfAny()) keeps firing its
    /// notify+flag wiring in both cases.
    @discardableResult
    func preserveSnapshotForRecovery() -> Bool {
        guard FileManager.default.fileExists(atPath: savePath.path) else { return false }
        guard !FileManager.default.fileExists(atPath: recoverySnapshotPath.path) else {
            // First-wins (F3): an earlier, still-unrecovered preserved
            // session is more valuable than this run's own (also
            // broken) on-disk state. savePath is left as-is; this run's
            // own subsequent saves will rewrite it regardless.
            return true
        }
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

    /// Called when hasPreservedSnapshot() is true but
    /// loadPreservedSnapshot() returned nil (corrupt bytes or an
    /// unknown future schema version): renames the unusable recovery
    /// file aside to sessions.recovery.json.corrupt instead of
    /// deleting it -- nothing is destroyed, only retired from the
    /// active recovery path -- so hasPreservedSnapshot() reports false
    /// afterwards and the caller can stop offering a dead command. A
    /// no-op returning false when there is nothing preserved to
    /// quarantine (mirrors preserveSnapshotForRecovery()'s own
    /// no-op-when-absent convention).
    @discardableResult
    func quarantineCorruptPreservedSnapshot() -> Bool {
        guard FileManager.default.fileExists(atPath: recoverySnapshotPath.path) else { return false }
        let quarantinePath = recoverySnapshotPath.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: quarantinePath)
        do {
            try FileManager.default.moveItem(at: recoverySnapshotPath, to: quarantinePath)
            return true
        } catch {
            return false
        }
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
