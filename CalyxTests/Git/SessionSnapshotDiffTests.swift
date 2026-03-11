// SessionSnapshotDiffTests.swift
// CalyxTests
//
// Tests that diff tabs are excluded from session snapshots and not restored.

import Foundation
import Testing
@testable import Calyx

@MainActor
struct SessionSnapshotDiffTests {
    @Test func diffTabExcludedFromSnapshot() {
        let terminalTab = Tab(title: "Terminal")
        let diffTab = Tab(title: "diff", content: .diff(source: .unstaged(path: "f.swift", workDir: "/tmp")))
        let group = TabGroup(name: "Test", tabs: [terminalTab, diffTab], activeTabID: terminalTab.id)

        let snapshot = group.snapshot()
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.tabs[0].id == terminalTab.id)
    }

    @Test func onlyDiffTabsYieldsEmptyList() {
        let diff1 = Tab(title: "d1", content: .diff(source: .staged(path: "a.swift", workDir: "/tmp")))
        let diff2 = Tab(title: "d2", content: .diff(source: .unstaged(path: "b.swift", workDir: "/tmp")))
        let group = TabGroup(name: "Test", tabs: [diff1, diff2], activeTabID: diff1.id)

        let snapshot = group.snapshot()
        #expect(snapshot.tabs.isEmpty)
    }

    @Test func terminalAndBrowserPreservedWithDiff() {
        let terminal = Tab(title: "Terminal")
        let browser = Tab(title: "Browser", content: .browser(url: URL(string: "https://example.com")!))
        let diff = Tab(title: "diff", content: .diff(source: .commit(hash: "abc", path: "f.swift", workDir: "/tmp")))
        let group = TabGroup(name: "Test", tabs: [terminal, browser, diff], activeTabID: terminal.id)

        let snapshot = group.snapshot()
        #expect(snapshot.tabs.count == 2)
    }

    @Test func restoredSessionHasNoDiffTabs() {
        let snapshot = TabGroupSnapshot(
            name: "Test",
            tabs: [TabSnapshot(title: "Terminal")],
            activeTabID: nil
        )
        let group = TabGroup(snapshot: snapshot)
        for tab in group.tabs {
            #expect(!tab.content.isDiff)
        }
    }
}
