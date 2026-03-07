// Tab.swift
// Calyx
//
// Represents a single terminal tab with its split layout.

import Foundation

enum TabContent: Sendable {
    case terminal
}

@MainActor @Observable
class Tab: Identifiable {
    let id: UUID
    var title: String
    var pwd: String?
    var splitTree: SplitTree
    var content: TabContent

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        content: TabContent = .terminal
    ) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.splitTree = splitTree
        self.content = content
    }
}
