//
//  OpenCodePluginManagerTests.swift
//  CalyxTests
//
//  Covers OpenCodePluginManager (Phase 2): installs/removes
//  `<pluginsDirectory>/plugins/calyx-agent-monitor.js`, a Bun-runtime
//  plugin OpenCode auto-loads with no opencode.json edit required.
//
//  Coverage:
//  - install creates the `plugins/` directory and writes scriptBody
//    verbatim, overwriting idempotently on reinstall
//  - scriptBody invariants: CALYX_SURFACE_ID env guard (`return {}`),
//    agent-endpoint.json reference, X-Calyx-Agent-Kind: opencode header,
//    hook_event_name field, AbortSignal.timeout, catch-silenced errors,
//    the 7 OpenCode event -> Claude Code hook_event_name mappings,
//    pendingPermissions suppressing a racing session.idle,
//    pendingPermissions cleanup on session.deleted, and the mtime-cached
//    endpoint file read
//  - childSessions translation (replacing the old suppression): a child
//    session's own session.created posts SubagentStart, its own
//    session.deleted posts SubagentStop, every event in between is
//    forwarded with agent_id set to the child session id, and the POST
//    body for a child event never carries session_id
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
        try! FileManager.default.createDirectory(atPath: configRoot, withIntermediateDirectories: true)
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

    func test_scriptBody_guardsOnMissingPaneIdentityAndPrefersStableSessionID() {
        let body = OpenCodePluginManager.scriptBody

        XCTAssertTrue(body.contains("CALYX_SURFACE_ID"),
                     "Plugin must support an ordinary pane's CALYX_SURFACE_ID")
        XCTAssertTrue(body.contains("CALYX_SESSION_ID"),
                     "Plugin must support a persistent pane's stable CALYX_SESSION_ID")
        XCTAssertTrue(
            body.contains("process.env.CALYX_SESSION_ID || process.env.CALYX_SURFACE_ID"),
            "Plugin must prefer CALYX_SESSION_ID over the reconnect-sensitive surface UUID"
        )
        XCTAssertTrue(body.contains("return {}"),
                     "When both pane identity variables are unset, the plugin must register no hooks")
    }

    func test_scriptBody_referencesAgentEndpointFile() {
        XCTAssertTrue(OpenCodePluginManager.scriptBody.contains("agent-endpoint.json"),
                     "Plugin must re-read agent-endpoint.json on every event")
    }

    func test_scriptBody_readsEndpointPathFromCalyxEndpointFileWithLiteralFallback() {
        XCTAssertTrue(
            OpenCodePluginManager.scriptBody.contains(
                "process.env.CALYX_ENDPOINT_FILE ?? \(AgentEndpointFile.javascriptFallbackPathExpression)"
            ),
            "Plugin must read CALYX_ENDPOINT_FILE (injected by GhosttySurfaceController, scoped to " +
            "wherever Calyx actually wrote agent-endpoint.json), falling back to the literal " +
            "process.env.HOME-relative path for a pane launched before that injection existed"
        )
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

    // MARK: - childSessions translation (subagent rows)
    //
    // Replaces the old suppression contract (a child session's events
    // never reached the server at all -- see git history for the removed
    // "childSessions.has(sessionID)) { ... return; }" tests) now that the
    // structural guard "a child never owns a row" lives server-side
    // (AgentEvent.isSubagentEvent / CalyxMCPServer.routeAgentEvent). The
    // plugin now translates a child session's events into subagent
    // events instead of discarding them.

    /// Every `body: JSON.stringify({ ... })` object literal in
    /// `scriptBody`, as raw source text -- assumes a flat (no nested
    /// braces) object literal, which every body this plugin builds is.
    private func jsonStringifyBodies(in script: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"JSON\.stringify\(\{([\s\S]*?)\}\)"#) else { return [] }
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return regex.matches(in: script, range: range).compactMap { match in
            guard let bodyRange = Range(match.range(at: 1), in: script) else { return nil }
            return String(script[bodyRange])
        }
    }

    func test_scriptBody_containsSubagentStartAndSubagentStopLiterals() {
        let body = OpenCodePluginManager.scriptBody
        XCTAssertTrue(body.contains("SubagentStart"),
                     "The plugin must be able to post SubagentStart for a child session's own session.created")
        XCTAssertTrue(body.contains("SubagentStop"),
                     "The plugin must be able to post SubagentStop for a child session's own session.deleted")
    }

    func test_scriptBody_everyBodyCarryingAgentId_neverAlsoCarriesSessionId() {
        let bodies = jsonStringifyBodies(in: OpenCodePluginManager.scriptBody)
        XCTAssertFalse(bodies.isEmpty, "Precondition: scriptBody must build at least one POST body")

        let agentIDBodies = bodies.filter { $0.contains("agent_id") }
        XCTAssertFalse(agentIDBodies.isEmpty,
                       "At least one POST body must carry agent_id -- the child-event translation path")
        for body in agentIDBodies {
            XCTAssertFalse(body.contains("session_id"),
                           "A child event's POST body must never carry session_id, or a later reattach " +
                           "could offer to resume the child instead of the parent conversation. Body: \(body)")
        }
    }

    func test_scriptBody_atLeastOneBodyStillCarriesPlainSessionId() {
        // Non-regression: the parent (non-child) path must keep sending
        // session_id exactly as it does today.
        let bodies = jsonStringifyBodies(in: OpenCodePluginManager.scriptBody)
        XCTAssertTrue(bodies.contains { $0.contains("session_id") && !$0.contains("agent_id") },
                      "The ordinary (non-child) event path must still send a body carrying session_id " +
                      "with no agent_id")
    }

    // MARK: - child session.idle retirement (SubagentStop)
    //
    // A subagent session going idle is OpenCode reporting that child's
    // work is over -- a subagent does not take another turn. The child's
    // own session.idle must retire it exactly like its own session.deleted
    // does, since a captured real subagent run never emits session.deleted
    // at all: session.idle is what actually fires.

    func test_scriptBody_childSessionOwnSessionIdlePostsSubagentStop() {
        let body = OpenCodePluginManager.scriptBody
        guard let childSessionsCheckRange = body.range(of: "if (childSessions.has(sessionID)) {") else {
            XCTFail("scriptBody must guard on childSessions.has(sessionID)")
            return
        }
        let windowEnd = body.index(
            childSessionsCheckRange.upperBound, offsetBy: 260, limitedBy: body.endIndex
        ) ?? body.endIndex
        let window = body[childSessionsCheckRange.upperBound..<windowEnd]
        XCTAssertTrue(window.contains("session.idle"),
                     "The childSessions branch must check for the child's own session.idle, not just " +
                     "session.deleted, since a real subagent run never fires session.deleted at all")
        XCTAssertTrue(window.contains("SubagentStop"),
                     "A child session's own session.idle must post SubagentStop, mirroring session.deleted")
    }

    func test_scriptBody_childSessionIdleRemovesFromChildSessionsAndPendingPermissions() {
        let body = OpenCodePluginManager.scriptBody
        guard let childSessionsCheckRange = body.range(of: "if (childSessions.has(sessionID)) {") else {
            XCTFail("scriptBody must guard on childSessions.has(sessionID)")
            return
        }
        // Narrow window: only the retirement branch (session.deleted ||
        // session.idle), not the plain forwarding branch below it.
        guard let subagentStopRange = body.range(
            of: "SubagentStop", range: childSessionsCheckRange.upperBound..<body.endIndex
        ) else {
            XCTFail("scriptBody must post SubagentStop somewhere inside the childSessions branch")
            return
        }
        let windowStart = childSessionsCheckRange.upperBound
        let windowEnd = subagentStopRange.lowerBound
        let window = body[windowStart..<windowEnd]
        XCTAssertTrue(window.contains("childSessions.delete(sessionID)"),
                     "Retiring a child on its own session.idle must remove it from childSessions")
        XCTAssertTrue(window.contains("pendingPermissions.delete(sessionID)"),
                     "Retiring a child on its own session.idle must remove it from pendingPermissions")
    }

    func test_scriptBody_pendingPermissionsSuppressionPrecedesChildSessionsBranch() {
        // The pendingPermissions.has(sessionID) suppression for
        // session.idle must be checked (and return early) before the
        // childSessions.has(sessionID) branch is ever reached, so a child
        // with an outstanding, unanswered permission.asked can't be
        // retired by a session.idle racing its own permission.replied.
        let body = OpenCodePluginManager.scriptBody
        guard let idleGuardRange = body.range(
            of: "event.type === \"session.idle\" && pendingPermissions.has(sessionID)"
        ) else {
            XCTFail("scriptBody must guard session.idle on pendingPermissions.has(sessionID)")
            return
        }
        guard let childSessionsCheckRange = body.range(of: "if (childSessions.has(sessionID)) {") else {
            XCTFail("scriptBody must guard on childSessions.has(sessionID)")
            return
        }
        XCTAssertTrue(idleGuardRange.upperBound < childSessionsCheckRange.lowerBound,
                     "pendingPermissions suppression of session.idle must be checked before the " +
                     "childSessions retirement branch, so a pending child's session.idle returns early " +
                     "instead of retiring it")
    }

    func test_scriptBody_parentSessionIdleMapsToStopAndCarriesSessionIdNotAgentId() {
        // Non-regression: only a child session's session.idle is
        // translated into SubagentStop. A parent's own session.idle must
        // still be forwarded as an ordinary Stop event with session_id.
        assertMapping("session.idle", mapsTo: "Stop", in: OpenCodePluginManager.scriptBody)

        let bodies = jsonStringifyBodies(in: OpenCodePluginManager.scriptBody)
        XCTAssertTrue(
            bodies.contains { $0.contains("hookEventName") && $0.contains("session_id") && !$0.contains("agent_id") },
            "The non-child (parent) event path must post hookEventName with session_id and no agent_id, " +
            "covering a parent's own session.idle -> Stop"
        )
    }

    func test_scriptBody_childSessionDeletedStillPostsSubagentStop() {
        // Non-regression: session.deleted remains a legitimate end signal
        // alongside the new session.idle retirement path, even though a
        // real captured subagent run never produced one.
        let body = OpenCodePluginManager.scriptBody
        guard let childSessionsCheckRange = body.range(of: "if (childSessions.has(sessionID)) {") else {
            XCTFail("scriptBody must guard on childSessions.has(sessionID)")
            return
        }
        let windowEnd = body.index(
            childSessionsCheckRange.upperBound, offsetBy: 260, limitedBy: body.endIndex
        ) ?? body.endIndex
        let window = body[childSessionsCheckRange.upperBound..<windowEnd]
        XCTAssertTrue(window.contains("session.deleted"),
                     "The childSessions branch must still check for the child's own session.deleted")
        XCTAssertTrue(window.contains("SubagentStop"),
                     "A child session's own session.deleted must still post SubagentStop")
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

    // Contract: a dotfiles-managed OpenCode config root
    // can legitimately symlink its plugins/ directory (or an individual
    // plugin file) elsewhere. Blanket symlink rejection silently broke
    // plugin installation in that setup. install() now follows the link
    // and overwrites the real target file, leaving the link itself
    // intact — consistent with install()'s existing plain-overwrite
    // contract for a non-symlinked destination.
    func test_install_symlinkAtDestinationPath_followsAndOverwritesRealFileKeepingLinkIntact() throws {
        let pluginsDir = configRoot + "/plugins"
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let realFile = tempDir + "/real_plugin.js"
        FileManager.default.createFile(atPath: realFile, contents: Data("// stale content".utf8))
        let destinationPath = pluginsDir + "/calyx-agent-monitor.js"
        try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: realFile)

        _ = try OpenCodePluginManager.install(pluginsDirectory: configRoot)

        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertEqual(realContent, OpenCodePluginManager.scriptBody,
                       "install() must overwrite the real file reached through the symlink with the plugin body")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at the plugin's destination path must survive the install")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: destinationPath)
        XCTAssertEqual(destination, realFile)
    }

    // resolveConfigPath follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // config manager.
    func test_install_multiHopDanglingSymlink_writesToFinalDestinationKeepingBothLinksIntact() throws {
        let pluginsDir = configRoot + "/plugins"
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let dotfilesDir = tempDir + "/dotfiles"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        let finalTarget = dotfilesDir + "/calyx-agent-monitor.js"
        let middleLink = tempDir + "/middle-link.js"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        let destinationPath = pluginsDir + "/calyx-agent-monitor.js"
        try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: middleLink)

        _ = try OpenCodePluginManager.install(pluginsDirectory: configRoot)

        let realContent = try String(contentsOfFile: finalTarget, encoding: .utf8)
        XCTAssertEqual(realContent, OpenCodePluginManager.scriptBody,
                       "install() must create the plugin at the multi-hop dangling chain's final destination")

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    // remove() previously deleted the raw (possibly
    // symlinked) destination path directly — for a symlinked
    // destination, that deletes the *symlink itself* (unlink(2) doesn't
    // follow it), leaving the real installed file behind un-removed and
    // orphaning it, asymmetric with install()'s follow-through-and-write
    // behavior above. remove() must now resolve the same way and delete
    // the real target, leaving the (now-dangling) symlink itself intact.
    func test_remove_symlinkAtDestinationPath_removesRealFileKeepingLinkIntact() throws {
        let pluginsDir = configRoot + "/plugins"
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let realFile = tempDir + "/real_plugin.js"
        FileManager.default.createFile(atPath: realFile, contents: Data(OpenCodePluginManager.scriptBody.utf8))
        let destinationPath = pluginsDir + "/calyx-agent-monitor.js"
        try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: realFile)

        try OpenCodePluginManager.remove(pluginsDirectory: configRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: realFile),
                       "remove() must delete the real file reached through the symlink")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at the plugin's destination path must survive remove() (now dangling)")
    }
}
