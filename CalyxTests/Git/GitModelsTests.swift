// GitModelsTests.swift
// CalyxTests
//
// Tests for Git data models: GitFileEntry, CommitFileEntry, DiffSource, GitFileStatus.

import Testing
@testable import Calyx

struct GitModelsTests {
    @Test func gitFileEntryIDIsDeterministic() {
        let a = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let b = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        #expect(a.id == b.id)
    }

    @Test func gitFileEntryIDDistinguishesStagedState() {
        let staged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let unstaged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        #expect(staged.id != unstaged.id)
    }

    @Test func commitFileEntryIDIsDeterministic() {
        let a = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        let b = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        #expect(a.id == b.id)
    }

    @Test func diffSourceEquality() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/tmp")
        #expect(a != c)
    }

    @Test func allGitFileStatusRawValues() {
        #expect(GitFileStatus.modified.rawValue == "M")
        #expect(GitFileStatus.added.rawValue == "A")
        #expect(GitFileStatus.deleted.rawValue == "D")
        #expect(GitFileStatus.renamed.rawValue == "R")
        #expect(GitFileStatus.copied.rawValue == "C")
        #expect(GitFileStatus.untracked.rawValue == "?")
        #expect(GitFileStatus.unmerged.rawValue == "U")
        #expect(GitFileStatus.typeChanged.rawValue == "T")
    }
}
