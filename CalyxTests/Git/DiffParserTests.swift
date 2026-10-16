// DiffParserTests.swift
// CalyxTests
//
// Tests for DiffParser: full-context unified diff -> FileDiff via DiffContent,
// DefaultLinesDiffComputer and DiffLineGenerator (line numbering, binary
// detection; hunk headers / meta rows are no longer emitted).

import Testing
@testable import Calyx

struct DiffParserTests {
    @Test func emptyDiff() {
        let result = DiffParser.parse("", path: "test.swift")
        #expect(result.lines.isEmpty)
        #expect(!result.isBinary)
        #expect(!result.isTruncated)
        #expect(result.path == "test.swift")
    }

    @Test func basicUnifiedDiff() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         context line
        -deleted line
        +added line
        +another added
         more context
        """
        let result = DiffParser.parse(diff, path: "file.swift")
        #expect(!result.isBinary)

        let additions = result.lines.filter { $0.type == .addition }
        let deletions = result.lines.filter { $0.type == .deletion }
        let contexts = result.lines.filter { $0.type == .context }
        let hunks = result.lines.filter { $0.type == .hunkHeader }

        #expect(additions.count == 2)
        #expect(deletions.count == 1)
        #expect(contexts.count == 2)
        #expect(hunks.isEmpty)
        #expect(result.changes.count == 1)
        #expect(result.oldLineCount == 3)
        #expect(result.newLineCount == 4)
    }

    @Test func lineNumbersIncrement() {
        let diff = """
        @@ -10,4 +20,5 @@
         context
        -old
        +new1
        +new2
         end
        """
        let result = DiffParser.parse(diff, path: "test")

        // The hunk is the whole file (full-context diff), so numbering starts at 1;
        // the hunk header's start offsets are not used.
        let hunkLines = result.lines
        #expect(hunkLines.count == 5)

        // context: old=1, new=1
        let ctx1 = hunkLines[0]
        #expect(ctx1.type == .context)
        #expect(ctx1.oldLineNumber == 1)
        #expect(ctx1.newLineNumber == 1)

        // deletion: old=2
        let del = hunkLines[1]
        #expect(del.type == .deletion)
        #expect(del.oldLineNumber == 2)
        #expect(del.newLineNumber == nil)

        // addition: new=2
        let add1 = hunkLines[2]
        #expect(add1.type == .addition)
        #expect(add1.oldLineNumber == nil)
        #expect(add1.newLineNumber == 2)

        // addition: new=3
        let add2 = hunkLines[3]
        #expect(add2.type == .addition)
        #expect(add2.newLineNumber == 3)

        // context: old=3, new=4
        let ctx2 = hunkLines[4]
        #expect(ctx2.type == .context)
        #expect(ctx2.oldLineNumber == 3)
        #expect(ctx2.newLineNumber == 4)
    }

    @Test func multipleHunks() {
        let diff = """
        @@ -1,2 +1,2 @@
         a
        -b
        +c
        @@ -10,2 +10,2 @@
         x
        -y
        +z
        """
        // Full-context diffs have a single hunk; extra hunks are concatenated.
        let result = DiffParser.parse(diff, path: "test")
        let hunks = result.lines.filter { $0.type == .hunkHeader }
        #expect(hunks.isEmpty)
        #expect(result.oldLineCount == 4)
        #expect(result.newLineCount == 4)
    }

    @Test func headerLines() {
        let diff = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,1 @@
        +hello
        """
        let result = DiffParser.parse(diff, path: "new.swift")
        // Header lines are skipped; only the file content becomes rows.
        #expect(!result.lines.contains { $0.type == .meta || $0.type == .hunkHeader })
        #expect(result.lines == [DiffLine(type: .addition, text: "+hello", oldLineNumber: nil, newLineNumber: 1)])
        #expect(result.oldLineCount == 0)
        #expect(result.newLineCount == 1)
    }

    @Test func binaryFilesDiffer() {
        let diff = "Binary files a/image.png and b/image.png differ"
        let result = DiffParser.parse(diff, path: "image.png")
        #expect(result.isBinary)
    }

    @Test func gitBinaryPatch() {
        let diff = "GIT binary patch\nliteral 1234\ndata..."
        let result = DiffParser.parse(diff, path: "binary.dat")
        #expect(result.isBinary)
    }

    @Test func noNewlineAtEndOfFile() {
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let result = DiffParser.parse(diff, path: "test")
        // The marker is not file content and produces no row.
        #expect(!result.lines.contains { $0.type == .meta })
        #expect(!result.lines.contains { $0.text.hasPrefix("\\") })
        #expect(result.lines.map(\.text) == ["-old", "+new"])
    }

    @Test func largeInputIsNotTruncated() {
        // The 1 MB / 50,000-line truncation is gone; size limits live in the loader.
        let line = String(repeating: "x", count: 1000)
        var lines: [String] = ["@@ -0,0 +1,1100 @@"]
        lines.append(contentsOf: Array(repeating: "+" + line, count: 1100))
        let bigInput = lines.joined(separator: "\n")
        #expect(bigInput.utf8.count > 1_000_000)

        let result = DiffParser.parse(bigInput, path: "big.txt")
        #expect(!result.isTruncated)
        #expect(result.lines.count == 1100)
    }

    @Test func trailingNewlineOfGitOutput_isNotALine() {
        let result = DiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new\n", path: "test")
        #expect(result.lines.map(\.text) == ["-old", "+new"])
        #expect(result.oldLineCount == 1)
        #expect(result.newLineCount == 1)
    }

    @Test func newFileWithSingleBlankLine_isOneAddition() {
        // The diff computer treats [] like [""]; DiffParser restores the change.
        let result = DiffParser.parse("@@ -0,0 +1 @@\n+\n", path: "f")
        #expect(result.lines == [DiffLine(type: .addition, text: "+", oldLineNumber: nil, newLineNumber: 1)])
        #expect(result.changes.count == 1)
        #expect(result.oldLineCount == 0)
        #expect(result.newLineCount == 1)
    }

    @Test func renameDiff() {
        let diff = """
        diff --git a/old.swift b/new.swift
        similarity index 95%
        rename from old.swift
        rename to new.swift
        index abc..def 100644
        --- a/old.swift
        +++ b/new.swift
        @@ -1,1 +1,1 @@
        -old content
        +new content
        """
        let result = DiffParser.parse(diff, path: "new.swift")
        // Rename headers are skipped; the content change is diffed.
        #expect(!result.lines.contains { $0.type == .meta })
        #expect(result.lines.map(\.text) == ["-old content", "+new content"])
    }
}
