// DiffContentTests.swift
// CalyxTests
//
// Tests for full-context git diff arguments and reconstruction of both file
// sides (DiffContent) from a single-hunk `-U2147483647` diff.

import Foundation
import Testing
@testable import Calyx

private func raw(_ lines: [String]) -> String {
    lines.joined(separator: "\n")
}

private let header = [
    "diff --git a/f.txt b/f.txt",
    "index 1111111..2222222 100644",
    "--- a/f.txt",
    "+++ b/f.txt",
]

struct DiffContentArgumentsTests {

    @Test func unstaged_arguments() {
        let args = GitService.fileDiffArguments(for: .unstaged(path: "src/a.swift", workDir: "/repo"))
        #expect(args == ["diff", "-U2147483647", "--", "src/a.swift"])
    }

    @Test func staged_arguments() {
        let args = GitService.fileDiffArguments(for: .staged(path: "src/a.swift", workDir: "/repo"))
        #expect(args == ["diff", "--cached", "-U2147483647", "--", "src/a.swift"])
    }

    @Test func commit_arguments() {
        let args = GitService.fileDiffArguments(for: .commit(hash: "abc123", path: "src/a.swift", workDir: "/repo"))
        #expect(args == ["show", "--format=", "--patch", "-U2147483647", "abc123", "--", "src/a.swift"])
    }

    @Test func contextFlag_precedesSeparatorAndHash() throws {
        let commit = try #require(GitService.fileDiffArguments(for: .commit(hash: "abc123", path: "p", workDir: "/r")))
        let u = try #require(commit.firstIndex(of: "-U2147483647"))
        #expect(u < commit.firstIndex(of: "--")!)
        #expect(u < commit.firstIndex(of: "abc123")!)

        let unstaged = try #require(GitService.fileDiffArguments(for: .unstaged(path: "p", workDir: "/r")))
        #expect(unstaged.firstIndex(of: "-U2147483647")! < unstaged.firstIndex(of: "--")!)
    }

    @Test func untracked_isNil() {
        #expect(GitService.fileDiffArguments(for: .untracked(path: "new.txt", workDir: "/repo")) == nil)
    }
}

struct DiffContentExtractTests {

    @Test func reconstructsBothSides() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,3 +1,4 @@",
            " a",
            "-b",
            "+x",
            "+y",
            " c",
        ]))
        #expect(content.oldLines == ["a", "b", "c"])
        #expect(content.newLines == ["a", "x", "y", "c"])
        #expect(content.isBinary == false)
        #expect(content.oldMissingTrailingNewline == false)
        #expect(content.newMissingTrailingNewline == false)
    }

    @Test func emptyContextLine_isEmptyStringOnBothSides() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,3 +1,3 @@",
            " a",
            " ",
            "-b",
            "+c",
        ]))
        #expect(content.oldLines == ["a", "", "b"])
        #expect(content.newLines == ["a", "", "c"])
    }

    @Test func newFile_oldSideEmpty() {
        let content = DiffContent.extract(from: raw([
            "@@ -0,0 +1,2 @@",
            "+a",
            "+b",
        ]))
        #expect(content.oldLines == [])
        #expect(content.newLines == ["a", "b"])
    }

    @Test func noNewlineMarker_oldSideOnly() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,2 +1,2 @@",
            " a",
            "-b",
            "\\ No newline at end of file",
            "+b",
        ]))
        #expect(content.oldLines == ["a", "b"])
        #expect(content.newLines == ["a", "b"])
        #expect(content.oldMissingTrailingNewline == true)
        #expect(content.newMissingTrailingNewline == false)
    }

    @Test func noNewlineMarker_newSideOnly() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,2 +1,2 @@",
            " a",
            "-b",
            "+b",
            "\\ No newline at end of file",
        ]))
        #expect(content.oldLines == ["a", "b"])
        #expect(content.newLines == ["a", "b"])
        #expect(content.oldMissingTrailingNewline == false)
        #expect(content.newMissingTrailingNewline == true)
    }

    @Test func noNewlineMarker_bothSidesOnChangedLines() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,2 +1,2 @@",
            " a",
            "-b",
            "\\ No newline at end of file",
            "+c",
            "\\ No newline at end of file",
        ]))
        #expect(content.oldLines == ["a", "b"])
        #expect(content.newLines == ["a", "c"])
        #expect(content.oldMissingTrailingNewline == true)
        #expect(content.newMissingTrailingNewline == true)
    }

    @Test func noNewlineMarker_afterContextLine_appliesToBothSides() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1,2 +1,2 @@",
            "-x",
            "+y",
            " b",
            "\\ No newline at end of file",
        ]))
        #expect(content.oldLines == ["x", "b"])
        #expect(content.newLines == ["y", "b"])
        #expect(content.oldMissingTrailingNewline == true)
        #expect(content.newMissingTrailingNewline == true)
    }

    @Test func binary_isDetected() {
        let content = DiffContent.extract(from: raw([
            "diff --git a/x.png b/x.png",
            "index 1111111..2222222 100644",
            "Binary files a/x.png and b/x.png differ",
        ]))
        #expect(content.isBinary == true)
        #expect(content.oldLines == [])
        #expect(content.newLines == [])
    }

    @Test func emptyInput_bothSidesEmpty() {
        let content = DiffContent.extract(from: "")
        #expect(content.oldLines == [])
        #expect(content.newLines == [])
        #expect(content.isBinary == false)
        #expect(content.oldMissingTrailingNewline == false)
        #expect(content.newMissingTrailingNewline == false)
    }

    @Test func crlfLines_stripTrailingCarriageReturn() {
        let content = DiffContent.extract(from: (header + [
            "@@ -1,3 +1,3 @@",
            " a\r",
            "-b\r",
            "+B\r",
            " c\r",
        ]).joined(separator: "\n") + "\n")
        #expect(content.oldLines == ["a", "b", "c"])
        #expect(content.newLines == ["a", "B", "c"])
    }

    @Test func doubleTrailingCarriageReturn_stripsOnlyOne() {
        let content = DiffContent.extract(from: raw(header + [
            "@@ -1 +1 @@",
            "-x\r\r",
            "+y\r",
        ]))
        #expect(content.oldLines == ["x\r"])
        #expect(content.newLines == ["y"])
    }
}

struct DiffContentLimitTests {

    @Test func maxFileSize_is50MB() {
        #expect(DiffComputationLimits.maxFileSizeBytes == 50 * 1024 * 1024)
    }

    @Test func exceedsMaxFileSize_boundary() {
        #expect(DiffContent.exceedsMaxFileSize(byteCount: 0) == false)
        #expect(DiffContent.exceedsMaxFileSize(byteCount: 52_428_800) == false)
        #expect(DiffContent.exceedsMaxFileSize(byteCount: 52_428_801) == true)
    }
}
