// DiffLayoutModel.swift
// Calyx
//
// Pure (AppKit-free) row model for the diff view. `DiffRowBuilder` turns
// the flat display lines plus the diff algorithm's line mappings into
// rows of left/right cells: side-by-side alignment is a port of VS Code's
// `computeRangeAlignment` (diffEditorViewZones.ts) with
// `innerHunkAlignment = true`; inline is VS Code's classic inline view.

import Foundation

/// Side of a side-by-side diff. `.left` is the original, `.right` the
/// modified text. Inline layouts only use `.left`.
enum DiffSide: Equatable, Sendable {
    case left
    case right
}

enum DiffCellKind: Equatable, Sendable {
    case line(DiffLineType)
    case comment
    case filler
    case collapsedRegion(regionID: Int, hiddenCount: Int)
    case banner
}

struct DiffCell: Equatable, Sendable {
    /// Index into `displayLines` (lines and comment rows); nil for filler,
    /// collapsed and banner cells.
    let displayIndex: Int?
    /// Index into the flat `[DiffLine]` (comment rows excluded); nil for
    /// non-line cells.
    let lineIndex: Int?
    let kind: DiffCellKind
    /// UTF-16 ranges in the line text including its leading marker column.
    var innerRanges: [NSRange]
    var isWholeLineChange: Bool
    /// Which side's text a line cell shows: `.left` = `DiffLine.text`
    /// (original), `.right` = `DiffLine.modifiedText`. Context cells on the
    /// right pane and in the inline view (VS Code's modified editor) show
    /// the modified text.
    var textSide: DiffSide = .left

    static let filler = DiffCell(displayIndex: nil, lineIndex: nil, kind: .filler,
                                 innerRanges: [], isWholeLineChange: false)
}

struct DiffLayoutRow: Equatable, Sendable {
    let left: DiffCell?
    /// Always nil in the inline layout.
    let right: DiffCell?
}

enum DiffRowBuilder {

    /// A diff line with its positions and the comment rows that follow it.
    private struct Entry {
        let displayIndex: Int
        let lineIndex: Int
        let line: DiffLine
        let commentDisplayIndices: [Int]
    }

    static func build(displayLines: [DisplayLine], changes: [DetailedLineRangeMapping],
                      layout: DiffLayout) -> [DiffLayoutRow] {
        buildLayout(displayLines: displayLines, changes: changes, layout: layout).rows
    }

    /// Rows plus alignment blocks: row-index ranges partitioning the rows.
    /// Side by side, every aligned group (with its interleaved comment rows)
    /// is one block; outside a group each row is its own block. Inline rows
    /// are all singletons.
    static func buildLayout(displayLines: [DisplayLine], changes: [DetailedLineRangeMapping],
                            layout: DiffLayout) -> DiffRowLayout {
        let entries = makeEntries(displayLines)
        var builder = Builder(layout: layout, entries: entries, changes: changes)
        builder.run()
        return DiffRowLayout(rows: builder.rows, blocks: builder.blocks)
    }

    private static func makeEntries(_ displayLines: [DisplayLine]) -> [Entry] {
        var entries: [Entry] = []
        var pending: (displayIndex: Int, lineIndex: Int, line: DiffLine)?
        var comments: [Int] = []
        var lineIndex = 0
        for (displayIndex, displayLine) in displayLines.enumerated() {
            switch displayLine {
            case .diff(let line):
                if let p = pending {
                    entries.append(Entry(displayIndex: p.displayIndex, lineIndex: p.lineIndex,
                                         line: p.line, commentDisplayIndices: comments))
                }
                pending = (displayIndex, lineIndex, line)
                comments = []
                lineIndex += 1
            case .commentBlock:
                // buildDisplayLines always places comments after a diff line.
                comments.append(displayIndex)
            }
        }
        if let p = pending {
            entries.append(Entry(displayIndex: p.displayIndex, lineIndex: p.lineIndex,
                                 line: p.line, commentDisplayIndices: comments))
        }
        return entries
    }

    private struct Builder {
        let layout: DiffLayout
        let entries: [Entry]
        let changes: [DetailedLineRangeMapping]
        var rows: [DiffLayoutRow] = []
        var blocks: [Range<Int>] = []
        /// True while `emitGroup` appends rows; the group closes one block.
        private var inGroup = false

        /// Text without marker, keyed by original line number (context + deletion).
        let originalText: [Int: String]
        let modifiedText: [Int: String]

        init(layout: DiffLayout, entries: [Entry], changes: [DetailedLineRangeMapping]) {
            self.layout = layout
            self.entries = entries
            self.changes = changes
            var orig: [Int: String] = [:]
            var mod: [Int: String] = [:]
            for e in entries {
                let text = String(e.line.text.dropFirst())
                switch e.line.type {
                case .context:
                    if let n = e.line.oldLineNumber { orig[n] = text }
                    if let n = e.line.newLineNumber { mod[n] = String(e.line.modifiedText.dropFirst()) }
                case .deletion:
                    if let n = e.line.oldLineNumber { orig[n] = text }
                case .addition:
                    if let n = e.line.newLineNumber { mod[n] = text }
                case .hunkHeader, .meta:
                    break
                }
            }
            originalText = orig
            modifiedText = mod
        }

        mutating func run() {
            var i = 0
            while i < entries.count {
                let entry = entries[i]
                switch entry.line.type {
                case .deletion, .addition:
                    var j = i
                    while j < entries.count, entries[j].line.type == .deletion || entries[j].line.type == .addition {
                        j += 1
                    }
                    emitChangeBlock(Array(entries[i..<j]))
                    i = j
                case .context, .hunkHeader, .meta:
                    emitContext(entry)
                    i += 1
                }
            }
        }

        /// A context line has both numbers, except in an uncompared
        /// (too-large) file past the shorter side: there the missing side is
        /// a filler, and the inline view (the modified file) omits
        /// original-only lines.
        private mutating func emitContext(_ entry: Entry) {
            let hasOriginal = entry.line.oldLineNumber != nil || entry.line.type != .context
            let hasModified = entry.line.newLineNumber != nil || entry.line.type != .context
            let original = lineCell(entry, inner: [], whole: false)
            var modified = original
            modified.textSide = .right
            switch layout {
            case .inline:
                guard hasModified else { return }
                appendRow(left: modified, right: nil, leftEntry: entry, rightEntry: nil)
            case .sideBySide:
                // Its comments render on the right when it has a right side.
                if hasModified {
                    appendRow(left: hasOriginal ? original : .filler, right: modified, leftEntry: nil, rightEntry: entry)
                } else {
                    appendRow(left: original, right: .filler, leftEntry: entry, rightEntry: nil)
                }
            }
        }

        // MARK: Change blocks

        private mutating func emitChangeBlock(_ block: [Entry]) {
            var consumed = Set<Int>()
            for mapping in changes {
                let dels = block.filter { e in
                    e.line.type == .deletion && e.line.oldLineNumber.map(mapping.original.contains) == true
                }
                let adds = block.filter { e in
                    e.line.type == .addition && e.line.newLineNumber.map(mapping.modified.contains) == true
                }
                guard !dels.isEmpty || !adds.isEmpty else { continue }
                dels.forEach { consumed.insert($0.lineIndex) }
                adds.forEach { consumed.insert($0.lineIndex) }
                emitMapping(mapping, deletions: dels, additions: adds)
            }
            // Lines not covered by any mapping: placed top-aligned, unannotated.
            let rest = block.filter { !consumed.contains($0.lineIndex) }
            if !rest.isEmpty {
                let pair: (Entry) -> (DiffCell, Entry) = { (lineCell($0, inner: [], whole: false), $0) }
                emitGroup(left: rest.filter { $0.line.type == .deletion }.map(pair),
                          right: rest.filter { $0.line.type == .addition }.map(pair))
            }
        }

        private mutating func emitMapping(_ mapping: DetailedLineRangeMapping,
                                          deletions: [Entry], additions: [Entry]) {
            let whole = mapping.original.isEmpty || mapping.modified.isEmpty
            let inner = mapping.innerChanges ?? []
            let origRanges = innerRangesByLine(inner.map(\.originalRange), text: originalText)
            let modRanges = innerRangesByLine(inner.map(\.modifiedRange), text: modifiedText)

            let delByLine = Dictionary(deletions.compactMap { e in e.line.oldLineNumber.map { ($0, e) } },
                                       uniquingKeysWith: { a, _ in a })
            let addByLine = Dictionary(additions.compactMap { e in e.line.newLineNumber.map { ($0, e) } },
                                       uniquingKeysWith: { a, _ in a })
            func leftCells(_ r: Range<Int>) -> [(DiffCell, Entry)] {
                r.compactMap { n in delByLine[n].map { (lineCell($0, inner: origRanges[n] ?? [], whole: whole), $0) } }
            }
            func rightCells(_ r: Range<Int>) -> [(DiffCell, Entry)] {
                r.compactMap { n in addByLine[n].map { (lineCell($0, inner: modRanges[n] ?? [], whole: whole), $0) } }
            }

            switch layout {
            case .inline:
                let origAll = mapping.original.startLineNumber..<mapping.original.endLineNumberExclusive
                let modAll = mapping.modified.startLineNumber..<mapping.modified.endLineNumberExclusive
                for (cell, e) in leftCells(origAll) + rightCells(modAll) {
                    appendRow(left: cell, right: nil, leftEntry: e, rightEntry: nil)
                }
            case .sideBySide:
                for (o, m) in alignment(mapping) {
                    emitGroup(left: leftCells(o), right: rightCells(m))
                }
            }
        }

        /// Port of `computeRangeAlignment`'s per-mapping loop with
        /// `innerHunkAlignment = true`.
        private func alignment(_ c: DetailedLineRangeMapping) -> [(Range<Int>, Range<Int>)] {
            var result: [(Range<Int>, Range<Int>)] = []
            var first = true
            var lastOrig = c.original.startLineNumber
            var lastMod = c.modified.startLineNumber

            func emit(_ origExclusive: Int, _ modExclusive: Int, force: Bool = false) {
                if origExclusive < lastOrig || modExclusive < lastMod { return }
                if first {
                    first = false
                } else if !force && (origExclusive == lastOrig || modExclusive == lastMod) {
                    return
                }
                if origExclusive == lastOrig && modExclusive == lastMod { return }
                result.append((lastOrig..<origExclusive, lastMod..<modExclusive))
                lastOrig = origExclusive
                lastMod = modExclusive
            }

            for i in c.innerChanges ?? [] {
                if i.originalRange.startColumn > 1 && i.modifiedRange.startColumn > 1 {
                    emit(i.originalRange.startLineNumber, i.modifiedRange.startLineNumber)
                }
                let maxColumn = originalText[i.originalRange.endLineNumber].map { $0.utf16.count + 1 } ?? Int.max
                if i.originalRange.endColumn < maxColumn {
                    emit(i.originalRange.endLineNumber, i.modifiedRange.endLineNumber)
                }
            }
            emit(c.original.endLineNumberExclusive, c.modified.endLineNumberExclusive, force: true)
            return result
        }

        /// Splits text ranges into per-line UTF-16 ranges (marker column included).
        private func innerRangesByLine(_ ranges: [DiffTextRange], text: [Int: String]) -> [Int: [NSRange]] {
            var out: [Int: [NSRange]] = [:]
            for r in ranges {
                if r.startLineNumber == r.endLineNumber {
                    out[r.startLineNumber, default: []].append(
                        NSRange(location: r.startColumn, length: r.endColumn - r.startColumn))
                    continue
                }
                for n in r.startLineNumber...r.endLineNumber {
                    let maxColumn = (text[n]?.utf16.count ?? 0) + 1
                    let start = n == r.startLineNumber ? r.startColumn : 1
                    let end = n == r.endLineNumber ? r.endColumn : maxColumn
                    out[n, default: []].append(NSRange(location: start, length: max(end - start, 0)))
                }
            }
            return out
        }

        // MARK: Rows

        private mutating func emitGroup(left: [(DiffCell, Entry)], right: [(DiffCell, Entry)]) {
            let start = rows.count
            inGroup = layout == .sideBySide
            defer {
                if inGroup, rows.count > start { blocks.append(start..<rows.count) }
                inGroup = false
            }
            for k in 0..<max(left.count, right.count) {
                let l = k < left.count ? left[k] : nil
                let r = k < right.count ? right[k] : nil
                appendRow(left: l?.0 ?? .filler, right: r?.0 ?? .filler,
                          leftEntry: l?.1, rightEntry: r?.1)
            }
        }

        /// Appends a row, then the comment rows of the entries it holds
        /// (left entry's comments on the left, right entry's on the right).
        private mutating func appendRow(left: DiffCell, right: DiffCell?, leftEntry: Entry?, rightEntry: Entry?) {
            push(DiffLayoutRow(left: left, right: right))
            let isInline = layout == .inline
            for d in leftEntry?.commentDisplayIndices ?? [] {
                push(DiffLayoutRow(left: commentCell(d), right: isInline ? nil : .filler))
            }
            for d in rightEntry?.commentDisplayIndices ?? [] {
                push(DiffLayoutRow(left: .filler, right: commentCell(d)))
            }
        }

        /// Appends one row; outside a group it is its own block.
        private mutating func push(_ row: DiffLayoutRow) {
            rows.append(row)
            if !inGroup { blocks.append((rows.count - 1)..<rows.count) }
        }

        private func lineCell(_ e: Entry, inner: [NSRange], whole: Bool) -> DiffCell {
            DiffCell(displayIndex: e.displayIndex, lineIndex: e.lineIndex, kind: .line(e.line.type),
                     innerRanges: inner, isWholeLineChange: whole)
        }

        private func commentCell(_ displayIndex: Int) -> DiffCell {
            DiffCell(displayIndex: displayIndex, lineIndex: nil, kind: .comment,
                     innerRanges: [], isWholeLineChange: false)
        }
    }
}

enum DiffSideRangeResolver {

    /// First/last displayIndex of `.line(context|addition|deletion)` cells on
    /// `side` within rows `startRow...endRow`; nil when there is none.
    static func displayRange(rows: [DiffLayoutRow], side: DiffSide,
                             startRow: Int, endRow: Int) -> (start: Int, end: Int)? {
        let lo = max(min(startRow, endRow), 0)
        let hi = min(max(startRow, endRow), rows.count - 1)
        guard lo <= hi else { return nil }
        var first: Int?
        var last: Int?
        for row in rows[lo...hi] {
            let cell = side == .left ? row.left : row.right
            guard let cell, let d = cell.displayIndex else { continue }
            switch cell.kind {
            case .line(.context), .line(.addition), .line(.deletion):
                if first == nil { first = d }
                last = d
            default:
                continue
            }
        }
        guard let first, let last else { return nil }
        return (first, last)
    }
}
