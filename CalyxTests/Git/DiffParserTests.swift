// DiffParserTests.swift
// CalyxTests
//
// Tests for DiffParser: unified diff parsing, line numbering, binary detection, truncation.

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
        #expect(hunks.count == 1)
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

        // Find lines in hunk
        let hunkLines = result.lines.filter { $0.type != .hunkHeader && $0.type != .meta }

        // context: old=10, new=20
        let ctx1 = hunkLines[0]
        #expect(ctx1.type == .context)
        #expect(ctx1.oldLineNumber == 10)
        #expect(ctx1.newLineNumber == 20)

        // deletion: old=11
        let del = hunkLines[1]
        #expect(del.type == .deletion)
        #expect(del.oldLineNumber == 11)
        #expect(del.newLineNumber == nil)

        // addition: new=21
        let add1 = hunkLines[2]
        #expect(add1.type == .addition)
        #expect(add1.oldLineNumber == nil)
        #expect(add1.newLineNumber == 21)

        // addition: new=22
        let add2 = hunkLines[3]
        #expect(add2.type == .addition)
        #expect(add2.newLineNumber == 22)

        // context: old=12, new=23
        let ctx2 = hunkLines[4]
        #expect(ctx2.type == .context)
        #expect(ctx2.oldLineNumber == 12)
        #expect(ctx2.newLineNumber == 23)
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
        let result = DiffParser.parse(diff, path: "test")
        let hunks = result.lines.filter { $0.type == .hunkHeader }
        #expect(hunks.count == 2)
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
        let metas = result.lines.filter { $0.type == .meta }
        #expect(metas.count >= 4) // diff --git, new file mode, index, ---, +++
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
        let metas = result.lines.filter { $0.type == .meta }
        #expect(metas.contains { $0.text.hasPrefix("\\") })
    }

    @Test func truncatesLargeInput() {
        // Create a string larger than 1MB
        let line = String(repeating: "x", count: 1000) + "\n"
        let bigInput = String(repeating: line, count: 1100)
        #expect(bigInput.utf8.count > 1_000_000)

        let result = DiffParser.parse(bigInput, path: "big.txt")
        #expect(result.isTruncated)
    }

    @Test func truncatesManyLines() {
        // 50,001 lines
        var lines: [String] = ["@@ -1,50001 +1,50001 @@"]
        for i in 1...50001 {
            lines.append("+line \(i)")
        }
        let input = lines.joined(separator: "\n")
        let result = DiffParser.parse(input, path: "many.txt")
        #expect(result.isTruncated)
        #expect(result.lines.count <= 50001)
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
        let metas = result.lines.filter { $0.type == .meta }
        #expect(metas.contains { $0.text.hasPrefix("rename from") })
        #expect(metas.contains { $0.text.hasPrefix("rename to") })
    }
}
