// ControlCharacterDisplay.swift
// Calyx
//
// Renders raw command payload text (e.g. an ApprovalRequest.payload of
// literal pane_send_keys bytes) into a safely-displayable string for the
// approval banner. Escapes two families of scalar into a visible form,
// so neither can actually control the banner's own rendering (or a
// terminal the text might get pasted into), NOR visually spoof what the
// human approving it is reading (trojan-source-style bidi override
// attacks, and Unicode Tag-block "ASCII smuggling" / invisible
// prompt-injection payloads):
//
// - ASCII C0 controls (U+0000-U+001F) and DEL (U+007F) -> two-character
//   caret notation (^C, ^J, ^?, ...).
// - Every other scalar whose Unicode general category is `.control`
//   (C1 controls), `.format` (bidi/directional overrides, zero-width
//   space/joiners, BOM, soft hyphen, word joiner, the Arabic Letter
//   Mark, and -- critically -- every ASSIGNED Unicode Tag character,
//   U+E0001 and U+E0020-U+E007F, the mechanism behind real-world
//   invisible-payload "ASCII smuggling"), `.lineSeparator`/
//   `.paragraphSeparator`, `.privateUse`, or `.surrogate` -> an explicit
//   `<U+XXXX>` token, unmistakable and impossible to confuse with real
//   content.
// - Everything else (letters, digits, punctuation, combining marks,
//   plain symbol/emoji scalars) passes through unchanged.
//
// SCALAR-LEVEL, NOT GRAPHEME-LEVEL, BY DESIGN: this works on
// `text.unicodeScalars` directly, never on `Character` (extended
// grapheme cluster). An earlier Character-based version only escaped a
// flagged scalar when it formed a grapheme cluster of exactly one on
// its own -- but Unicode's own grapheme-cluster rules merge a ZWJ (or a
// Tag-block "body" character) into whichever character precedes it
// (e.g. `"a" + ZWJ` is ONE two-scalar Character), so that version never
// even inspected -- let alone escaped -- a flagged scalar riding inside
// a multi-scalar cluster. Operating on scalars closes that gap
// entirely, with one deliberate, security-over-prettiness consequence:
// a ZWJ inside an otherwise-legitimate emoji ZWJ sequence (e.g. the
// family emoji 👨‍👩‍👧) now renders as a visible `<U+200D>` token too,
// since this renderer no longer depends on -- or trusts -- grapheme
// clustering to decide what "belongs" together. For a banner whose
// whole purpose is showing a human EXACTLY what bytes a command
// contains before they approve it, that's the correct tradeoff.
//
// See CalyxTests/ApprovalInbox/ControlCharacterDisplayTests.swift for
// the specced contract.

import Foundation

enum ControlCharacterDisplay {

    /// `cap` bounds the FINAL returned string's length (including any
    /// truncation suffix) in SCALARS, not extended grapheme clusters --
    /// a single `Character` can legally contain an unbounded number of
    /// combining-mark scalars (a "Zalgo" payload) while still counting
    /// as one grapheme cluster, which would otherwise let a single such
    /// `Character` evade any grapheme-counted bound entirely. Counting
    /// per rendered scalar closes that vector: a combining mark itself
    /// is not flagged for escaping (it's a legitimate accent scalar,
    /// category `.nonspacingMark`/`.spacingMark`), but it still counts
    /// as 1 unit against `cap` here, same as any other pass-through
    /// scalar. Rendering stops as soon as the accumulated rendered
    /// length would exceed `cap` (never fully expanding a
    /// pathologically large payload just to throw most of it away), and
    /// any backing-off needed to make room for the suffix removes whole
    /// rendered units, never splitting a caret/token escape in half.
    /// The suffix reports the ORIGINAL (raw, pre-render) SCALAR count
    /// (not `Character`/grapheme count, which would undercount exactly
    /// the pathological input this cap exists to bound) -- the number
    /// that actually reflects how much data the payload contains.
    ///
    /// If `cap` is smaller than the truncation suffix's own length,
    /// there is no room for any rendered content at all: this degrades
    /// to the truncation suffix itself, clipped to `cap`, so the
    /// documented "final length never exceeds cap" contract still holds
    /// even at the extreme.
    static func render(_ text: String, cap: Int = 2000) -> String {
        let rawScalarCount = text.unicodeScalars.count
        let clampedCap = max(cap, 0)

        var units: [String] = []
        var length = 0
        var exceededCap = false

        for scalar in text.unicodeScalars {
            let unit = renderedUnit(for: scalar)
            guard length + unit.count <= clampedCap else {
                exceededCap = true
                break
            }
            units.append(unit)
            length += unit.count
        }

        guard exceededCap else {
            // Every scalar was consumed without ever exceeding
            // `clampedCap` -- the full rendered string already fits, no
            // truncation suffix needed.
            return units.joined()
        }

        let suffix = "\n… [truncated, \(rawScalarCount) total characters]"
        guard suffix.count <= clampedCap else {
            // Not even room for the whole suffix -- no room for any
            // rendered content either. Degrade to a plain
            // prefix-truncated suffix so the overall contract (never
            // exceed `cap`) still holds at this extreme.
            return String(suffix.prefix(clampedCap))
        }

        // `units` so far is bounded by `clampedCap`, not yet by the
        // smaller `budget` that leaves room for `suffix` -- drop whole
        // units from the end until it fits, so the final `cap` never
        // gets exceeded and no escape is ever split.
        let budget = clampedCap - suffix.count
        while length > budget, let last = units.popLast() {
            length -= last.count
        }

        return units.joined() + suffix
    }

    /// One rendered unit per input SCALAR (never per `Character`/
    /// grapheme cluster -- see this file's header for why). C0/DEL keep
    /// caret notation; every scalar flagged by `isEscapedCategory`
    /// becomes a `<U+XXXX>` token; everything else (letters, digits,
    /// punctuation, combining marks, plain emoji/symbol scalars) passes
    /// through as itself.
    private static func renderedUnit(for scalar: Unicode.Scalar) -> String {
        let value = scalar.value
        if value <= 0x1F || value == 0x7F {
            return caretNotation(for: value)
        }
        if isEscapedCategory(scalar) {
            return unicodeToken(for: value)
        }
        return String(scalar)
    }

    /// Category-based, not a hand-maintained code-point list: any
    /// scalar whose Unicode general category is `.control` (catches C1
    /// controls; C0 and DEL are handled separately, above, with caret
    /// notation instead), `.format` (catches EVERY bidi/directional
    /// override, zero-width space/joiner, BOM, soft hyphen, word
    /// joiner, the Arabic Letter Mark U+061C, AND every assigned Unicode
    /// Tag character -- U+E0001 and U+E0020-U+E007F; U+E0000 and
    /// U+E0002-U+E001F are simply unassigned, not `.format`, in the
    /// current Unicode standard -- in one rule, with no risk of a future
    /// omission the way a manually enumerated range list has),
    /// `.lineSeparator`/`.paragraphSeparator` (would otherwise silently
    /// reflow the banner like a real newline), `.privateUse`, or
    /// `.surrogate` (never valid in well-formed text; escaped
    /// defensively).
    private static func isEscapedCategory(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate:
            return true
        default:
            return false
        }
    }

    /// Standard caret notation: a C0 control code or DEL toggles bit
    /// 0x40 to land on its printable ASCII letter/punctuation partner --
    /// 0x00 (NUL) -> '@' ("^@"), 0x01-0x1A (SOH..SUB) -> 'A'..'Z',
    /// 0x1B (ESC) -> '[' , 0x1C (FS) -> '\', 0x1D (GS) -> ']',
    /// 0x1E (RS) -> '^', 0x1F (US) -> '_', 0x7F (DEL) -> '?'. `value ^
    /// 0x40` is always in `0x3F...0x5F` for every input this is called
    /// with, comfortably within `UInt8`, so the narrowing conversion
    /// below never traps.
    private static func caretNotation(for value: UInt32) -> String {
        let caretValue = UInt8(value ^ 0x40)
        return "^\(Character(UnicodeScalar(caretValue)))"
    }

    /// `<U+XXXX>` token form, zero-padded to at least 4 uppercase hex
    /// digits (every C1/format/separator/private-use scalar below
    /// U+10000 fits in 4; the Tag block and any wider value simply
    /// widen the token, never truncate it).
    private static func unicodeToken(for value: UInt32) -> String {
        var hex = String(value, radix: 16, uppercase: true)
        if hex.count < 4 {
            hex = String(repeating: "0", count: 4 - hex.count) + hex
        }
        return "<U+\(hex)>"
    }
}
