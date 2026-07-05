//
//  SessionCommandPaletteNewRemoteTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), RED5 cycle (remote UI wiring),
//  contract R2: a "New Remote Session..." command-palette entry
//  (`session.newRemote`), registered by
//  `CalyxWindowController.setupCommandRegistry` alongside
//  `session.attach`/`session.detach`/`session.kill`
//  (SessionCommandPaletteTests, P4), plus a directly-testable seam that
//  produces the SessionSpawnContext a chosen remote host must turn
//  into.
//
//  GATING PRECEDENT (investigated, not assumed): NEITHER `session.attach`
//  (registered with no isAvailable at all -- always offered) NOR
//  `session.detach`/`session.kill` (gated on focusedPaneHasTrackedSession,
//  an existing-pane check) gates on SessionSettings.persistentSessionsEnabled
//  today. The actual existing precedent for THAT flag gating NEW
//  persistent-session creation lives one layer down, in
//  SessionSpawnPlanner.plan(for:)'s own guard (SessionSpawnPlanner.swift:
//  "guard SessionSettings.persistentSessionsEnabled, context.origin != .quickTerminal").
//  Since session.newRemote's entire purpose is spawning a brand-new
//  persistent session -- exactly what that guard already gates -- this
//  is the precedent it mirrors, not the other three session.* commands',
//  which act on an existing pane or open the browser unconditionally.
//
//  ORIGIN TAXONOMY: SessionSpawnOrigin has exactly two cases, `.tab` and
//  `.quickTerminal` (SessionSpawnPlanner.swift) -- every existing
//  createManagedSurface(...) call site for an ordinary new tab/split
//  passes `.tab`. A remote session created via the palette is, at the
//  surface-creation level, still a new TAB; there is no dedicated
//  palette-specific origin case, so `.tab` is what "matching the
//  palette's existing origin taxonomy" means here.
//
//  SCOPE: the actual host-PICKER UI (how the user selects a host once
//  session.newRemote's handler runs) is out of scope this round -- no
//  new visual design contract, no XCUITest. In scope: (1) the command
//  exists and is gated correctly, tested exactly in
//  SessionCommandPaletteTests' direct-query style; (2) once a host
//  string is available (however the real picker obtains one, a later
//  concern), CalyxWindowController.remoteSessionSpawnContext(forHost:)
//  is the single, directly-testable place that turns it into the
//  SessionSpawnContext the already-green spawn path
//  (SessionSpawnPlannerRemoteHostTests) consumes.
//
//  Held-out compile-RED file per this codebase's established convention:
//  `remoteSessionSpawnContext(forHost:)` does not exist on
//  CalyxWindowController yet, and no `session.newRemote` command is
//  registered. Expected to FAIL TO COMPILE until the Green phase adds
//  the method (the command-registration/gating tests below would only
//  runtime-fail via XCTUnwrap on their own, matching
//  SessionCommandPaletteTests' P4 Red-phase precedent, but sharing this
//  file with the new-method reference makes the whole file compile-RED
//  instead).
//
//  Coverage:
//  - session.newRemote is registered, category "Sessions"
//  - isAvailable is true when SessionSettings.persistentSessionsEnabled,
//    false otherwise -- mirrors SessionSpawnPlanner.plan(for:)'s own gate
//  - remoteSessionSpawnContext(forHost:) carries the given host and
//    origin == .tab
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SessionCommandPaletteNewRemoteTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.SessionCommandPaletteNewRemoteTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// `restoring: true` skips setupTerminalSurface(), which requires a
    /// live Ghostty app instance -- same helper shape as
    /// SessionCommandPaletteTests.makeController() (P4).
    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    private func command(_ id: String, in controller: CalyxWindowController) throws -> PaletteCommand {
        try XCTUnwrap(
            controller.commandRegistry.allCommands.first(where: { $0.id == id }),
            "setupCommandRegistry must register a '\(id)' command"
        )
    }

    // MARK: - Registration

    func test_sessionNewRemoteCommand_isRegistered_inSessionsCategory() throws {
        let controller = makeController()
        let newRemoteCommand = try command("session.newRemote", in: controller)

        XCTAssertEqual(newRemoteCommand.category, "Sessions",
                       "session.newRemote must sit in the same 'Sessions' category as " +
                       "session.attach/detach/kill")
    }

    // MARK: - isAvailable gating (mirrors SessionSpawnPlanner.plan(for:)'s own gate)

    func test_sessionNewRemoteCommand_isAvailable_whenPersistentSessionsEnabled() throws {
        SessionSettings.persistentSessionsEnabled = true
        let controller = makeController()
        let newRemoteCommand = try command("session.newRemote", in: controller)

        XCTAssertTrue(newRemoteCommand.isAvailable(),
                      "session.newRemote must be offered once persistent sessions are enabled, mirroring " +
                      "SessionSpawnPlanner.plan(for:)'s own gate on this exact flag")
    }

    func test_sessionNewRemoteCommand_isUnavailable_whenPersistentSessionsDisabled() throws {
        SessionSettings.persistentSessionsEnabled = false
        let controller = makeController()
        let newRemoteCommand = try command("session.newRemote", in: controller)

        XCTAssertFalse(newRemoteCommand.isAvailable(),
                       "session.newRemote must not be offered while persistent sessions are disabled -- " +
                       "spawning ANY new persistent session, remote or local, is gated on this flag")
    }

    // MARK: - remoteSessionSpawnContext(forHost:) (R2 core contract)

    func test_remoteSessionSpawnContext_carriesGivenHost() {
        let controller = makeController()

        let context = controller.remoteSessionSpawnContext(forHost: "devbox.example.com")

        XCTAssertEqual(context.host, "devbox.example.com",
                       "Selecting a host must produce a SessionSpawnContext whose host carries exactly " +
                       "that value")
    }

    func test_remoteSessionSpawnContext_usesTabOrigin_matchingExistingSpawnTaxonomy() {
        let controller = makeController()

        let context = controller.remoteSessionSpawnContext(forHost: "devbox.example.com")

        XCTAssertEqual(context.origin, .tab,
                       "A remote session created via the palette is still a new TAB at the " +
                       "surface-creation level -- SessionSpawnOrigin has no dedicated palette-specific " +
                       "case, so .tab is the correct origin, matching every other new-tab spawn's own " +
                       "origin")
    }
}
