// SplitDividerTintTests.swift
// CalyxTests
//
// Pins the bug fix for PR #34: the split divider must only honor ghostty's
// split-divider-color when the user's themeColorPreset is "ghostty".
// Otherwise the divider tint stops matching the terminal background.

import AppKit
import Testing
@testable import Calyx

@Suite("SplitDividerGlassStrip.resolveTint Tests")
struct SplitDividerTintTests {

    // MARK: - Test Inputs

    /// Concrete configColor used across tests: pure magenta. Chosen because it
    /// is visually distinct from any chromeTint derivation of the original
    /// theme color so RGB comparisons unambiguously distinguish the two
    /// branches.
    private static let configColor: NSColor =
        NSColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)

    private static let themeColor: NSColor = ThemeColorPreset.original.color
    private static let glassOpacity: Double = 0.7

    // MARK: - Helpers

    /// Compare two NSColors in sRGB, asserting each RGB component matches
    /// within 0.01 — same tolerance style as ThemeColorTests.
    private func expectRGBMatches(
        _ actual: NSColor,
        _ expected: NSColor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        #expect(
            abs(a.redComponent - e.redComponent) < 0.01,
            "Red component mismatch: got \(a.redComponent), expected \(e.redComponent)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(a.greenComponent - e.greenComponent) < 0.01,
            "Green component mismatch: got \(a.greenComponent), expected \(e.greenComponent)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(a.blueComponent - e.blueComponent) < 0.01,
            "Blue component mismatch: got \(a.blueComponent), expected \(e.blueComponent)",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Happy Path: ghostty preset honors configColor

    @Test("resolveTint returns configColor when preset is ghostty and configColor is non-nil")
    func ghosttyPresetWithConfigColor() {
        let result = SplitDividerGlassStrip.resolveTint(
            themePreset: "ghostty",
            configColor: Self.configColor,
            themeColor: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        expectRGBMatches(result, Self.configColor)
    }

    // MARK: - Fallback: ghostty preset with nil configColor

    @Test("resolveTint returns chromeTint when preset is ghostty and configColor is nil")
    func ghosttyPresetWithoutConfigColor() {
        let result = SplitDividerGlassStrip.resolveTint(
            themePreset: "ghostty",
            configColor: nil,
            themeColor: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        let expected = GlassTheme.chromeTint(
            for: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        expectRGBMatches(result, expected)
    }

    // MARK: - Bug Fix: non-ghostty preset must NOT honor configColor

    @Test("resolveTint returns chromeTint when preset is 'original' even if configColor is non-nil")
    func originalPresetIgnoresConfigColor() {
        let result = SplitDividerGlassStrip.resolveTint(
            themePreset: "original",
            configColor: Self.configColor,
            themeColor: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        let expected = GlassTheme.chromeTint(
            for: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        expectRGBMatches(result, expected)
    }

    // MARK: - Parametrized: all non-ghostty presets ignore configColor

    @Test(
        "resolveTint ignores configColor for any non-ghostty preset",
        arguments: ["red", "blue", "yellow", "purple", "black", "gray", "custom"]
    )
    func nonGhosttyPresetIgnoresConfigColor(preset: String) {
        let result = SplitDividerGlassStrip.resolveTint(
            themePreset: preset,
            configColor: Self.configColor,
            themeColor: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        let expected = GlassTheme.chromeTint(
            for: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        expectRGBMatches(result, expected)
    }

    // MARK: - Defensive: garbage / unknown preset string

    @Test("resolveTint returns chromeTint for unknown preset string (defensive)")
    func unknownPresetIgnoresConfigColor() {
        let result = SplitDividerGlassStrip.resolveTint(
            themePreset: "asdf",
            configColor: Self.configColor,
            themeColor: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        let expected = GlassTheme.chromeTint(
            for: Self.themeColor,
            glassOpacity: Self.glassOpacity
        )
        expectRGBMatches(result, expected)
    }
}
