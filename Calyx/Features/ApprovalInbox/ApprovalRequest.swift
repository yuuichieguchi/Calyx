// ApprovalRequest.swift
// Calyx
//
// Cockpit approval-core data model: a pending gated action (e.g. an MCP
// tool call) waiting on a human decision from the approval inbox. See
// ApprovalInboxStore for the queueing/decision lifecycle and
// ApprovalPolicy for whether a given action requires approval at all.

import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        case mcpTool(name: String)
    }

    let id: UUID
    let source: Source
    let targetSurfaceID: UUID?
    let payload: String
    let createdAt: Date
}

enum ApprovalDecision: Sendable, Equatable {
    case allowed
    case denied
    case expired
}
