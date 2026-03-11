// Tab.swift
// Calyx
//
// Represents a single terminal tab with its split layout.

import Foundation

enum TabContent: Sendable {
    case terminal
    case browser(url: URL)
    case diff(source: DiffSource)
}

@MainActor @Observable
class Tab: Identifiable {
    let id: UUID
    var title: String
    var pwd: String?
    var splitTree: SplitTree
    var content: TabContent
    var unreadNotifications: Int = 0
    let registry: SurfaceRegistry

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        content: TabContent = .terminal,
        registry: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.splitTree = splitTree
        self.content = content
        self.registry = registry
    }
}
