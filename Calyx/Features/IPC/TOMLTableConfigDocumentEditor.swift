// TOMLTableConfigDocumentEditor.swift
// Calyx
//
// Replaces the single `[tablePath]` TOML table (its sub-tables included)
// Calyx owns inside an otherwise user-owned TOML document
// (CodexConfigManager, GrokConfigManager). Operates entirely on bytes,
// never on Swift `String`/`Character`, for the same reason
// MarkerConfigDocumentEditor does: a CRLF pair collapses into a single
// `Character`, which would make suffix/prefix checks silently wrong
// against CRLF content.
//
// `~/.codex/config.toml` is shared with CodexHooksConfigManager's
// BEGIN/END block (a different region kind entirely), so the table scan
// must also stop at a `# BEGIN CALYX` marker line -- carried over from
// `CodexConfigManager`'s existing `removeSections` scan.

import Foundation

struct TOMLTableConfigDocumentEditor: Sendable {
    /// e.g. "mcp_servers.calyx-ipc". Sub-tables (`[tablePath.headers]`,
    /// `[[tablePath.headers]]`) are part of the owned region wherever in
    /// the file they appear, per TOML's dotted-key semantics.
    let tablePath: String

    /// Replaces the first table region in place, leaving whatever
    /// separator already precedes it untouched, and removes every further
    /// one together with the one blank line immediately before it, if
    /// any. Appends at EOF, preceded by one blank separator line, when no
    /// region exists and `current` is non-empty; no separator at all when
    /// `current` is empty or absent.
    func setTable(body: String, in current: Data?) throws -> Data {
        let bytes = current.map { Array($0) } ?? []
        let doc = LineDoc(bytes: bytes)
        let regions = findRegions(doc: doc)
        let eol = doc.detectEOL()
        let newRegionBytes = buildRegion(body: body, eol: eol)

        var result = bytes
        if !regions.isEmpty {
            for (i, region) in regions.enumerated().reversed() {
                if i == 0 {
                    let range = doc.blockRange(startLine: region.startLine, endLine: region.endLine)
                    result.replaceSubrange(range, with: newRegionBytes)
                } else {
                    let range = doc.removalRange(startLine: region.startLine, endLine: region.endLine)
                    result.removeSubrange(range)
                }
            }
        } else if result.isEmpty {
            result = newRegionBytes
        } else {
            // The last byte of any EOL (LF or CRLF) is always `\n`; that
            // single-byte check is EOL-style-agnostic even when the file
            // mixes line endings and the very last line used a different
            // style than `detectEOL()`'s first-found style.
            if result.last != UInt8(ascii: "\n") {
                result.append(contentsOf: eol)
            }
            result.append(contentsOf: eol)
            result.append(contentsOf: newRegionBytes)
        }
        return Data(result)
    }

    /// Removes every table region, each together with the one blank line
    /// immediately before it, if any. A region never includes trailing
    /// blank lines past its own last content line, so blank lines the
    /// user owns beyond the region survive untouched -- the F16
    /// destruction this editor exists to not repeat.
    ///
    /// This editor edits files Calyx does not own outright, so it never
    /// signals deletion: absent input stays `nil`, and a document emptied
    /// by the removal is returned as empty `Data()`, leaving the file in
    /// place, empty, matching `MarkerConfigDocumentEditor.removeBlock`.
    func removeTable(in current: Data?) throws -> Data? {
        guard let current, !current.isEmpty else { return current }
        let bytes = Array(current)
        let doc = LineDoc(bytes: bytes)
        let regions = findRegions(doc: doc)
        guard !regions.isEmpty else { return current }

        var result = bytes
        for region in regions.reversed() {
            let range = doc.removalRange(startLine: region.startLine, endLine: region.endLine)
            result.removeSubrange(range)
        }

        return Data(result)
    }

    func containsTable(in current: Data?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        let doc = LineDoc(bytes: Array(current))
        return !findRegions(doc: doc).isEmpty
    }

    // MARK: - Region scanning

    private struct TableRegion {
        let startLine: Int
        let endLine: Int
    }

    /// Mirrors `CodexConfigManager.removeSections` / `GrokConfigManager
    /// .removeSections`: a region starts at `tablePath`'s own header OR at
    /// one of its sub-table headers (a sub-table left elsewhere in the
    /// file, on its own, still belongs to Calyx and must not be preserved
    /// as foreign content, or `setTable`'s own append would define the
    /// same table twice). The scan ends at the next table header at any
    /// level, or at a `# BEGIN CALYX` block marker; the region itself then
    /// gets trimmed back to its last non-blank line, since trailing blank
    /// lines between the region's own content and that stop condition
    /// belong to the surrounding document, not to Calyx's table.
    private func findRegions(doc: LineDoc) -> [TableRegion] {
        var regions: [TableRegion] = []
        var i = 0
        var inSection = false
        var sectionStart = 0

        while i < doc.lines.count {
            let text = doc.lineBytes(doc.lines[i])
            if !inSection {
                if isOwnHeader(text) || isOwnSubTableHeader(text) {
                    inSection = true
                    sectionStart = i
                }
            } else {
                if isOwnSubTableHeader(text) {
                    // Still part of the same entry.
                } else if isAnyTableHeader(text) || isCalyxManagedBlockMarker(text) {
                    regions.append(trimTrailingBlank(doc: doc, region: TableRegion(startLine: sectionStart, endLine: i - 1)))
                    inSection = false
                    continue
                }
            }
            i += 1
        }
        if inSection {
            regions.append(trimTrailingBlank(doc: doc, region: TableRegion(startLine: sectionStart, endLine: doc.lines.count - 1)))
        }
        return regions
    }

    /// Moves `region.endLine` back past any trailing blank lines, down to
    /// (but never above) `region.startLine`, since the header line itself
    /// is never blank.
    private func trimTrailingBlank(doc: LineDoc, region: TableRegion) -> TableRegion {
        var endLine = region.endLine
        while endLine > region.startLine, doc.lines[endLine].contentRange.isEmpty {
            endLine -= 1
        }
        return TableRegion(startLine: region.startLine, endLine: endLine)
    }

    private func trimLeading(_ bytes: [UInt8]) -> [UInt8] {
        var slice = bytes
        while let first = slice.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
            slice.removeFirst()
        }
        return slice
    }

    private func hasBytePrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        return Array(bytes[0..<prefix.count]) == prefix
    }

    /// `[tablePath]` or `[[tablePath]]`, tolerant of leading whitespace
    /// and a trailing `# comment`.
    private func isOwnHeader(_ line: [UInt8]) -> Bool {
        let t = trimLeading(line)
        for bracketed in ["[\(tablePath)]", "[[\(tablePath)]]"] {
            let prefix = Array(bracketed.utf8)
            if hasBytePrefix(t, prefix) {
                var rest = Array(t[prefix.count...])
                rest = trimLeading(rest)
                if rest.isEmpty || rest.first == UInt8(ascii: "#") { return true }
            }
        }
        return false
    }

    private func isOwnSubTableHeader(_ line: [UInt8]) -> Bool {
        let t = trimLeading(line)
        return hasBytePrefix(t, Array("[\(tablePath).".utf8)) || hasBytePrefix(t, Array("[[\(tablePath).".utf8))
    }

    /// A `[table]` or `[[table]]` header line, tolerant of leading
    /// whitespace and a trailing `# comment`. Unlike `isOwnHeader`, this
    /// accepts ANY table path, not just `tablePath`'s own -- it exists
    /// to recognize where the NEXT (unrelated) table begins, ending the
    /// current region.
    ///
    /// A bare "starts with `[`" check (this function's previous body) is
    /// too loose: a multi-line array value's own continuation line
    /// (`["a", "b"],`, the last element of an array-of-arrays written
    /// across several lines) also starts with `[` after leading
    /// whitespace, and would wrongly be read as a header, truncating the
    /// region mid-array. This instead requires the line to actually
    /// close (the closing bracket sequence, `]` or `]]` matching the
    /// opener) with nothing after it but optional whitespace and an
    /// optional trailing comment -- a trailing comma (what an array
    /// element's continuation line has instead) fails that check.
    ///
    /// Known gap, accepted as-is: a multi-line array's LAST element
    /// (`["c", "d"]` with no trailing comma, since it's followed by the
    /// array's own closing `]` on the next line) still matches, because
    /// nothing distinguishes it from a real header by this line alone.
    private func isAnyTableHeader(_ line: [UInt8]) -> Bool {
        let t = trimLeading(line)
        guard t.first == UInt8(ascii: "[") else { return false }
        let isDoubleBracketed = t.count > 1 && t[1] == UInt8(ascii: "[")
        let closer = Array((isDoubleBracketed ? "]]" : "]").utf8)
        guard let closerStart = lastRangeStart(of: closer, in: t) else { return false }
        let afterCloser = trimLeading(Array(t[(closerStart + closer.count)...]))
        return afterCloser.isEmpty || afterCloser.first == UInt8(ascii: "#")
    }

    /// The start index of the LAST occurrence of `needle` in `haystack`,
    /// or `nil` if `needle` does not occur at all.
    private func lastRangeStart(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var result: Int?
        var i = 0
        while i <= haystack.count - needle.count {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                result = i
            }
            i += 1
        }
        return result
    }

    private func isCalyxManagedBlockMarker(_ line: [UInt8]) -> Bool {
        var t = trimLeading(line)
        guard t.first == UInt8(ascii: "#") else { return false }
        t.removeFirst()
        t = trimLeading(t)
        return hasBytePrefix(t, Array("BEGIN CALYX".utf8))
    }

    /// `body` is the table's content beneath the synthesized `[tablePath]`
    /// header (key/value lines, sub-table headers). Arrives with plain
    /// `\n` separators; every line, including the header, is terminated
    /// with the document's own detected EOL.
    private func buildRegion(body: String, eol: [UInt8]) -> [UInt8] {
        var result = Array("[\(tablePath)]".utf8)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            result.append(contentsOf: eol)
            result.append(contentsOf: Array(cleaned.utf8))
        }
        result.append(contentsOf: eol)
        return result
    }
}
