// WindowSession.swift
// Calyx
//
// Represents a single window's state with tab groups.

import Foundation

@MainActor @Observable
class WindowSession: Identifiable {
    let id: UUID
    var groups: [TabGroup]
    var activeGroupID: UUID?

    var activeGroup: TabGroup? {
        groups.first { $0.id == activeGroupID }
    }

    init(
        id: UUID = UUID(),
        groups: [TabGroup] = [],
        activeGroupID: UUID? = nil
    ) {
        self.id = id
        self.groups = groups
        self.activeGroupID = activeGroupID
    }

    func addGroup(_ group: TabGroup) {
        groups.append(group)
        if activeGroupID == nil {
            activeGroupID = group.id
        }
    }

    func removeGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }

        groups.remove(at: index)

        if activeGroupID == id {
            if groups.isEmpty {
                activeGroupID = nil
            } else if index < groups.count {
                activeGroupID = groups[index].id
            } else {
                activeGroupID = groups[groups.count - 1].id
            }
        }
    }
}
