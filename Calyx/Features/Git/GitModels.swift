// GitModels.swift
// Calyx
//
// Data models for git source control integration.

import Foundation

enum SidebarMode: Sendable {
    case tabs
    case changes
}

enum GitChangesState: Sendable {
    case notLoaded
    case notRepository
    case loading
    case loaded
    case error(String)
}

// MARK: - Git Status

enum GitFileStatus: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case unmerged = "U"
    case typeChanged = "T"
}

struct GitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(isStaged)-\(status.rawValue)-\(path)" }
    let path: String
    let origPath: String?
    let status: GitFileStatus
    let isStaged: Bool
    let renameScore: Int?
}

// MARK: - Commit Graph

struct GitCommit: Identifiable, Equatable, Sendable {
    let id: String              // full SHA
    let shortHash: String       // first 7 chars
    let message: String         // first line
    let author: String
    let relativeDate: String
    let parentIDs: [String]
    let graphPrefix: String     // git log --graph prefix string
}

struct CommitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(commitHash)-\(status.rawValue)-\(path)" }
    let commitHash: String
    let path: String
    let origPath: String?
    let status: GitFileStatus
}

// MARK: - Diff

enum DiffLineType: Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
    case meta
}

struct DiffLine: Equatable, Sendable {
    let type: DiffLineType
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct FileDiff: Equatable, Sendable {
    let path: String
    let lines: [DiffLine]
    let isBinary: Bool
    let isTruncated: Bool
}

enum DiffLoadState: Sendable {
    case loading
    case success(FileDiff)
    case error(String)
}

enum DiffSource: Sendable, Equatable {
    case unstaged(path: String, workDir: String)
    case staged(path: String, workDir: String)
    case commit(hash: String, path: String, workDir: String)
}
