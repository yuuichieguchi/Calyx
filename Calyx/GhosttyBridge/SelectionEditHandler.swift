// SelectionEditHandler.swift
// Calyx
//
// Handles select+cut and select+delete operations for the terminal.
// Reads the selection text, calculates arrow key movements to position
// the cursor at the end of the selection, then sends backspaces to delete.

@preconcurrency import AppKit
import GhosttyKit

// MARK: - Protocols

/// Reads selection and surface geometry from a ghostty surface.
@MainActor
protocol SelectionReading {
    func hasSelection() -> Bool
    func readSelection() -> (text: String, tlPxX: Double, tlPxY: Double)?
    func cellDimensions() -> (cellW: Double, cellH: Double, cols: Int)?
    func cursorPixelPosition() -> (x: Double, y: Double)?
}

/// Writes text to the system clipboard.
@MainActor
protocol ClipboardWriting {
    func copyToClipboard(_ text: String)
}

/// Dispatches synthetic key events (arrow keys, backspace) to a surface.
@MainActor
protocol KeyDispatching {
    func sendArrowLeft()
    func sendArrowRight()
    func sendBackspace()
}

// MARK: - Production Implementations

/// Reads selection data from a ghostty surface via FFI.
@MainActor
final class GhosttySurfaceSelectionReader: SelectionReading {
    private let surface: ghostty_surface_t

    init(surface: ghostty_surface_t) {
        self.surface = surface
    }

    func hasSelection() -> Bool {
        GhosttyFFI.surfaceHasSelection(surface)
    }

    func readSelection() -> (text: String, tlPxX: Double, tlPxY: Double)? {
        guard let result = readAndDecodeText({ GhosttyFFI.surfaceReadSelection(surface, text: &$0) }) else {
            return nil
        }
        return (text: result.text, tlPxX: result.raw.tl_px_x, tlPxY: result.raw.tl_px_y)
    }

    func cellDimensions() -> (cellW: Double, cellH: Double, cols: Int)? {
        let size = GhosttyFFI.surfaceSize(surface)
        let cellW = Double(size.cell_width_px)
        let cellH = Double(size.cell_height_px)
        guard cellW > 0, cellH > 0 else { return nil }
        return (cellW: cellW, cellH: cellH, cols: Int(size.columns))
    }

    /// Reads the pane's bottom `rows` *active-screen* lines (clamped to
    /// however many rows the surface actually has), for
    /// `ScreenStateClassifier`'s Herdr-layer-2 polling. Unlike
    /// `readSelection()`, this doesn't require an active user selection:
    /// it builds an explicit `ACTIVE`-relative selection spanning from
    /// `rows` lines above the bottom (`EXACT` top-left, clamped to row 0)
    /// to the active screen's `BOTTOM_RIGHT`, non-rectangular so wrapped
    /// lines read as continuous text. Follows the same decode +
    /// `defer`-release shape as `readSelection()`.
    ///
    /// Deliberately `ACTIVE`, not `VIEWPORT`: `VIEWPORT` is relative to
    /// wherever the user has scrolled to, so classifying it while
    /// scrollback is being browsed would read stale, already-scrolled-
    /// past screen content instead of the pane's actual current
    /// blocked/working status. `ACTIVE` always addresses the live
    /// (bottom) screen region regardless of scroll position, which is
    /// what the classifier needs to reflect the pane's real-time state.
    func readActiveBottomText(rows: Int) -> String? {
        let totalRows = Int(GhosttyFFI.surfaceSize(surface).rows)
        guard totalRows > 0 else { return nil }
        let startRow = UInt32(max(0, totalRows - rows))

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: startRow
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        return readAndDecodeText({ GhosttyFFI.surfaceReadText(surface, selection: selection, text: &$0) })?.text
    }

    func cursorPixelPosition() -> (x: Double, y: Double)? {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        GhosttyFFI.surfaceIMEPoint(surface, x: &x, y: &y, width: &width, height: &height)
        return (x: x, y: y)
    }

    /// Runs `read` (an FFI call that fills `text` and reports success),
    /// guarantees `GhosttyFFI.surfaceFreeText` runs on the result before
    /// returning regardless of outcome, and decodes the UTF-8 text
    /// buffer (`text.text` / `text.text_len`, not NUL-terminated) into a
    /// Swift `String` — `nil` for an unsuccessful read, or one whose
    /// buffer is empty/absent or decodes to an empty string. Shared by
    /// `readSelection()` and `readActiveBottomText(rows:)`, whose only
    /// difference is which FFI call fills `text` (and, for
    /// `readSelection()`, that it also needs `raw`'s `tl_px_x`/`tl_px_y`
    /// fields) — this keeps the FFI buffer's read/decode/free lifecycle
    /// in exactly one place. `raw`'s scalar fields remain valid to read
    /// after this returns even though `raw.text` itself has already been
    /// freed: `GhosttyFFI.surfaceFreeText` only releases the buffer
    /// `raw.text` points to, not the `ghostty_text_s` value itself,
    /// whose other fields were already value-copied by the FFI call.
    private func readAndDecodeText(
        _ read: (inout ghostty_text_s) -> Bool
    ) -> (text: String, raw: ghostty_text_s)? {
        var text = ghostty_text_s()
        guard read(&text) else { return nil }
        defer {
            var mutableText = text
            GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
        }

        let len = Int(text.text_len)
        guard len > 0, let ptr = text.text else { return nil }

        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: len)
        let decoded = String(decoding: buffer, as: UTF8.self)
        guard !decoded.isEmpty else { return nil }

        return (text: decoded, raw: text)
    }
}

/// Writes text to the system pasteboard.
@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Dispatches synthetic key events to a ghostty surface controller.
@MainActor
final class GhosttyKeyDispatcher: KeyDispatching {
    private let surfaceController: GhosttySurfaceController

    init(surfaceController: GhosttySurfaceController) {
        self.surfaceController = surfaceController
    }

    func sendArrowLeft() {
        sendKeyPress(keycode: 0x7B)  // macOS keycode for Left arrow
    }

    func sendArrowRight() {
        sendKeyPress(keycode: 0x7C)  // macOS keycode for Right arrow
    }

    func sendBackspace() {
        sendKeyPress(keycode: 0x33)  // macOS keycode for Backspace
    }

    private func sendKeyPress(keycode: UInt32) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        surfaceController.sendKey(keyEvent)

        // Send release after press.
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        surfaceController.sendKey(keyEvent)
    }
}

// MARK: - Core Logic

/// Handles selection-based edit operations (cut/delete).
enum SelectionEditHandler {

    /// Attempts to delete the selected text by sending arrow keys + backspaces.
    ///
    /// - Parameters:
    ///   - reader: Provides selection text and surface geometry.
    ///   - clipboard: If non-nil and `copyToClipboard` is true, copies selection text.
    ///   - dispatcher: Sends arrow key and backspace events.
    ///   - copyToClipboard: Whether to copy the selection to the clipboard before deleting.
    /// - Returns: `true` if the operation was handled, `false` if it should fall through.
    @MainActor
    static func handleSelectionEdit(
        reader: SelectionReading,
        clipboard: ClipboardWriting?,
        dispatcher: KeyDispatching,
        copyToClipboard: Bool
    ) -> Bool {
        // 1. Guard: has selection
        guard reader.hasSelection() else { return false }

        // 2. Guard: read selection text
        guard let selection = reader.readSelection() else { return false }
        let text = selection.text

        // 3. Guard: non-empty, single line only
        guard !text.isEmpty, !text.contains("\n") else { return false }

        // 4. Get cell dimensions and cursor position
        guard let dims = reader.cellDimensions() else { return false }
        guard let cursorPos = reader.cursorPixelPosition() else { return false }

        // 5-7. Calculate grid positions
        let cursorCol = Int(cursorPos.x / dims.cellW)
        let selStartCol = Int(selection.tlPxX / dims.cellW)

        // 8. Guard: same row — use pixel proximity (not grid row) to handle
        //    subpixel offsets between IME point and selection coordinates.
        guard abs(cursorPos.y - selection.tlPxY) < dims.cellH else { return false }

        // 9. Calculate display width (accounts for wide CJK characters)
        let displayWidth = unicodeDisplayWidth(text)

        // 10. Selection end column
        let selEndCol = selStartCol + displayWidth

        // 11. Cell delta: how many arrow keys to move cursor to selection end
        let cellDelta = selEndCol - cursorCol

        // 12. Guard: reasonable delta
        guard abs(cellDelta) < dims.cols else { return false }

        // 13. All guards passed — copy to clipboard if requested
        if copyToClipboard {
            clipboard?.copyToClipboard(text)
        }

        // 14. Send arrow keys to position cursor at end of selection
        if cellDelta > 0 {
            for _ in 0..<cellDelta { dispatcher.sendArrowRight() }
        } else if cellDelta < 0 {
            for _ in 0..<abs(cellDelta) { dispatcher.sendArrowLeft() }
        }

        // 15. Send backspaces (one per grapheme cluster)
        let graphemeCount = text.count  // Swift .count is grapheme cluster count
        for _ in 0..<graphemeCount { dispatcher.sendBackspace() }

        return true
    }
}

// MARK: - Unicode Display Width

/// Checks whether a Unicode scalar is East Asian Wide or Fullwidth,
/// meaning it occupies 2 terminal cells.
private func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    // CJK Unified Ideographs and extensions
    if (0x4E00...0x9FFF).contains(v) { return true }
    if (0x3400...0x4DBF).contains(v) { return true }
    if (0x20000...0x2A6DF).contains(v) { return true }
    if (0x2A700...0x2B73F).contains(v) { return true }
    if (0x2B740...0x2B81F).contains(v) { return true }
    if (0x2B820...0x2CEAF).contains(v) { return true }
    if (0x2CEB0...0x2EBEF).contains(v) { return true }
    if (0x30000...0x3134F).contains(v) { return true }
    if (0xF900...0xFAFF).contains(v) { return true }    // CJK Compatibility Ideographs
    if (0x2F800...0x2FA1F).contains(v) { return true }  // CJK Compatibility Supplement
    // Hangul Syllables
    if (0xAC00...0xD7AF).contains(v) { return true }
    // Fullwidth Forms
    if (0xFF01...0xFF60).contains(v) { return true }
    if (0xFFE0...0xFFE6).contains(v) { return true }
    // Hiragana and Katakana
    if (0x3040...0x309F).contains(v) { return true }
    if (0x30A0...0x30FF).contains(v) { return true }
    if (0x31F0...0x31FF).contains(v) { return true }
    // CJK Symbols and Punctuation, Enclosed CJK, CJK Compatibility
    if (0x3000...0x303F).contains(v) { return true }
    if (0x3200...0x32FF).contains(v) { return true }
    if (0x3300...0x33FF).contains(v) { return true }
    // Bopomofo
    if (0x3100...0x312F).contains(v) { return true }
    if (0x31A0...0x31BF).contains(v) { return true }
    // Ideographic Description Characters
    if (0x2FF0...0x2FFF).contains(v) { return true }
    // Kangxi Radicals
    if (0x2F00...0x2FDF).contains(v) { return true }
    // CJK Compatibility Forms
    if (0xFE30...0xFE4F).contains(v) { return true }
    return false
}

/// Calculates the terminal display width of a string, accounting for
/// East Asian wide/fullwidth characters that occupy 2 cells.
func unicodeDisplayWidth(_ text: String) -> Int {
    var width = 0
    for char in text {
        var isWide = false
        for scalar in char.unicodeScalars {
            if isWideScalar(scalar) {
                isWide = true
                break
            }
        }
        width += isWide ? 2 : 1
    }
    return width
}
