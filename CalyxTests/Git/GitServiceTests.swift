// GitServiceTests.swift
// CalyxTests
//
// Tests for GitService parsers: parseStatus, parseCommitLog, parseCommitFiles.

import Testing
@testable import Calyx

struct GitServiceTests {
    // MARK: - Status Parsing

    @Test func emptyStatus() {
        let result = GitService.parseStatus("")
        #expect(result.isEmpty)
    }

    @Test func ordinaryModified() {
        // "1 .M N... 100644 100644 100644 abc def path.swift"
        let output = "1 .M N... 100644 100644 100644 abc123 def456 src/file.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].path == "src/file.swift")
        #expect(result[0].status == .modified)
        #expect(!result[0].isStaged)
    }

    @Test func stagedAdded() {
        let output = "1 A. N... 000000 100644 100644 0000000 abc123 new.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .added)
        #expect(result[0].isStaged)
    }

    @Test func bothStagedAndUnstaged() {
        let output = "1 MM N... 100644 100644 100644 abc123 def456 both.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 2)
        let staged = result.filter { $0.isStaged }
        let unstaged = result.filter { !$0.isStaged }
        #expect(staged.count == 1)
        #expect(unstaged.count == 1)
    }

    @Test func untracked() {
        let output = "? untracked.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .untracked)
        #expect(!result[0].isStaged)
        #expect(result[0].path == "untracked.swift")
    }

    @Test func ignoredSkipped() {
        let output = "! ignored.swift"
        let result = GitService.parseStatus(output)
        #expect(result.isEmpty)
    }

    @Test func renamed() {
        let output = "2 R. N... 100644 100644 100644 abc123 def456 R100 new.swift\0old.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .renamed)
        #expect(result[0].isStaged)
        #expect(result[0].path == "new.swift")
        #expect(result[0].origPath == "old.swift")
        #expect(result[0].renameScore == 100)
    }

    @Test func copied() {
        let output = "2 C. N... 100644 100644 100644 abc123 def456 C075 copy.swift\0orig.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .copied)
        #expect(result[0].renameScore == 75)
    }

    @Test func unmerged() {
        let output = "u UU N... 100644 100644 100644 100644 abc123 def456 ghi789 conflict.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .unmerged)
    }

    @Test func typeChanged() {
        let output = "1 T. N... 120000 100644 100644 abc123 def456 link.txt"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .typeChanged)
        #expect(result[0].isStaged)
    }

    @Test func deletedStaged() {
        let output = "1 D. N... 100644 000000 000000 abc123 0000000 removed.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].status == .deleted)
        #expect(result[0].isStaged)
    }

    @Test func pathWithSpaces() {
        let output = "1 .M N... 100644 100644 100644 abc123 def456 path with spaces/file.swift"
        let result = GitService.parseStatus(output)
        #expect(result.count == 1)
        #expect(result[0].path == "path with spaces/file.swift")
    }

    @Test func multipleEntries() {
        let output = "1 .M N... 100644 100644 100644 abc def file1.swift\0? new.txt\0! ignored.txt"
        let result = GitService.parseStatus(output)
        #expect(result.count == 2) // modified + untracked, ignored skipped
    }

    // MARK: - Commit Log Parsing

    @Test func emptyCommitLog() {
        let result = GitService.parseCommitLog("")
        #expect(result.isEmpty)
    }

    @Test func singleCommit() {
        let output = "* \u{1f}abc1234567890\u{1f}abc1234\u{1f}Initial commit\u{1f}Author\u{1f}2 hours ago\u{1f}\u{1e}\n"
        let result = GitService.parseCommitLog(output)
        #expect(result.count == 1)
        #expect(result[0].shortHash == "abc1234")
        #expect(result[0].message == "Initial commit")
        #expect(result[0].author == "Author")
        #expect(result[0].parentIDs.isEmpty)
    }

    @Test func mergeCommit() {
        let output = "*   \u{1f}abc123\u{1f}abc1234\u{1f}Merge branch\u{1f}Author\u{1f}1 day ago\u{1f}parent1 parent2\u{1e}\n"
        let result = GitService.parseCommitLog(output)
        #expect(result.count == 1)
        #expect(result[0].parentIDs.count == 2)
    }

    @Test func commitWithParent() {
        let output = "* \u{1f}abc123\u{1f}abc1234\u{1f}Some change\u{1f}Dev\u{1f}3 hours ago\u{1f}def456\u{1e}\n"
        let result = GitService.parseCommitLog(output)
        #expect(result.count == 1)
        #expect(result[0].parentIDs == ["def456"])
    }

    // MARK: - Commit Files Parsing

    @Test func emptyCommitFiles() {
        let result = GitService.parseCommitFiles("", commitHash: "abc")
        #expect(result.isEmpty)
    }

    @Test func modifiedFile() {
        let output = "M\0src/file.swift\0"
        let result = GitService.parseCommitFiles(output, commitHash: "abc123")
        #expect(result.count == 1)
        #expect(result[0].status == .modified)
        #expect(result[0].path == "src/file.swift")
        #expect(result[0].commitHash == "abc123")
    }

    @Test func addedAndDeleted() {
        let output = "A\0new.swift\0D\0old.swift\0"
        let result = GitService.parseCommitFiles(output, commitHash: "abc")
        #expect(result.count == 2)
        #expect(result[0].status == .added)
        #expect(result[1].status == .deleted)
    }

    @Test func renamedFile() {
        let output = "R\0old.swift\0new.swift\0"
        let result = GitService.parseCommitFiles(output, commitHash: "abc")
        #expect(result.count == 1)
        #expect(result[0].status == .renamed)
        #expect(result[0].path == "new.swift")
        #expect(result[0].origPath == "old.swift")
    }
}
