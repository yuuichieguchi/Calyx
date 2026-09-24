//
//  MCPServerImportTextViewTests.swift
//  CalyxTests
//
//  The JSON import sheet's text view takes typed and pasted JSON, so it
//  must not rewrite what is entered: macOS smart quotes turn `"` into
//  `“ ”` (the JSON no longer parses) and smart dashes turn `--flag` into
//  `—flag` (the JSON parses but the argument is wrong). K70.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class MCPServerImportTextViewTests: XCTestCase {

    /// Every automatic substitution is on before configuration, as a
    /// user's system text settings may have them, so the assertions
    /// observe `configure(_:)` turning them off.
    private func makeSubstitutingTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.isRichText = true
        return textView
    }

    func test_configure_disablesQuoteAndDashSubstitution() {
        let textView = makeSubstitutingTextView()
        MCPServerImportTextView.configure(textView)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
    }

    func test_configure_disablesOtherRewritesOfTypedText() {
        let textView = makeSubstitutingTextView()
        MCPServerImportTextView.configure(textView)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.smartInsertDeleteEnabled)
        XCTAssertFalse(textView.isRichText)
    }

    func test_configure_setsTheImportTextViewAccessibilityIdentifier() {
        let textView = makeSubstitutingTextView()
        MCPServerImportTextView.configure(textView)
        XCTAssertEqual(textView.accessibilityIdentifier(), AccessibilityID.MCPServersSettings.importTextView)
    }
}
