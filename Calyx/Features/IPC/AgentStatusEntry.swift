// AgentStatusEntry.swift
// Calyx
//
// Models for AI agent activity state visualization in the Agents sidebar.

import Foundation

// MARK: - Agent Activity State

enum AgentActivityState: Sendable, Equatable {
    /// lastSeen within 30 seconds
    case active
    /// 30 seconds <= lastSeen < 5 minutes
    case idle
    /// lastSeen >= 5 minutes
    case stale
}

// MARK: - Agent Status Entry

struct AgentStatusEntry: Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let role: String
    let lastSeen: Date
    let inboxCount: Int
    /// True when this entry corresponds to the calyx-app peer (appPeerID).
    let isSelf: Bool
    let state: AgentActivityState
}

// MARK: - Agent Status Classifier

enum AgentStatusClassifier {
    /// Classifies an agent's activity state based on the elapsed time since `lastSeen`.
    ///
    /// - `elapsed < 30s`   → `.active`
    /// - `30s <= elapsed < 300s` (5 min)  → `.idle`
    /// - `elapsed >= 300s` → `.stale`
    static func classify(lastSeen: Date, now: Date) -> AgentActivityState {
        let elapsed = now.timeIntervalSince(lastSeen)
        if elapsed < 30.0 {
            return .active
        } else if elapsed < 300.0 {
            return .idle
        } else {
            return .stale
        }
    }
}
