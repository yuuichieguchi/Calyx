//
//  SettingsLabelFactoryTests.swift
//  CalyxTests
//
//  TDD Red phase: tabbed Settings window restructure, description-label
//  wrapping. Introduces SettingsLabelFactory, which does not exist yet --
//  a held-out compile-RED file, same convention as SettingsPaneTests
//  (see that file's header).
//
//  ROOT CAUSE OF THE TRUNCATION BUG, confirmed by running actual AppKit
//  code (not guessed from memory): NSTextField(labelWithString:) --
//  what SettingsWindowController.swift's LSP and Sessions subtitles
//  (":157-162", ":187-192") are built with -- defaults its
//  lineBreakMode to .byClipping, and setting maximumNumberOfLines = 0
//  afterwards (which both call sites already do) does NOT change that.
//  Only NSTextField(wrappingLabelWithString:), or an explicit
//  `.lineBreakMode = .byWordWrapping`, produces word-wrapping; verified
//  directly:
//
//    NSTextField(labelWithString: "hi").lineBreakMode == .byClipping   // true
//    NSTextField(wrappingLabelWithString: "hi").lineBreakMode == .byWordWrapping  // true
//
//  This is exactly why both subtitles clip mid-sentence in the reported
//  screenshot despite already having maximumNumberOfLines = 0 and
//  preferredMaxLayoutWidth = 460 set: that "recovery round" fix was
//  incomplete because it never touched lineBreakMode.
//
//  This factory pins the two properties that actually control wrapping
//  (maximumNumberOfLines and lineBreakMode) behind one construction
//  path, so every pane's description labels share the fix instead of
//  re-triggering this bug per call site.
//

import XCTest
@testable import Calyx

@MainActor
final class SettingsLabelFactoryTests: XCTestCase {

    func test_descriptionLabel_wordWrapsInsteadOfClipping() {
        let label = SettingsLabelFactory.descriptionLabel("placeholder text")

        XCTAssertEqual(label.maximumNumberOfLines, 0,
                       "must be unlimited so a long description is never capped at one line")
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping,
                       "must be .byWordWrapping -- NSTextField(labelWithString:)'s default " +
                       ".byClipping survives maximumNumberOfLines = 0 unchanged, which is the " +
                       "actual, verified cause of the reported clipping")
    }

    func test_descriptionLabel_preservesGivenString() {
        let text = "Calyx hosts language servers and exposes them to AI agents over MCP."
        let label = SettingsLabelFactory.descriptionLabel(text)

        XCTAssertEqual(label.stringValue, text)
    }

    func test_descriptionLabel_usesSecondaryLabelColorAndSize13Font_matchingExistingSubtitles() {
        let label = SettingsLabelFactory.descriptionLabel("placeholder text")

        XCTAssertEqual(label.textColor, .secondaryLabelColor)
        XCTAssertEqual(label.font, .systemFont(ofSize: 13))
    }
}
