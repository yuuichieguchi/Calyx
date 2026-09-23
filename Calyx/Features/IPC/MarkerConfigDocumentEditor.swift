// MarkerConfigDocumentEditor.swift
// Calyx
//
// Replaces the single BEGIN/END marker block Calyx owns inside an
// otherwise user-owned text document (HermesConfigManager's YAML,
// CodexHooksConfigManager's TOML, OpenCodeConfigManager's AGENTS.md).
// Operates entirely on bytes, never on Swift `String`/`Character`, since a
// CRLF pair collapses into a single `Character` and would make a
// `String`-based `hasSuffix("\n")`/`hasSuffix("\n\n")` check silently
// wrong against CRLF content.

import Foundation

/// Thrown by `MarkerConfigDocumentEditor.childIndentUnit(afterLine:in:)`
/// when the mapping being spliced into is tab-indented -- a manager
/// translates this into its own domain error.
enum MarkerConfigDocumentEditorError: Error, Sendable {
    case tabIndentation
}

struct MarkerConfigDocumentEditor: Sendable {
    let beginLine: String
    let endLine: String

    /// Bounds the orphan-BEGIN self-heal scan (`removeBlock`'s second
    /// pass): whether `doc.lines[index]` still looks like part of
    /// Calyx's own generated block body. The scan starts right after an
    /// orphan BEGIN (no matching END anywhere in the document) and stops
    /// at the first line this returns false for; the BEGIN line itself
    /// is always removed regardless. `nil` disables orphan self-heal
    /// entirely (an orphan BEGIN, or an orphan END with no matching
    /// BEGIN, is left untouched).
    var isOwnBodyLine: (@Sendable (LineDoc, Int) -> Bool)?

    /// Extracts the bytes to preserve from a block's body line range (a
    /// well-formed BEGIN...END span, or a self-healed orphan's bounded
    /// body) that are NOT Calyx's own generated content -- a user's own
    /// entry that ended up inside Calyx's owned span. `nil`, or an empty
    /// result, discards the whole body once Calyx's own portion has been
    /// identified. Written back in place of the removed block (not
    /// appended at EOF): a format where position is meaningful (a YAML
    /// mapping's nested child) would become invalid if its preserved
    /// content moved to end of file; a position-independent format (a
    /// TOML table) is unaffected either way.
    var foreignBodyBytes: (@Sendable (LineDoc, Range<Int>) -> [UInt8])?

    init(
        beginLine: String,
        endLine: String,
        isOwnBodyLine: (@Sendable (LineDoc, Int) -> Bool)? = nil,
        foreignBodyBytes: (@Sendable (LineDoc, Range<Int>) -> [UInt8])? = nil
    ) {
        self.beginLine = beginLine
        self.endLine = endLine
        self.isOwnBodyLine = isOwnBodyLine
        self.foreignBodyBytes = foreignBodyBytes
    }

    /// Learns the indent unit (in spaces) of the block-style mapping
    /// `headerLine` introduces: the indent of the first non-blank line
    /// after it whose indent is greater than 0. Defaults to 2 when the
    /// mapping has no children (EOF, or the very next non-blank line is
    /// already back at indent 0). Throws `.tabIndentation` if a
    /// tab-indented line is encountered before that point -- splicing a
    /// child in beneath tab-indented content isn't safe.
    func childIndentUnit(afterLine headerLine: Int, in doc: LineDoc) throws -> Int {
        for i in (headerLine + 1)..<doc.lines.count {
            let raw = doc.lineBytes(doc.lines[i])
            if raw.isEmpty { continue }
            if raw.first == UInt8(ascii: "\t") { throw MarkerConfigDocumentEditorError.tabIndentation }
            let indent = doc.leadingSpaceCount(doc.lines[i])
            if indent == 0 { return 2 }
            return indent
        }
        return 2
    }

    /// Inserts `body` (plain `\n`-separated lines, BEGIN/END markers not
    /// included) as a new child of `headerLine`'s block-style mapping,
    /// right before that mapping's end (its first subsequent non-blank
    /// line at indent 0, or EOF). Every inserted line -- the markers and
    /// each body line -- is prefixed with `unit` spaces and terminated
    /// with the document's own detected EOL. A body line's own `\r`
    /// suffix (a CRLF-authored body string) is stripped first so it's
    /// never doubled against a CRLF target EOL.
    func insertBlock(body: String, asChildOfLine headerLine: Int, unit: Int, in current: Data?) -> Data {
        let bytes = current.map { Array($0) } ?? []
        let doc = LineDoc(bytes: bytes)
        let eol = doc.detectEOL()
        let indent = Array(String(repeating: " ", count: unit).utf8)

        var insertAt = doc.lines.count
        for i in (headerLine + 1)..<doc.lines.count {
            if doc.lineBytes(doc.lines[i]).isEmpty { continue }
            if doc.leadingSpaceCount(doc.lines[i]) == 0 {
                insertAt = i
                break
            }
        }
        // The mapping's own region ends at its last non-blank line -- any
        // blank line(s) right before `insertAt` are the user's own
        // separator ahead of the next top-level key, not part of this
        // mapping, so the block must land before them, not after.
        while insertAt > headerLine + 1, doc.lineBytes(doc.lines[insertAt - 1]).isEmpty {
            insertAt -= 1
        }

        var result = doc.rawBytes(forLines: 0..<insertAt)
        if insertAt > 0, result.last != UInt8(ascii: "\n") {
            result.append(contentsOf: eol)
        }
        result.append(contentsOf: blockBytes(body: body, eol: eol, indent: indent))
        result.append(contentsOf: doc.rawBytes(forLines: insertAt..<doc.lines.count))
        return Data(result)
    }

    /// Replaces the first well-formed BEGIN...END occurrence in place,
    /// leaving whatever separator already precedes it untouched, and
    /// removes every further occurrence together with the one blank line
    /// immediately before it, if any. Appends at EOF, preceded by one
    /// blank separator line, when no occurrence exists and `current` is
    /// non-empty; no separator at all when `current` is empty or absent.
    func setBlock(body: String, in current: Data?) throws -> Data {
        let bytes = current.map { Array($0) } ?? []
        let doc = LineDoc(bytes: bytes)
        let blocks = doc.findBlocks(beginLine: beginLine, endLine: endLine)
        let eol = doc.detectEOL()

        var result = bytes
        if !blocks.isEmpty {
            for (i, block) in blocks.enumerated().reversed() {
                if i == 0 {
                    // The in-place replacement must keep the existing
                    // BEGIN line's own indentation -- a block nested inside
                    // a mapping (e.g. Hermes's Case B child block) would
                    // otherwise be flattened to column 0 and corrupt the
                    // structure it's nested in.
                    let indentCount = doc.leadingSpaceCount(doc.lines[block.beginLineIndex])
                    let indent = Array(String(repeating: " ", count: indentCount).utf8)
                    let range = doc.blockRange(startLine: block.beginLineIndex, endLine: block.endLineIndex)
                    result.replaceSubrange(range, with: blockBytes(body: body, eol: eol, indent: indent))
                } else {
                    let range = doc.removalRange(startLine: block.beginLineIndex, endLine: block.endLineIndex)
                    result.removeSubrange(range)
                }
            }
        } else if result.isEmpty {
            result = blockBytes(body: body, eol: eol, indent: [])
        } else {
            // The last byte of any EOL (LF or CRLF) is always `\n`; that
            // single-byte check is EOL-style-agnostic even when the file
            // mixes line endings and the very last line used a different
            // style than `detectEOL()`'s first-found style.
            if result.last != UInt8(ascii: "\n") {
                result.append(contentsOf: eol)
            }
            result.append(contentsOf: eol)
            result.append(contentsOf: blockBytes(body: body, eol: eol, indent: []))
        }
        return Data(result)
    }

    /// Removes every well-formed BEGIN...END occurrence. Each is either
    /// deleted together with the one blank line immediately before it (no
    /// foreign content to keep), or -- when `foreignBodyBytes` finds
    /// content inside its span that isn't Calyx's own -- replaced in
    /// place by exactly that preserved content, so a user's own entry
    /// that ended up inside Calyx's owned span survives at the same
    /// position rather than being discarded.
    ///
    /// Then self-heals, when `isOwnBodyLine` is configured: any orphan
    /// BEGIN (no matching END anywhere in the document) the same way,
    /// bounding its body to the longest run of lines after it that still
    /// look like Calyx's own content; and any orphan END left over with
    /// no matching BEGIN (e.g. from a version that only stripped a
    /// malformed BEGIN), removed on its own. An orphan is Calyx's own
    /// marker regardless of what turned out to be between it and its
    /// pair, so this never requires the caller to hand-edit the file
    /// before Calyx can proceed.
    ///
    /// This editor edits files Calyx does not own outright, so it never
    /// signals deletion: absent input stays `nil`, and a document emptied
    /// by the removal is returned as empty `Data()`, leaving the file in
    /// place, empty.
    func removeBlock(in current: Data?) throws -> Data? {
        guard let current, !current.isEmpty else { return current }
        var bytes = Array(current)

        let doc = LineDoc(bytes: bytes)
        let blocks = doc.findBlocks(beginLine: beginLine, endLine: endLine)
        for block in blocks.reversed() {
            let bodyRange = (block.beginLineIndex + 1)..<block.endLineIndex
            let foreign = foreignBodyBytes?(doc, bodyRange) ?? []
            if foreign.isEmpty {
                let range = doc.removalRange(startLine: block.beginLineIndex, endLine: block.endLineIndex)
                bytes.removeSubrange(range)
            } else {
                let range = doc.blockRange(startLine: block.beginLineIndex, endLine: block.endLineIndex)
                bytes.replaceSubrange(range, with: foreign)
            }
        }

        if let isOwnBodyLine {
            let beginBytes = Array(beginLine.utf8)
            while true {
                let scanDoc = LineDoc(bytes: bytes)
                guard let beginIndex = scanDoc.lines.indices.first(
                    where: { scanDoc.trimmedLineBytes(scanDoc.lines[$0]) == beginBytes }
                ) else { break }

                var lastRecognized = beginIndex
                var scan = beginIndex + 1
                while scan < scanDoc.lines.count, isOwnBodyLine(scanDoc, scan) {
                    lastRecognized = scan
                    scan += 1
                }
                let bodyRange = (beginIndex + 1)..<(lastRecognized + 1)
                let foreign = foreignBodyBytes?(scanDoc, bodyRange) ?? []
                if foreign.isEmpty {
                    let removal = scanDoc.removalRange(startLine: beginIndex, endLine: lastRecognized)
                    bytes.removeSubrange(removal)
                } else {
                    let range = scanDoc.blockRange(startLine: beginIndex, endLine: lastRecognized)
                    bytes.replaceSubrange(range, with: foreign)
                }
            }

            let endBytes = Array(endLine.utf8)
            while true {
                let scanDoc = LineDoc(bytes: bytes)
                guard let endIndex = scanDoc.lines.indices.first(
                    where: { scanDoc.trimmedLineBytes(scanDoc.lines[$0]) == endBytes }
                ) else { break }
                let removal = scanDoc.removalRange(startLine: endIndex, endLine: endIndex)
                bytes.removeSubrange(removal)
            }
        }

        return Data(bytes)
    }

    /// Whether Calyx owns any region in `current`: a well-formed
    /// BEGIN...END pair, or (when self-heal is wired up via
    /// `isOwnBodyLine`) an orphan BEGIN or orphan END on its own -- the
    /// same set of things `removeBlock` always changes the document for,
    /// so a read-only "is this installed" predicate built on this never
    /// disagrees with what `removeBlock` would actually do.
    func containsBlock(in current: Data?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        let doc = LineDoc(bytes: Array(current))
        if !doc.findBlocks(beginLine: beginLine, endLine: endLine).isEmpty { return true }
        guard isOwnBodyLine != nil else { return false }
        let beginBytes = Array(beginLine.utf8)
        let endBytes = Array(endLine.utf8)
        return doc.lines.contains {
            doc.trimmedLineBytes($0) == beginBytes || doc.trimmedLineBytes($0) == endBytes
        }
    }

    /// Builds a complete BEGIN...END span -- `indent` prefixed to every
    /// line, `beginLine` and `endLine` included -- shared by `insertBlock`
    /// (a child-mapping `indent`) and `setBlock` (an existing block's own
    /// indent when replacing in place, or no indent at all when appending
    /// at EOF). `body` arrives with plain `\n` separators; each line is
    /// terminated with `eol`. A `\r` suffix on a body line (a
    /// CRLF-authored body string) is stripped first so it is never doubled
    /// against a CRLF target EOL.
    private func blockBytes(body: String, eol: [UInt8], indent: [UInt8]) -> [UInt8] {
        var result = indent
        result.append(contentsOf: Array(beginLine.utf8))
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            result.append(contentsOf: eol)
            result.append(contentsOf: indent)
            result.append(contentsOf: Array(cleaned.utf8))
        }
        result.append(contentsOf: eol)
        result.append(contentsOf: indent)
        result.append(contentsOf: Array(endLine.utf8))
        result.append(contentsOf: eol)
        return result
    }
}

// MARK: - Marker scanning

private struct BlockMatch {
    let beginLineIndex: Int
    let endLineIndex: Int
}

extension LineDoc {
    /// Trims leading/trailing space and tab bytes only -- markers are
    /// matched whitespace-tolerantly on the line, never across a newline.
    /// Not `fileprivate`: also used by `CodexHooksConfigManager`'s own
    /// BEGIN-line scans, so a single marker-line-matching rule exists in
    /// one place.
    func trimmedLineBytes(_ record: LineRecord) -> [UInt8] {
        var slice = lineBytes(record)
        while let first = slice.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
            slice.removeFirst()
        }
        while let last = slice.last, last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") {
            slice.removeLast()
        }
        return slice
    }

    /// Finds every well-formed, non-overlapping BEGIN...END occurrence, in
    /// document order. A BEGIN with no following END anywhere in the
    /// document is left untouched (its extent can't be determined), so it
    /// is never treated as -- or folded into -- a block.
    fileprivate func findBlocks(beginLine: String, endLine: String) -> [BlockMatch] {
        let beginBytes = Array(beginLine.utf8)
        let endBytes = Array(endLine.utf8)
        var result: [BlockMatch] = []
        var i = 0
        while i < lines.count {
            if trimmedLineBytes(lines[i]) == beginBytes {
                var j = i + 1
                var found: Int?
                while j < lines.count {
                    if trimmedLineBytes(lines[j]) == endBytes {
                        found = j
                        break
                    }
                    j += 1
                }
                if let end = found {
                    result.append(BlockMatch(beginLineIndex: i, endLineIndex: end))
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return result
    }
}
