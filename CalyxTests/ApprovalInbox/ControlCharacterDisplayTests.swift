//
//  ControlCharacterDisplayTests.swift
//  CalyxTests
//
//  TDD Red Phase for ControlCharacterDisplay: renders raw command
//  payload text (e.g. an ApprovalRequest.payload of literal
//  pane_send_keys bytes) into a safely-displayable string for the
//  approval banner -- escaping ASCII control characters into their
//  caret-notation form (never letting a raw newline/escape/etc.
//  actually control the banner's own rendering) and capping overlong
//  payloads.
//
//  Coverage:
//  - Ctrl-C (ETX, 0x03), LF, CR, TAB, ESC, DEL, NUL each render to
//    their two-character caret form (^C, ^J, ^M, ^I, ^[, ^?, ^@); none
//    of these bytes survive literally into the rendered string
//  - plain ASCII, Japanese, and (non-joined) emoji text passes through
//    unchanged
//  - escaping operates on SCALARS, not grapheme clusters: a flagged
//    scalar (Tag block, ZWJ, bidi override, ...) is escaped even when
//    Unicode's own grapheme-cluster rules would merge it into a
//    neighboring Character -- including inside an otherwise-legitimate
//    emoji ZWJ sequence, which now renders its joiners as visible
//    `<U+200D>` tokens (a deliberate security-over-prettiness tradeoff)
//  - `cap` bounds the rendered SCALAR count, not `Character`/grapheme
//    count, so one pathological many-combining-mark Character can't
//    evade it
//  - a rendered string over `cap` scalars is truncated to at most `cap`
//    characters total (including the truncation suffix), never
//    splitting a caret/token escape in half, with the suffix reporting
//    the original (raw, pre-render) scalar count
//

import XCTest
@testable import Calyx

final class ControlCharacterDisplayTests: XCTestCase {

    func test_ctrlC_rendersCaretC() {
        XCTAssertEqual(ControlCharacterDisplay.render("a\u{03}b"), "a^Cb")
    }

    func test_newline_rendersCaretJ_notALineBreak() {
        let result = ControlCharacterDisplay.render("x\ny")

        XCTAssertEqual(result, "x^Jy")
        XCTAssertFalse(result.contains("\n"), "a raw newline must never survive into the rendered string")
    }

    func test_carriageReturn_tab_escape_del() {
        XCTAssertEqual(ControlCharacterDisplay.render("\r"), "^M")
        XCTAssertEqual(ControlCharacterDisplay.render("\t"), "^I")
        XCTAssertEqual(ControlCharacterDisplay.render("\u{1B}"), "^[")
        XCTAssertEqual(ControlCharacterDisplay.render("\u{7F}"), "^?")
    }

    func test_nul_rendersCaretAt() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{00}"), "^@")
    }

    func test_plainTextUnchanged() {
        let text = "Hello, world 世界 🎉"

        XCTAssertEqual(ControlCharacterDisplay.render(text), text,
                       "plain ASCII, Japanese, and emoji text must pass through unrendered")
    }

    func test_capAt2000_appendsTruncationSuffixWithTotalCount() {
        // Crafted so the 2000-character cap boundary lands exactly on
        // the caret half of the one NUL's two-character "^@" escape --
        // the renderer must back off to the prior complete
        // character/escape rather than emit a dangling, misleading lone
        // "^" at the cut edge.
        let input = String(repeating: "a", count: 1999) + "\u{00}" + String(repeating: "b", count: 500)
        XCTAssertEqual(input.count, 2500, "sanity check on the crafted fixture")

        let result = ControlCharacterDisplay.render(input, cap: 2000)

        XCTAssertLessThan(result.count, input.count,
                          "a capped render must be shorter than the raw input once truncated")
        XCTAssertLessThanOrEqual(result.count, 2000,
                                 "the FINAL returned string, including the truncation suffix, must never exceed cap")
        XCTAssertFalse(result.hasPrefix(String(repeating: "a", count: 1999) + "^"),
                       "truncation must never keep a lone caret without its \"^@\" escape partner")
        XCTAssertTrue(result.contains("2500"),
                     "the truncation suffix must report the original (raw, pre-render) character count")
    }

    func test_hugePayload_finalResultNeverExceedsCap_boundsWorkNotJustLayout() {
        let hugePayload = String(repeating: "a", count: 1_000_000)

        let result = ControlCharacterDisplay.render(hugePayload, cap: 500)

        XCTAssertLessThanOrEqual(result.count, 500,
                                 "a pathologically large payload must still be capped, including its suffix")
        XCTAssertTrue(result.contains("1000000"),
                     "the suffix must still report the true raw character count")
    }

    /// Critical #2: `cap` must bound rendered SCALAR count, not
    /// `Character`/grapheme-cluster count -- a single `Character` built
    /// from a base letter plus 50,000 combining marks is still exactly
    /// ONE grapheme cluster, so a grapheme-counted cap would treat it as
    /// costing "1" and let it through completely unbounded (a
    /// "Zalgo bomb").
    func test_zalgoCombiningMarkBomb_boundedByScalarCountNotGraphemeCount() {
        var zalgo = "a"
        for _ in 0..<50_000 {
            zalgo.unicodeScalars.append(Unicode.Scalar(0x0301)!) // COMBINING ACUTE ACCENT
        }
        XCTAssertEqual(zalgo.count, 1, "sanity check: the crafted fixture is a single grapheme cluster")

        let result = ControlCharacterDisplay.render(zalgo, cap: 2000)

        XCTAssertLessThanOrEqual(result.unicodeScalars.count, 2000,
                                 "cap must bound the rendered scalar count, not just the grapheme-cluster count")
    }

    /// S8: when `cap` is smaller than the truncation suffix's own
    /// length, there is no room for any rendered content -- the result
    /// must degrade to a clipped suffix rather than silently exceeding
    /// `cap`.
    func test_capSmallerThanSuffixLength_degradesToClippedSuffix_neverExceedsCap() {
        let input = String(repeating: "a", count: 100)

        let result = ControlCharacterDisplay.render(input, cap: 5)

        XCTAssertLessThanOrEqual(result.count, 5,
                                 "even when cap is smaller than the truncation suffix itself, the result must " +
                                 "never exceed cap")
    }

    // MARK: - Unicode bidi/format/invisible spoofing (security)

    func test_bidiRightToLeftOverride_rendersAsUnicodeToken() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{202E}"), "<U+202E>")
    }

    func test_lineSeparator_rendersAsUnicodeToken_notARealLineBreak() {
        let result = ControlCharacterDisplay.render("x\u{2028}y")

        XCTAssertEqual(result, "x<U+2028>y")
        XCTAssertFalse(result.contains("\u{2028}"), "a raw line separator must never survive into the rendered string")
    }

    func test_c1Control_rendersAsUnicodeToken() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{0085}"), "<U+0085>")
    }

    func test_byteOrderMark_rendersAsUnicodeToken() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{FEFF}"), "<U+FEFF>")
    }

    func test_zeroWidthSpace_rendersAsUnicodeToken() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{200B}"), "<U+200B>")
    }

    func test_arabicLetterMark_rendersAsUnicodeToken() {
        XCTAssertEqual(ControlCharacterDisplay.render("\u{061C}"), "<U+061C>")
    }

    /// Critical #1: the Unicode Tag block is the mechanism behind
    /// real-world invisible-payload/"ASCII smuggling" attacks -- an
    /// entire hidden secondary payload can ride along inside characters
    /// that render as nothing at all. Must be escaped like any other
    /// `.format`-category scalar. U+E0001 (LANGUAGE TAG) is used here --
    /// note only U+E0001 and U+E0020-U+E007F are actually assigned
    /// (`.format`) code points in this block; the rest (including
    /// U+E0000 and U+E0002-U+E001F) are unassigned (`.unassigned`, not
    /// `.format`) and therefore correctly NOT escaped by this renderer,
    /// same as any other unassigned scalar.
    func test_tagCharacter_rendersAsUnicodeToken() {
        let result = ControlCharacterDisplay.render("Approve this\u{E0001}")

        XCTAssertEqual(result, "Approve this<U+E0001>")
        XCTAssertFalse(result.unicodeScalars.contains(Unicode.Scalar(0xE0001)!),
                       "a raw Tag character must never survive into the rendered string")
    }

    /// Critical #3: escaping must operate on scalars, not the
    /// `Character`/grapheme cluster Unicode's own segmentation rules
    /// would merge a flagged scalar into. Per grapheme-cluster-break
    /// rule GB9, `"a" + ZWJ` is ONE two-scalar `Character` -- a
    /// Character-level (cluster-of-one) escaping gate would never even
    /// inspect the ZWJ here, let alone escape it.
    func test_zwjBetweenPlainASCII_isEscaped_evenThoughItMergesIntoAGraphemeCluster() {
        XCTAssertEqual(ControlCharacterDisplay.render("a\u{200D}b"), "a<U+200D>b")
    }

    func test_plainEmoji_passesThroughUnescaped() {
        let thumbsUp = "👍"
        XCTAssertEqual(ControlCharacterDisplay.render(thumbsUp), thumbsUp,
                       "a plain emoji scalar with no format/control scalars must pass through unescaped")
    }

    /// Deliberate contract: a ZWJ is a `.format`-category scalar and is
    /// ALWAYS escaped, even inside an otherwise-legitimate emoji ZWJ
    /// sequence -- this renderer no longer trusts grapheme clustering to
    /// decide what "belongs together" (see critical #3), so a family
    /// emoji's joiners now render as visible tokens. Security-over-
    /// prettiness tradeoff for a command-preview banner: a human
    /// deciding whether to approve a command should see every byte that
    /// could possibly be hiding something, not a prettied-up cluster.
    func test_emojiZWJFamilySequence_rendersJoinersAsVisibleTokens_bySecurityDesign() {
        let family = "👨\u{200D}👩\u{200D}👧" // man + ZWJ + woman + ZWJ + girl
        let result = ControlCharacterDisplay.render(family)

        XCTAssertEqual(result, "👨<U+200D>👩<U+200D>👧")
    }
}
