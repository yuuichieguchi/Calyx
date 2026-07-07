// SearchUITests.swift
// CalyxUITests

import XCTest

final class SearchUITests: CalyxUITestCase {

    private func openSearchViaCommandPalette() {
        openCommandPaletteViaMenu()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))
        searchField.typeText("Find in Terminal")
        searchField.typeKey(.enter, modifierFlags: [])
    }

    func test_openSearchBar() {
        openSearchViaCommandPalette()

        // Search field should appear
        let field = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(field), "Search bar should appear")
    }

    func test_dismissSearchWithEscape() {
        openSearchViaCommandPalette()

        let field = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(field))

        // Dismiss with Escape
        app.typeKey(.escape, modifierFlags: [])

        waitForNonExistence(field)
    }

    func test_searchBarHasAllControls() {
        openSearchViaCommandPalette()

        let field = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(field))

        // Verify all controls exist
        let prevButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.previousButton")
            .firstMatch
        XCTAssertTrue(prevButton.exists, "Previous button should exist")

        let nextButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.nextButton")
            .firstMatch
        XCTAssertTrue(nextButton.exists, "Next button should exist")

        let closeButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.closeButton")
            .firstMatch
        XCTAssertTrue(closeButton.exists, "Close button should exist")
    }

    func test_closeButtonDismissesSearch() {
        openSearchViaCommandPalette()

        let field = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(field))

        // Click close button
        let closeButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.closeButton")
            .firstMatch
        XCTAssertTrue(closeButton.exists)
        closeButton.click()

        waitForNonExistence(field)
    }

    /// Parses `SearchBarView.formatMatchCount(total:selected:)`'s own
    /// three label formats ("No matches" / "M matches" / "N of M") into
    /// (total, selected). `selected` is `nil` until the user has
    /// actually navigated to a match (field-verified: typing a query
    /// alone reports "M matches" with no selected index yet -- selection
    /// only resolves once Find Next/Previous is invoked).
    private func parseMatchCount(_ label: String) -> (total: Int?, selected: Int?) {
        if label == "No matches" { return (0, nil) }
        if let ofRange = label.range(of: " of ") {
            return (Int(label[ofRange.upperBound...]), Int(label[label.startIndex..<ofRange.lowerBound]))
        }
        if let matchesRange = label.range(of: " matches") {
            return (Int(label[label.startIndex..<matchesRange.lowerBound]), nil)
        }
        return (nil, nil)
    }

    /// Seeds known, distinctive terminal content via `PaneCLIExec`
    /// (`SelectionEditUITests`' established pane-injection pattern),
    /// types a query into `calyx.search.searchField` that matches it
    /// multiple times, and asserts `calyx.search.matchCount`'s text
    /// actually reflects a real, positive match count (not just that the
    /// label element exists, which `test_searchBarHasAllControls`
    /// already covers) and that clicking the search bar's own "next"
    /// control moves the selected match to a DIFFERENT index.
    ///
    /// Does not assert an exact total: the needle's own command line
    /// (`printf '...'`) is itself echoed into the scrollback by the
    /// shell before its output appears, so the real total is a multiple
    /// of the seeded occurrence count, not that count itself -- an
    /// implementation detail of how a pasted command is echoed, not
    /// something this test should pin down.
    func test_searchFindsSeededContent_andNextMovesSelectedMatch() {
        let needle = "CALYXNEEDLE"

        // Seed 3 occurrences of a unique needle into the scrollback via a
        // single command (fire-and-forget: this suite only needs the
        // needle to land in the terminal's own scrollback, not to read
        // the command's output back).
        panePasteAndReturn("printf '\(needle)\\nfiller\\n\(needle)\\nfiller\\n\(needle)\\n'")
        Thread.sleep(forTimeInterval: 1.0)

        openSearchViaCommandPalette()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Search bar should appear")

        // Click to give the field keyboard focus before typing: opening
        // the search bar does not itself guarantee the field is first
        // responder (`Find in Terminal`'s own palette command returns
        // focus to the palette's dismiss handling, not necessarily the
        // search field), and every other typed-text interaction
        // elsewhere in this codebase (e.g. `BrowserUITests`'s dialog
        // text field) clicks before typing for the same reason.
        searchField.click()
        searchField.typeText(needle)

        let matchCount = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.matchCount")
            .firstMatch
        XCTAssertTrue(waitFor(matchCount), "Match count label should exist")

        // The query is debounced 100ms before `performSearch` runs, and
        // ghostty reports the total asynchronously afterward; poll
        // rather than assume immediacy, same idiom as this codebase's
        // other ledger/state polls.
        var matchCountText = (matchCount.value as? String) ?? ""
        var parsed = parseMatchCount(matchCountText)
        for _ in 0..<20 where parsed.total == nil {
            Thread.sleep(forTimeInterval: 0.5)
            matchCountText = (matchCount.value as? String) ?? ""
            parsed = parseMatchCount(matchCountText)
        }
        XCTAssertNotNil(parsed.total, "Match count should report a total after searching, got \"\(matchCountText)\"")
        XCTAssertGreaterThan(
            parsed.total ?? 0, 0,
            "Should find at least one match for the seeded needle \"\(needle)\", got \"\(matchCountText)\""
        )
        let total = parsed.total ?? 0

        // "Find Next" (calyx.search.nextButton, the search bar's own
        // chevron-down control): the FIRST click resolves the selected
        // index (unset until navigation happens).
        let nextButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.nextButton")
            .firstMatch
        XCTAssertTrue(nextButton.exists, "Next button should exist")
        nextButton.click()

        var afterFirstNextText = (matchCount.value as? String) ?? ""
        var selectedAfterFirstNext = parseMatchCount(afterFirstNextText).selected
        for _ in 0..<10 where selectedAfterFirstNext == nil {
            Thread.sleep(forTimeInterval: 0.3)
            afterFirstNextText = (matchCount.value as? String) ?? ""
            selectedAfterFirstNext = parseMatchCount(afterFirstNextText).selected
        }
        XCTAssertEqual(
            afterFirstNextText, "\(selectedAfterFirstNext ?? -1) of \(total)",
            "After the first Find Next, the match count should show a selected index in \"N of \(total)\" form, got \"\(afterFirstNextText)\""
        )

        // A SECOND Find Next should move the selected match to a
        // DIFFERENT index -- not just leave the label unchanged.
        nextButton.click()

        var afterSecondNextText = (matchCount.value as? String) ?? ""
        var selectedAfterSecondNext = parseMatchCount(afterSecondNextText).selected
        for _ in 0..<10 where selectedAfterSecondNext == selectedAfterFirstNext {
            Thread.sleep(forTimeInterval: 0.3)
            afterSecondNextText = (matchCount.value as? String) ?? ""
            selectedAfterSecondNext = parseMatchCount(afterSecondNextText).selected
        }
        XCTAssertNotEqual(
            selectedAfterSecondNext, selectedAfterFirstNext,
            "Clicking Find Next again should move to a different match, changing the match count label (before: \"\(afterFirstNextText)\", after: \"\(afterSecondNextText)\")"
        )
    }
}
