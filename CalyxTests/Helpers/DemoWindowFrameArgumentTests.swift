//
//  DemoWindowFrameArgumentTests.swift
//  CalyxTests
//
//  Coverage for DemoWindowFrameArgument.parse(_:) (Calyx/Helpers
//  /DemoWindowFrameArgument.swift), the pure `--demo-window-frame=<W>x<H>`
//  parser AppDelegate.applyDemoWindowFrameIfNeeded() consults for the
//  scripted demo-recording XCUITest scenario
//  (CalyxUITests/DemoRecordingScenario.swift). Deliberately does not
//  cover the `--uitesting` gate itself -- that combination lives at the
//  AppDelegate call site (see that method's own doc comment), and this
//  parser has no knowledge of `--uitesting` at all.
//
//  Coverage:
//  - "1440x900" parses to CGSize(1440, 900)
//  - "" / "abc" / "0x0" / negative / missing flag entirely -> nil
//  - "1440X900" (uppercase X) -> nil, documenting the case-sensitive
//    lowercase-only separator (see the parser's own doc comment)
//  - "infxinf" / "1e3x900" / "nanxnan" -> nil, documenting the switch to
//    strict `Int(_:)` parsing (a `Double`-based parser would have
//    accepted all three, per the parser's own doc comment)
//  - "+1440x900" -> ACCEPTED, documenting that `Int(_:)`'s own leading-
//    `+` grammar is left as-is rather than special-cased out
//  - an oversized value (e.g. "9999x9999") is ACCEPTED, not clamped --
//    documenting that this AppKit-free parser has no screen geometry to
//    clamp against; any clamping happens at the AppDelegate call site
//

import XCTest
@testable import Calyx

final class DemoWindowFrameArgumentTests: XCTestCase {

    func test_validWxH_parsesToCGSize() {
        let size = DemoWindowFrameArgument.parse(["--uitesting", "--demo-window-frame=1440x900"])
        XCTAssertEqual(size, CGSize(width: 1440, height: 900))
    }

    func test_missingFlag_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--uitesting", "-AppleLanguages", "(en)"]))
    }

    func test_emptyArguments_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse([]))
    }

    func test_emptyValue_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame="]))
    }

    func test_nonNumericValue_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=abcxdef"]))
    }

    /// Zero and negative values both fail the same `width > 0`/
    /// `height > 0` guard, so both are covered by one test.
    func test_nonPositiveValues_returnNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=0x0"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=0x900"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1440x0"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=-1440x900"]))
    }

    /// `Double(_:)` would have parsed all three of these (`.infinity`/
    /// `.nan` for "inf"/"nan", and "1e3" as scientific notation for
    /// 1000) -- `Int(_:)` (the parser's own deliberate choice, see its
    /// doc comment) rejects all three outright.
    func test_nonIntegerNumericShapes_returnNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=infxinf"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1e3x900"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=nanxnan"]))
    }

    /// Documented choice (see the parser's own doc comment): a leading
    /// `+` is part of `Int(_:)`'s own string-conversion grammar and is
    /// left accepted rather than special-cased out.
    func test_leadingPlusSign_isAccepted() {
        let size = DemoWindowFrameArgument.parse(["--demo-window-frame=+1440x900"])
        XCTAssertEqual(size, CGSize(width: 1440, height: 900))
    }

    /// Documented case-sensitivity choice (see the parser's own doc
    /// comment): only a lowercase `x` separator matches. An uppercase
    /// `X` is treated the same as any other malformed value -- nil,
    /// never a silent case-insensitive fallback.
    func test_uppercaseXSeparator_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1440X900"]))
    }

    func test_missingSecondDimension_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1440x"]))
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1440"]))
    }

    func test_tooManyDimensions_returnsNil() {
        XCTAssertNil(DemoWindowFrameArgument.parse(["--demo-window-frame=1440x900x100"]))
    }

    /// Documented "accept, don't clamp" choice (see the parser's own doc
    /// comment): this parser is deliberately AppKit-free and has no
    /// access to real screen geometry, so an oversized value is returned
    /// as-is rather than silently rewritten to fit some assumed bound.
    func test_oversizedValue_isAcceptedNotClamped() {
        let size = DemoWindowFrameArgument.parse(["--demo-window-frame=9999x9999"])
        XCTAssertEqual(size, CGSize(width: 9999, height: 9999))
    }

    func test_matchAmongOtherArguments_stillParses() {
        let size = DemoWindowFrameArgument.parse([
            "/path/to/Calyx", "--uitesting", "-AppleLanguages", "(en)", "--demo-window-frame=1920x1080"
        ])
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
    }
}
