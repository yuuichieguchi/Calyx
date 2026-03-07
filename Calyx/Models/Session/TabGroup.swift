// TabGroup.swift
// Calyx
//
// A named group of tabs. ID-based selection for safety.

import Foundation

@MainActor @Observable
class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: String?
    var tabs: [Tab]
    var activeTabID: UUID?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init(
        id: UUID = UUID(),
        name: String = "Default",
        color: String? = nil,
        tabs: [Tab] = [],
        activeTabID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    func addTab(_ tab: Tab) {
        tabs.append(tab)
        if activeTabID == nil {
            activeTabID = tab.id
        }
    }

    func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        tabs.remove(at: index)

        if activeTabID == id {
            if tabs.isEmpty {
                activeTabID = nil
            } else if index < tabs.count {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs[tabs.count - 1].id
            }
        }
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              tabs.indices.contains(fromIndex),
              toIndex >= 0, toIndex < tabs.count else { return }

        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex > fromIndex ? toIndex : toIndex)
    }
}
