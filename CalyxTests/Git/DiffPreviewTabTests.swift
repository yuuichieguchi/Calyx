// DiffPreviewTabTests.swift
// CalyxTests
//
// Issue #51: VS Code-style preview tab for diffs opened from the Changes view.

import Testing
import AppKit
import Foundation
@testable import Calyx

@MainActor
struct DiffPreviewTabTests {
    private static let settingKey = "gitDiffPreviewTabEnabled"

    private let sourceA = DiffSource.unstaged(path: "Sources/Alpha.swift", workDir: "/nonexistent-repo")
    private let sourceB = DiffSource.unstaged(path: "Sources/Beta.swift", workDir: "/nonexistent-repo")

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

    /// Runs body with the setting forced to `enabled` (nil = key removed), restoring afterwards.
    private func withSetting(_ enabled: Bool?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Self.settingKey)
        if let enabled { defaults.set(enabled, forKey: Self.settingKey) } else { defaults.removeObject(forKey: Self.settingKey) }
        defer {
            if let saved { defaults.set(saved, forKey: Self.settingKey) } else { defaults.removeObject(forKey: Self.settingKey) }
        }
        try body()
    }

    private func diffTabs(_ group: TabGroup) -> [Tab] {
        group.tabs.filter { if case .diff = $0.content { return true } else { return false } }
    }

    private func source(of tab: Tab) -> DiffSource? {
        if case .diff(let s) = tab.content { return s }
        return nil
    }

    // MARK: - Model

    @Test func tabIsPreviewDefaultsToFalse() {
        #expect(Tab(title: "x").isPreview == false)
        #expect(Tab(title: "Alpha.swift", content: .diff(source: sourceA)).isPreview == false)
    }

    // MARK: - Setting OFF

    @Test func settingOff_twoSources_createTwoNonPreviewTabs() {
        withSetting(false) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            controller.openDiffTab(source: sourceB)
            let tabs = diffTabs(group)
            #expect(tabs.count == 2)
            #expect(group.tabs.count == 3)
            #expect(tabs.allSatisfy { !$0.isPreview })
        }
    }

    // MARK: - Setting ON

    @Test func defaultSetting_isOn_whenKeyAbsent() {
        withSetting(nil) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            controller.openDiffTab(source: sourceB)
            #expect(diffTabs(group).count == 1)
            #expect(diffTabs(group).first?.isPreview == true)
        }
    }

    @Test func settingOn_AthenB_reusesSinglePreviewTab() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let first = diffTabs(group)
            #expect(first.count == 1)
            #expect(first.first?.isPreview == true)
            let firstID = first.first?.id

            controller.openDiffTab(source: sourceB)
            let tabs = diffTabs(group)
            #expect(tabs.count == 1)
            #expect(group.tabs.count == 2)
            #expect(tabs.first?.id == firstID)
            #expect(tabs.first?.isPreview == true)
            #expect(tabs.first.flatMap(source(of:)) == sourceB)
            #expect(tabs.first?.title == "Beta.swift")
            #expect(group.activeTabID == firstID)
        }
    }

    @Test func settingOn_sameSourceTwice_dedups() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let id = diffTabs(group).first?.id
            controller.openDiffTab(source: sourceA)
            let tabs = diffTabs(group)
            #expect(tabs.count == 1)
            #expect(tabs.first?.id == id)
            #expect(tabs.first?.isPreview == true)
            #expect(tabs.first.flatMap(source(of:)) == sourceA)
            #expect(tabs.first?.title == "Alpha.swift")
            #expect(group.activeTabID == id)
        }
    }

    @Test func settingOn_keepTabOpen_thenNewSourceOpensSecondPreview() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let tabA = diffTabs(group)[0]
            controller.keepTabOpen(id: tabA.id)
            #expect(tabA.isPreview == false)

            controller.openDiffTab(source: sourceB)
            let tabs = diffTabs(group)
            #expect(tabs.count == 2)
            #expect(source(of: tabA) == sourceA)
            #expect(tabA.isPreview == false)
            let tabB = tabs.first { $0.id != tabA.id }
            #expect(tabB.flatMap(source(of:)) == sourceB)
            #expect(tabB?.isPreview == true)
            #expect(group.activeTabID == tabB?.id)
        }
    }

    @Test func settingOn_pinnedOnFreshGroup_createsNonPreviewTab() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA, pinned: true)
            let tabs = diffTabs(group)
            #expect(tabs.count == 1)
            #expect(tabs.first?.isPreview == false)
            #expect(tabs.first.flatMap(source(of:)) == sourceA)
        }
    }

    @Test func settingOn_pinnedWithExistingPreview_reusesAndPromotes() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let previewID = diffTabs(group)[0].id
            controller.openDiffTab(source: sourceB, pinned: true)
            let tabs = diffTabs(group)
            #expect(tabs.count == 1)
            #expect(tabs.first?.id == previewID)
            #expect(tabs.first.flatMap(source(of:)) == sourceB)
            #expect(tabs.first?.title == "Beta.swift")
            #expect(tabs.first?.isPreview == false)
            #expect(group.activeTabID == previewID)

            // No preview left, so the next single-click opens a new preview tab.
            let sourceC = DiffSource.staged(path: "Gamma.swift", workDir: "/nonexistent-repo")
            controller.openDiffTab(source: sourceC)
            #expect(diffTabs(group).count == 2)
            #expect(diffTabs(group).filter(\.isPreview).count == 1)
        }
    }

    @Test func settingOn_pinnedOnAlreadyOpenPreviewSource_promotesViaDedup() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let id = diffTabs(group).first?.id
            #expect(diffTabs(group).first?.isPreview == true)
            controller.openDiffTab(source: sourceA, pinned: true)
            let tabs = diffTabs(group)
            #expect(tabs.count == 1)
            #expect(tabs.first?.id == id)
            #expect(tabs.first?.isPreview == false)
            #expect(group.activeTabID == id)
        }
    }

    @Test func settingOn_atMostOnePreviewPerGroup() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            controller.openDiffTab(source: sourceB)
            controller.openDiffTab(source: .untracked(path: "New.txt", workDir: "/nonexistent-repo"))
            #expect(diffTabs(group).filter(\.isPreview).count == 1)
            #expect(diffTabs(group).count == 1)
        }
    }

    @Test func settingOn_addingCommentPromotesPreview() throws {
        try withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let tabA = diffTabs(group)[0]
            let store = try #require(controller._reviewStoresForTesting[tabA.id])
            store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "note")
            #expect(tabA.isPreview == false)

            controller.openDiffTab(source: sourceB)
            #expect(diffTabs(group).count == 2)
            #expect(source(of: tabA) == sourceA)
        }
    }

    @Test func settingOn_reusingPreviewResetsStateAndReviewStore() throws {
        try withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            let tabID = diffTabs(group)[0].id
            let oldStore = try #require(controller._reviewStoresForTesting[tabID])

            controller.openDiffTab(source: sourceB)
            let newStore = try #require(controller._reviewStoresForTesting[tabID])
            #expect(newStore !== oldStore)
            #expect(newStore.comments.isEmpty)
            if case .loading = controller._diffStatesForTesting[tabID] {} else {
                Issue.record("Expected diffStates[tabID] == .loading after preview reuse")
            }
        }
    }

    @Test func keepTabOpen_unknownID_isNoOp() {
        withSetting(true) {
            let (controller, group) = makeController()
            controller.openDiffTab(source: sourceA)
            controller.keepTabOpen(id: UUID())
            #expect(diffTabs(group).first?.isPreview == true)
        }
    }

    // MARK: - Command palette

    @Test func commandRegistry_registersKeepOpen() {
        let (controller, _) = makeController()
        #expect(controller.commandRegistry.allCommands.contains { $0.id == "tab.keepOpen" })
    }
}
