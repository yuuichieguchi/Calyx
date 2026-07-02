//
//  OpenCodePluginManagerTests.swift
//  CalyxTests
//
//  TDD Red Phase for OpenCodePluginManager (Phase 2): installs/removes
//  `<pluginsDirectory>/plugins/calyx-agent-monitor.js`, a Bun-runtime
//  plugin OpenCode auto-loads with no opencode.json edit required.
//
//  Coverage:
//  - install creates the `plugins/` directory and writes scriptBody
//    verbatim, overwriting idempotently on reinstall
//  - scriptBody invariants: CALYX_SURFACE_ID env guard (`return {}`),
//    agent-endpoint.json reference, X-Calyx-Agent-Kind: opencode header,
//    hook_event_name field, AbortSignal.timeout, catch-silenced errors,
//    parentID-based child-session exclusion, the 7 OpenCode event ->
//    Claude Code hook_event_name mappings, pendingPermissions suppressing
//    a racing session.idle, pendingPermissions and childSessions cleanup
//    on session.deleted, and the mtime-cached endpoint file read
//  - remove deletes an installed plugin (and throws if an existing file
//    can't be deleted), no-ops when absent
//  - isInstalled reflects install state
//  - A symlink at the plugin's destination path is rejected
//

import XCTest
@testable import Calyx

final class OpenCodePluginManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    /// Passed as `pluginsDirectory:` — the OpenCode config root
    /// (`~/.config/opencode` in production). install()/remove()/
    /// isInstalled() operate on `<this>/plugins/calyx-agent-monitor.js`.
    private var configRoot: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configRoot = tempDir + "/opencode"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private var expectedPluginPath: String {
        configRoot + "/plugins/calyx-agent-monitor.js"
    }

    /// Asserts that `eventKey` appears in `body` with `hookEventName`
    /// present shortly after it (i.e. within the same mapping entry),
    /// without pinning down the surrounding literal-vs-object-vs-switch
    /// syntax the implementation chooses.
    private func assertMapping(_ eventKey: String, mapsTo hookEventName: String, in body: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let keyRange = body.range(of: "\"\(eventKey)\"") ?? body.range(of: "'\(eventKey)'") else {
            XCTFail("scriptBody must reference the \(eventKey) event key", file: file, line: line)
            return
        }
        let windowEnd = body.index(keyRange.upperBound, offsetBy: 200, limitedBy: body.endIndex) ?? body.endIndex
        let window = body[keyRange.upperBound..<windowEnd]
        XCTAssertTrue(window.contains(hookEventName),
                     "\(eventKey) must map to hook_event_name \(hookEventName) within its mapping entry",
                     file: file, line: line)
    }

    // MARK: - install()

    func test_install_createsPluginsDirectoryAndWritesScriptBodyExactly() throws {
        let path = try OpenCodePluginManager.install(pluginsDirectory: configRoot)

        XCTAssertEqual(path, expectedPluginPath, "install() must return the plugin's absolute path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot + "/plugins", isDirectory: &isDir),
                      "install() must create the plugins/ directory")
        XCTAssertTrue(isDir.boolValue)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, OpenCodePluginManager.scriptBody,
                       "Installed plugin content must match scriptBody exactly")
    }

    func test_install_reinstall_overwritesIdempotently() throws {
        let firstPath = try OpenCodePluginManager.install(pluginsDirectory: configRoot)
        try "stale content from a previous version".write(toFile: firstPath, atomically: true, encoding: .utf8)

        let secondPath = try OpenCodePluginManager.install(pluginsDirectory: configRoot)

        XCTAssertEqual(firstPath, secondPath, "install() must return the same path on reinstall")
        let content = try String(contentsOfFile: secondPath, encoding: .utf8)
        XCTAssertEqual(content, OpenCodePluginManager.scriptBody,
                       "Reinstalling must overwrite stale content with the current scriptBody")
    }

    // MARK: - scriptBody invariants

    func test_scriptBody_guardsOnMissingSurfaceIDAndReturnsEmptyHooks() {
        let body = OpenCodePluginManager.scriptBody

        XCTAssertTrue(body.contains("CALYX_SURFACE_ID"),
                     "Plugin must gate on process.env.CALYX_SURFACE_ID")
        XCTAssertTrue(body.contains("return {}"),
                     "When CALYX_SURFACE_ID is unset, the plugin must register no hooks (return {})")
    }

    func test_scriptBody_referencesAgentEndpointFile() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("agent-endpoint.json"),
                     "Plugin must re-read agent-endpoint.json on every event")
    }

    func test_scriptBody_sendsAgentKindHeaderAsOpenCode() {
        let body = OpenCodePluginManager.scriptBody
        guard let headerRange = body.range(of: "X-Calyx-Agent-Kind") else {
            XCTFail("scriptBody must send the X-Calyx-Agent-Kind header")
            return
        }
        let windowEnd = body.index(headerRange.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        XCTAssertTrue(body[headerRange.upperBound..<windowEnd].contains("opencode"),
                     "X-Calyx-Agent-Kind header value must be opencode")
    }

    func test_scriptBody_usesHookEventNameField() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("hook_event_name"),
                     "Plugin must post the canonical hook_event_name field, matching AgentEvent.decode")
    }

    func test_scriptBody_usesAbortSignalTimeout() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("AbortSignal.timeout"),
                     "Plugin's fetch must be bounded by AbortSignal.timeout")
    }

    func test_scriptBody_silencesErrorsViaCatch() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("catch"),
                     "Plugin must swallow all errors (unreachable server, timeout, etc.) via catch")
    }

    func test_scriptBody_excludesChildSessionsByParentID() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("parentID"),
                     "Plugin must track info.parentID to exclude subagent child sessions")
    }

    func test_scriptBody_tracksPendingPermissionsAndSuppressesIdleWhilePending() {
        let body = OpenCodePluginManager.scriptBody
        XCTAssertTrue(body.contains("pendingPermissions"),
                     "Plugin must track sessions with an outstanding permission.asked")
        XCTAssertTrue(body.contains("pendingPermissions.add(sessionID)"),
                     "permission.asked must mark the session pending")
        XCTAssertTrue(body.contains("pendingPermissions.delete(sessionID)"),
                     "permission.replied must clear the session's pending state")

        guard let idleGuardRange = body.range(
            of: "event.type === \"session.idle\" && pendingPermissions.has(sessionID)"
        ) else {
            XCTFail("session.idle must check pendingPermissions before forwarding")
            return
        }
        let windowEnd = body.index(idleGuardRange.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        XCTAssertTrue(body[idleGuardRange.upperBound..<windowEnd].contains("return"),
                     "A pending session's session.idle must be discarded (return), not forwarded as Stop, " +
                     "so it can't overwrite a blocked row with idle while a prompt awaits a reply")
    }

    func test_scriptBody_deletesPendingPermissionOnSessionDeleted() {
        // A `} else if (` prefix disambiguates this from the unrelated
        // `if (event.type === "session.deleted") {` check nested inside the
        // childSessions branch above it in the script.
        let body = OpenCodePluginManager.scriptBody
        guard let sessionDeletedRange = body.range(
            of: "} else if (event.type === \"session.deleted\") {"
        ) else {
            XCTFail("scriptBody must have a session.deleted branch in the permission-tracking chain")
            return
        }
        let windowEnd = body.index(
            sessionDeletedRange.upperBound, offsetBy: 60, limitedBy: body.endIndex
        ) ?? body.endIndex
        XCTAssertTrue(
            body[sessionDeletedRange.upperBound..<windowEnd].contains("pendingPermissions.delete(sessionID)"),
            "A session's own session.deleted must remove it from pendingPermissions too, mirroring " +
            "childSessions' cleanup, so an outstanding never-answered prompt doesn't leak an entry " +
            "for the lifetime of the plugin process"
        )
    }

    func test_scriptBody_deletesChildSessionOnItsOwnSessionDeleted() {
        let body = OpenCodePluginManager.scriptBody
        guard let childSessionsCheckRange = body.range(of: "if (childSessions.has(sessionID)) {") else {
            XCTFail("scriptBody must guard on childSessions.has(sessionID)")
            return
        }
        let windowEnd = body.index(
            childSessionsCheckRange.upperBound, offsetBy: 200, limitedBy: body.endIndex
        ) ?? body.endIndex
        let window = body[childSessionsCheckRange.upperBound..<windowEnd]
        XCTAssertTrue(window.contains("session.deleted"),
                     "The childSessions branch must check for the child's own session.deleted")
        XCTAssertTrue(window.contains("childSessions.delete(sessionID)"),
                     "A child session's own session.deleted must remove it from childSessions, " +
                     "so the set doesn't grow without bound over a long-lived process")
    }

    func test_scriptBody_cachesEndpointFileByMtime() {
        let body = OpenCodePluginManager.scriptBody
        XCTAssertTrue(body.contains("mtimeMs"),
                     "Plugin must compare the endpoint file's mtime to avoid re-parsing it on every event")
        XCTAssertTrue(body.contains("cachedEndpoint"),
                     "Plugin must cache the parsed endpoint (port/token) across events")
        XCTAssertTrue(body.contains("import { stat }") && body.contains("node:fs/promises"),
                     "Plugin must stat the endpoint file to detect changes (e.g. a Calyx server restart)")
    }

    func test_scriptBody_mapsAllSevenEventsToExpectedHookEventNames() {
        let body = OpenCodePluginManager.scriptBody
        let expectedMappings: [(event: String, hookEventName: String)] = [
            ("session.created", "SessionStart"),
            ("tool.execute.before", "PreToolUse"),
            ("tool.execute.after", "PostToolUse"),
            ("permission.asked", "PermissionRequest"),
            ("permission.replied", "PostToolUse"),
            ("session.idle", "Stop"),
            ("session.deleted", "SessionEnd"),
        ]
        for mapping in expectedMappings {
            assertMapping(mapping.event, mapsTo: mapping.hookEventName, in: body)
        }
    }

    // MARK: - remove()

    func test_remove_missingFileIsNoop_andDeletesAnInstalledPlugin() throws {
        // Part 1: no-op when nothing is installed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPluginPath))
        XCTAssertNoThrow(try OpenCodePluginManager.remove(pluginsDirectory: configRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPluginPath))

        // Part 2: once installed, remove() must actually delete it.
        let installedPath = try OpenCodePluginManager.install(pluginsDirectory: configRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedPath),
                      "Precondition: install must have written the plugin")

        try OpenCodePluginManager.remove(pluginsDirectory: configRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath),
                       "remove() must delete the installed plugin")
    }

    func test_remove_fileExistsButDeletionFails_throws() throws {
        // Deleting a file requires write permission on its *containing*
        // directory, not the file itself — stripping write (while keeping
        // read+execute, so the file stays visible to fileExists) from
        // plugins/ stands in for any "exists but can't be deleted" failure
        // (permissions, etc.) that must now surface as a thrown error
        // rather than being silently swallowed.
        let pluginsDir = configRoot + "/plugins"
        _ = try OpenCodePluginManager.install(pluginsDirectory: configRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPluginPath),
                      "Precondition: install must have written the plugin")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pluginsDir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginsDir)
        }

        XCTAssertThrowsError(try OpenCodePluginManager.remove(pluginsDirectory: configRoot),
                             "remove() must throw when the plugin file exists but can't be deleted")
    }

    // MARK: - isInstalled()

    func test_isInstalled_reflectsInstallState() throws {
        XCTAssertFalse(OpenCodePluginManager.isInstalled(pluginsDirectory: configRoot),
                       "Nothing installed yet -> must not be reported as installed")

        _ = try OpenCodePluginManager.install(pluginsDirectory: configRoot)

        XCTAssertTrue(OpenCodePluginManager.isInstalled(pluginsDirectory: configRoot),
                      "After install, must be reported as installed")

        try OpenCodePluginManager.remove(pluginsDirectory: configRoot)

        XCTAssertFalse(OpenCodePluginManager.isInstalled(pluginsDirectory: configRoot),
                       "After remove, must no longer be reported as installed")
    }

    // MARK: - Security

    func test_install_symlinkAtDestinationPath_throws() throws {
        let pluginsDir = configRoot + "/plugins"
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let realFile = tempDir + "/real_plugin.js"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: pluginsDir + "/calyx-agent-monitor.js",
            withDestinationPath: realFile
        )

        XCTAssertThrowsError(
            try OpenCodePluginManager.install(pluginsDirectory: configRoot),
            "install() must reject a symlink at the plugin's destination path"
        )
    }
}
