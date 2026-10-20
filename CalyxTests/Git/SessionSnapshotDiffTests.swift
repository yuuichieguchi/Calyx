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
        #expect(snapshot.activeTabID == nil)
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

    private func diffTab(_ path: String) -> Tab {
        Tab(title: path, content: .diff(source: .unstaged(path: path, workDir: "/tmp")))
    }

    private func browserTab(_ title: String) -> Tab {
        Tab(title: title, content: .browser(url: URL(string: "https://example.com")!))
    }

    @Test func activeDiffTabHandsActiveToFollowingPersistedTab() {
        let terminalA = Tab(title: "A")
        let diff = diffTab("d.swift")
        let terminalB = Tab(title: "B")
        let group = TabGroup(name: "Test", tabs: [terminalA, diff, terminalB], activeTabID: diff.id)

        #expect(group.snapshot().activeTabID == terminalB.id)
    }

    @Test func activeLastDiffTabHandsActiveToPrecedingPersistedTab() {
        let terminalA = Tab(title: "A")
        let terminalB = Tab(title: "B")
        let diff = diffTab("d.swift")
        let group = TabGroup(name: "Test", tabs: [terminalA, terminalB, diff], activeTabID: diff.id)

        #expect(group.snapshot().activeTabID == terminalB.id)
    }

    @Test func activeDiffTabSkipsDiffTabsAfterItToReachAPersistedTab() {
        let terminalA = Tab(title: "A")
        let diff1 = diffTab("d1.swift")
        let diff2 = diffTab("d2.swift")
        let diff3 = diffTab("d3.swift")
        let browserB = browserTab("B")
        let group = TabGroup(name: "Test", tabs: [terminalA, diff1, diff2, diff3, browserB], activeTabID: diff2.id)

        #expect(group.snapshot().activeTabID == browserB.id)
    }

    @Test func activeDiffTabWithOnlyDiffTabsAfterItFallsBackToPrecedingPersistedTab() {
        let terminalA = Tab(title: "A")
        let diff1 = diffTab("d1.swift")
        let diff2 = diffTab("d2.swift")
        let group = TabGroup(name: "Test", tabs: [terminalA, diff1, diff2], activeTabID: diff2.id)

        #expect(group.snapshot().activeTabID == terminalA.id)
    }

    @Test func activeFirstDiffTabSkipsDiffTabsToReachFollowingPersistedTab() {
        let diff1 = diffTab("d1.swift")
        let diff2 = diffTab("d2.swift")
        let terminalA = Tab(title: "A")
        let group = TabGroup(name: "Test", tabs: [diff1, diff2, terminalA], activeTabID: diff1.id)

        #expect(group.snapshot().activeTabID == terminalA.id)
    }

    @Test func persistedActiveTabStaysActiveAfterDiffTabs() {
        let terminalA = Tab(title: "A")
        let diff = diffTab("d.swift")
        let browserB = browserTab("B")
        let group = TabGroup(name: "Test", tabs: [terminalA, diff, browserB], activeTabID: browserB.id)

        #expect(group.snapshot().activeTabID == browserB.id)
    }

    @Test func activeTabIDNamingNoTabPersistsFirstPersistedTab() {
        let diff = diffTab("d.swift")
        let terminalA = Tab(title: "A")
        let terminalB = Tab(title: "B")
        let group = TabGroup(name: "Test", tabs: [diff, terminalA, terminalB], activeTabID: UUID())

        #expect(group.snapshot().activeTabID == terminalA.id)
    }

    @Test func noActiveTabPersistsFirstPersistedTab() {
        let terminalA = Tab(title: "A")
        let terminalB = Tab(title: "B")
        let group = TabGroup(name: "Test", tabs: [terminalA, terminalB], activeTabID: nil)

        #expect(group.snapshot().activeTabID == terminalA.id)
    }

    @Test func activeDiffTabAtSaveRestoresWithPrecedingTabActive() throws {
        let terminalA = Tab(title: "A")
        let diff = diffTab("d.swift")
        let group = TabGroup(name: "Test", tabs: [terminalA, diff], activeTabID: diff.id)

        let data = try JSONEncoder().encode(group.snapshot())
        let decoded = try JSONDecoder().decode(TabGroupSnapshot.self, from: data)
        let restored = TabGroup(snapshot: decoded)

        #expect(restored.activeTab?.id == terminalA.id)
    }
}
