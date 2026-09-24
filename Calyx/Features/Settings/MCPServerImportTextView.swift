//
//  MCPServerImportTextView.swift
//  Calyx
//
//  The JSON text area of the MCP server import sheet. SwiftUI's
//  `TextEditor` follows the system text settings, so smart quotes turn
//  `"` into `“ ”` (the JSON no longer parses) and smart dashes turn
//  `--flag` into `—flag` (the JSON parses with a wrong argument).
//  SwiftUI has no modifier for either on macOS, so this wraps an
//  `NSTextView` with every automatic rewrite of the typed text turned off.
//

import AppKit
import SwiftUI

struct MCPServerImportTextView: NSViewRepresentable {
    @Binding var text: String

    /// Turns off every rewrite of typed or pasted text and sets the
    /// accessibility identifier on the text view itself, the element
    /// XCUITest finds as a text view.
    static func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.setAccessibilityIdentifier(AccessibilityID.MCPServersSettings.importTextView)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = Self.textView(in: scrollView)
        Self.configure(textView)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let textView = Self.textView(in: scrollView)
        if textView.string != text {
            textView.string = text
        }
    }

    /// `NSTextView.scrollableTextView()` documents its document view as
    /// an `NSTextView`; anything else is an AppKit contract violation.
    private static func textView(in scrollView: NSScrollView) -> NSTextView {
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() returned a scroll view without an NSTextView document view")
        }
        return textView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            // NSText posts its delegate notifications with itself as the object.
            guard let textView = notification.object as? NSTextView else {
                preconditionFailure("textDidChange arrived without an NSTextView object")
            }
            text.wrappedValue = textView.string
        }
    }
}
