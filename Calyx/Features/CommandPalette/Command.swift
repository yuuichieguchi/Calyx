// Command.swift
// Calyx
//
// A single command that can appear in the command palette.

import Foundation

struct Command: Identifiable, Sendable {
    let id: String
    let title: String
    let shortcut: String?
    let category: String
    let isAvailable: @MainActor @Sendable () -> Bool
    let handler: @MainActor @Sendable () -> Void

    init(
        id: String,
        title: String,
        shortcut: String? = nil,
        category: String = "General",
        isAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.category = category
        self.isAvailable = isAvailable
        self.handler = handler
    }
}
