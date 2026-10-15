// DiffLayoutCommandsTests.swift
// CalyxTests
//
// Command-palette entries for the diff layout (plan §5): registration,
// titles/category, availability (diff tab only), and handler effects on
// DiffLayoutSettings and the active tab's DiffRevealState.
// Helpers mirror DiffPreviewTabTests.

import Testing
import AppKit
import Foundation
@testable import Calyx

@MainActor
@Suite(.serialized)
struct DiffLayoutCommandsTests {

    private let source = DiffSource.unstaged(path: "Sources/Alpha.swift", workDir: "/nonexistent-repo")

    private static let expected: [(id: String, title: String)] = [
        ("diff.layout.automatic", "Diff View: Automatic"),
        ("diff.layout.inline", "Diff View: Inline"),
        ("diff.layout.sideBySide", "Diff View: Side by Side"),
        ("diff.layout.toggleInline", "Toggle Inline View"),
        ("diff.unchangedRegions.toggle", "Toggle Collapse Unchanged Regions"),
        ("diff.unchangedRegions.collapseAll", "Collapse All Unchanged Regions"),
        ("diff.unchangedRegions.showAll", "Show All Unchanged Regions"),
        ("diff.ignoreTrimWhitespace.toggle", "Toggle Ignore Trim Whitespace"),
    ]

    private func makeController() -> (CalyxWindowController, TabGroup) {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return (CalyxWindowController(window: window, windowSession: session, restoring: true), group)
    }

    /// Runs body with the three diff settings forced to known values, restoring the originals afterwards.
    private func withSettings(
        preference: DiffLayoutPreference = .automatic,
        hide: Bool = false,
        ignoreTrim: Bool = true,
        _ body: () throws -> Void
    ) rethrows {
        let savedPref = DiffLayoutSettings.preference
        let savedHide = DiffLayoutSettings.hideUnchangedRegionsEnabled
        let savedTrim = DiffLayoutSettings.ignoreTrimWhitespace
        DiffLayoutSettings.preference = preference
        DiffLayoutSettings.hideUnchangedRegionsEnabled = hide
        DiffLayoutSettings.ignoreTrimWhitespace = ignoreTrim
        defer {
            DiffLayoutSettings.preference = savedPref
            DiffLayoutSettings.hideUnchangedRegionsEnabled = savedHide
            DiffLayoutSettings.ignoreTrimWhitespace = savedTrim
        }
        try body()
    }

    private func command(_ id: String, in controller: CalyxWindowController) -> PaletteCommand? {
        controller.commandRegistry.allCommands.first { $0.id == id }
    }

    private func run(_ id: String, in controller: CalyxWindowController) throws {
        let cmd = try #require(command(id, in: controller), "command \(id) must be registered")
        cmd.handler()
    }

    // MARK: - Registration

    @Test func allEightCommands_registeredWithTitlesAndViewCategory() {
        let (controller, _) = makeController()
        for (id, title) in Self.expected {
            let cmd = command(id, in: controller)
            #expect(cmd != nil, "missing \(id)")
            #expect(cmd?.title == title)
            #expect(cmd?.category == "View")
        }
    }

    // MARK: - Availability

    @Test func terminalTab_allUnavailable_andIsDiffTabActiveFalse() {
        let (controller, _) = makeController()
        #expect(controller.isDiffTabActive == false)
        for (id, _) in Self.expected {
            #expect(command(id, in: controller)?.isAvailable() == false, "\(id) must be unavailable on a terminal tab")
        }
    }

    @Test func diffTab_allAvailable_andIsDiffTabActiveTrue() {
        let (controller, _) = makeController()
        controller.openDiffTab(source: source, pinned: true)
        #expect(controller.isDiffTabActive == true)
        for (id, _) in Self.expected {
            #expect(command(id, in: controller)?.isAvailable() == true, "\(id) must be available on a diff tab")
        }
    }

    @Test func activeDiffRevealState_nilOnTerminal_presentOnDiff() {
        let (controller, _) = makeController()
        #expect(controller.activeDiffRevealState == nil)
        controller.openDiffTab(source: source, pinned: true)
        #expect(controller.activeDiffRevealState != nil)
    }

    // MARK: - Layout handlers

    @Test func layoutInline_setsInline() throws {
        try withSettings(preference: .sideBySide) {
            let (controller, _) = makeController()
            try run("diff.layout.inline", in: controller)
            #expect(DiffLayoutSettings.preference == .inline)
        }
    }

    @Test func layoutSideBySide_setsSideBySide() throws {
        try withSettings(preference: .inline) {
            let (controller, _) = makeController()
            try run("diff.layout.sideBySide", in: controller)
            #expect(DiffLayoutSettings.preference == .sideBySide)
        }
    }

    @Test func layoutAutomatic_setsAutomatic() throws {
        try withSettings(preference: .inline) {
            let (controller, _) = makeController()
            try run("diff.layout.automatic", in: controller)
            #expect(DiffLayoutSettings.preference == .automatic)
        }
    }

    @Test func toggleInline_flipsBetweenInlineAndSideBySide() throws {
        try withSettings(preference: .sideBySide) {
            let (controller, _) = makeController()
            try run("diff.layout.toggleInline", in: controller)
            #expect(DiffLayoutSettings.preference == .inline)
            try run("diff.layout.toggleInline", in: controller)
            #expect(DiffLayoutSettings.preference == .sideBySide)
        }
    }

    @Test func toggleInline_fromAutomatic_goesInline() throws {
        // Plan §3: automatic counts as side-by-side for toggledInline.
        try withSettings(preference: .automatic) {
            let (controller, _) = makeController()
            try run("diff.layout.toggleInline", in: controller)
            #expect(DiffLayoutSettings.preference == .inline)
        }
    }

    // MARK: - Bool toggles

    @Test func unchangedRegionsToggle_flips() throws {
        try withSettings(hide: false) {
            let (controller, _) = makeController()
            try run("diff.unchangedRegions.toggle", in: controller)
            #expect(DiffLayoutSettings.hideUnchangedRegionsEnabled == true)
            try run("diff.unchangedRegions.toggle", in: controller)
            #expect(DiffLayoutSettings.hideUnchangedRegionsEnabled == false)
        }
    }

    @Test func ignoreTrimWhitespaceToggle_flips() throws {
        try withSettings(ignoreTrim: true) {
            let (controller, _) = makeController()
            try run("diff.ignoreTrimWhitespace.toggle", in: controller)
            #expect(DiffLayoutSettings.ignoreTrimWhitespace == false)
            try run("diff.ignoreTrimWhitespace.toggle", in: controller)
            #expect(DiffLayoutSettings.ignoreTrimWhitespace == true)
        }
    }

    // MARK: - Reveal state handlers

    @Test func showAll_thenCollapseAll_actOnActiveRevealState() throws {
        let (controller, _) = makeController()
        controller.openDiffTab(source: source, pinned: true)
        let state = try #require(controller.activeDiffRevealState)

        try run("diff.unchangedRegions.showAll", in: controller)
        #expect(state.isAllRevealed == true)

        try run("diff.unchangedRegions.collapseAll", in: controller)
        #expect(state.isAllRevealed == false)

        try run("diff.unchangedRegions.showAll", in: controller)
        #expect(state.isAllRevealed == true)
    }

    @Test func revealCommands_doNotChangeHideSetting() throws {
        try withSettings(hide: true) {
            let (controller, _) = makeController()
            controller.openDiffTab(source: source, pinned: true)
            try run("diff.unchangedRegions.showAll", in: controller)
            try run("diff.unchangedRegions.collapseAll", in: controller)
            #expect(DiffLayoutSettings.hideUnchangedRegionsEnabled == true)
        }
    }
}
