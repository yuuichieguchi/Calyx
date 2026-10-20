// TabGroup.swift
// Calyx
//
// A named group of tabs. ID-based selection for safety.

import Foundation

@MainActor @Observable
class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: TabGroupColor
    var isCollapsed: Bool
    var tabs: [Tab]
    var activeTabID: UUID?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init(
        id: UUID = UUID(),
        name: String = "Default",
        color: TabGroupColor = .blue,
        isCollapsed: Bool = false,
        tabs: [Tab] = [],
        activeTabID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    func addTab(_ tab: Tab) {
        tabs.append(tab)
        if activeTabID == nil {
            activeTabID = tab.id
        }
    }

    /// Inserts `tab` at `index`, clamped to `0...tabs.count`. Like
    /// `addTab(_:)`, it becomes the active tab only when the group has
    /// none.
    func insertTab(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        if activeTabID == nil {
            activeTabID = tab.id
        }
    }

    func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        tabs.remove(at: index)

        if activeTabID == id {
            activeTabID = successorTab(at: index)?.id
        }
    }

    func activeTabID(ifOnlyTabsRemain remainingTabIDs: Set<UUID>) -> UUID? {
        let remains: (Tab) -> Bool = { remainingTabIDs.contains($0.id) }
        guard let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return tabs.first(where: remains)?.id
        }
        return successorTab(at: activeIndex, where: remains)?.id
    }

    private func successorTab(at index: Int, where isCandidate: (Tab) -> Bool = { _ in true }) -> Tab? {
        tabs[index...].first(where: isCandidate) ?? tabs[..<index].last(where: isCandidate)
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              tabs.indices.contains(fromIndex),
              toIndex >= 0, toIndex < tabs.count else { return }

        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
    }

    /// Moves the tab at `fromIndex` by a relative `amount`, wrapping
    /// cyclically within the tab list rather than clamping at the ends --
    /// `GHOSTTY_ACTION_MOVE_TAB`'s intended receiver
    /// (`CalyxWindowController.processMoveTab(tab:group:amount:)`). Mirrors
    /// ghostty's own `move_tab` keybind semantics (`ghostty/src/input/
    /// Binding.zig`: "Positive values move the tab forwards, and negative
    /// values move it backwards. If the new position is out of bounds, it
    /// is wrapped around cyclically within the tab list.") and the GTK
    /// apprt's own reference implementation (`apprt/gtk/class/window.zig`'s
    /// `moveTab`). Deliberately NOT the same as macOS ghostty's own
    /// (`macos/Sources/Features/Terminal/TerminalController.swift`'s
    /// `onMoveTab`), which CLAMPS at the ends instead of wrapping -- that
    /// is a mismatch against `Binding.zig`'s own documented contract, not
    /// a precedent to follow.
    ///
    /// A no-op if `fromIndex` is out of range, or if the wrapped target
    /// index equals `fromIndex` (`amount == 0`, `amount` a multiple of
    /// `tabs.count`, or `tabs.count <= 1`).
    ///
    /// `count`/`fromIndex` are read BEFORE the wrap computation (not
    /// re-read from `tabs` after some partial mutation), so the
    /// `((fromIndex + amount) % count + count) % count` result is always
    /// computed against the pre-move array. The result is always a valid
    /// index into the sibling `moveTab(fromIndex:toIndex:)`'s `toIndex`
    /// (that method's own doc comment: "the tab's final position in the
    /// array after removal") — delegating to it here means `activeTabID`
    /// (ID-based) is preserved automatically, with no explicit
    /// reassignment needed, exactly like that method's own contract. See
    /// `TabGroupMoveTabTests` for the exhaustive contract this satisfies.
    func moveTab(fromIndex: Int, by amount: Int) {
        guard tabs.count > 1, amount != 0, tabs.indices.contains(fromIndex) else { return }
        let count = tabs.count
        let target = ((fromIndex + amount) % count + count) % count
        moveTab(fromIndex: fromIndex, toIndex: target)
    }

    /// The tab in this group whose `SurfaceRegistry` owns `surfaceID`, or
    /// `nil` if none of this group's tabs do.
    func tab(owningSurface surfaceID: UUID) -> Tab? {
        tabs.first { $0.registry.contains(surfaceID) }
    }
}

extension Array where Element == TabGroup {
    /// The tab (and its owning group) among these groups whose
    /// `SurfaceRegistry` owns `surfaceID`, or `nil` if none of them do.
    @MainActor
    func tabAndGroup(owningSurface surfaceID: UUID) -> (tab: Tab, group: TabGroup)? {
        for group in self {
            if let tab = group.tab(owningSurface: surfaceID) {
                return (tab, group)
            }
        }
        return nil
    }

    /// The tab with `tabID` (and its owning group) among these groups, or
    /// `nil` if none of them contains it.
    @MainActor
    func tabAndGroup(tabID: UUID) -> (tab: Tab, group: TabGroup)? {
        for group in self {
            if let tab = group.tabs.first(where: { $0.id == tabID }) {
                return (tab, group)
            }
        }
        return nil
    }
}
