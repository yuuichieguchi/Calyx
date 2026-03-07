// AppSession.swift
// Calyx
//
// Top-level runtime model for all windows.

import Foundation

@MainActor @Observable
class AppSession {
    var windows: [WindowSession]

    init(windows: [WindowSession] = []) {
        self.windows = windows
    }

    func addWindow(_ window: WindowSession) {
        windows.append(window)
    }

    func removeWindow(id: UUID) {
        windows.removeAll { $0.id == id }
    }
}
