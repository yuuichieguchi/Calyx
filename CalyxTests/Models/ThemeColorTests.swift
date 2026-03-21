// ThemeColorTests.swift
// CalyxTests
//
// TDD red-phase tests for ThemeColorPreset and HexColor.
//
// ThemeColorPreset is a CaseIterable enum representing built-in theme color
// presets (original, ghostty, black, gray, custom). Each preset maps to an
// NSColor used to derive chrome tint, atmosphere gradients, and accent colors.
//
// HexColor is a utility enum for parsing hex color strings (e.g. "#FF0000")
// into NSColor and converting NSColor back to hex strings.
//
// Coverage:
// - ThemeColorPreset display names, color values, CaseIterable conformance
// - HexColor parsing (valid, invalid, edge cases)
// - HexColor toHex conversion and round-trip consistency

import AppKit
import Testing
@testable import Calyx

// MARK: - ThemeColorPreset Tests

@Suite("ThemeColorPreset Tests")
struct ThemeColorPresetTests {

    // MARK: - Display Names

    @Test("Each preset has a non-empty displayName")
    func allPresetsHaveNonEmptyDisplayName() {
        for preset in ThemeColorPreset.allCases {
            #expect(
                !preset.displayName.isEmpty,
                "Preset \(preset) should have a non-empty displayName"
            )
        }
    }

    // MARK: - Preset Color Values

    @Test("Original preset color matches hardcoded value (r:0.02 g:0.05 b:0.11)")
    func originalPresetColor() {
        let color = ThemeColorPreset.original.color
        let r = color.redComponent
        let g = color.greenComponent
        let b = color.blueComponent
        #expect(abs(r - 0.02) < 0.01, "Red component should be ~0.02")
        #expect(abs(g - 0.05) < 0.01, "Green component should be ~0.05")
        #expect(abs(b - 0.11) < 0.01, "Blue component should be ~0.11")
    }

    @Test("Ghostty preset color is neutral (saturation < 0.05)")
    func ghosttyPresetIsNeutral() {
        let color = ThemeColorPreset.ghostty.color
        let saturation = color.saturationComponent
        #expect(
            saturation < 0.05,
            "Ghostty preset should be nearly neutral (saturation \(saturation) >= 0.05)"
        )
    }

    @Test("Black preset color is (0, 0, 0)")
    func blackPresetColor() {
        let color = ThemeColorPreset.black.color
        let r = color.redComponent
        let g = color.greenComponent
        let b = color.blueComponent
        #expect(abs(r) < 0.01, "Red component should be ~0")
        #expect(abs(g) < 0.01, "Green component should be ~0")
        #expect(abs(b) < 0.01, "Blue component should be ~0")
    }

    @Test("Gray preset color is neutral (saturation < 0.05)")
    func grayPresetIsNeutral() {
        let color = ThemeColorPreset.gray.color
        let saturation = color.saturationComponent
        #expect(
            saturation < 0.05,
            "Gray preset should be nearly neutral (saturation \(saturation) >= 0.05)"
        )
    }

    // MARK: - CaseIterable Conformance

    @Test("Custom case exists in CaseIterable")
    func customCaseExists() {
        let allCases = ThemeColorPreset.allCases
        let hasCustom = allCases.contains { preset in
            if case .custom = preset { return true }
            return false
        }
        #expect(hasCustom, "ThemeColorPreset.allCases should contain .custom")
    }

    @Test("All preset rawValues are unique")
    func allRawValuesUnique() {
        let rawValues = ThemeColorPreset.allCases.map(\.rawValue)
        let uniqueCount = Set(rawValues).count
        #expect(
            rawValues.count == uniqueCount,
            "All rawValues should be unique but found duplicates"
        )
    }
}

// MARK: - HexColor Tests

@Suite("HexColor Tests")
struct HexColorTests {

    // MARK: - Valid Parsing

    @Test("parse #FF0000 returns red NSColor")
    func parseRedWithHash() {
        let color = HexColor.parse("#FF0000")
        #expect(color != nil, "Should parse a valid hex string")
        if let color {
            #expect(abs(color.redComponent - 1.0) < 0.01, "Red should be ~1.0")
            #expect(abs(color.greenComponent) < 0.01, "Green should be ~0.0")
            #expect(abs(color.blueComponent) < 0.01, "Blue should be ~0.0")
        }
    }

    @Test("parse FF0000 works without # prefix")
    func parseRedWithoutHash() {
        let color = HexColor.parse("FF0000")
        #expect(color != nil, "Should parse hex without # prefix")
        if let color {
            #expect(abs(color.redComponent - 1.0) < 0.01, "Red should be ~1.0")
            #expect(abs(color.greenComponent) < 0.01, "Green should be ~0.0")
            #expect(abs(color.blueComponent) < 0.01, "Blue should be ~0.0")
        }
    }

    @Test("parse #ff0000 works case-insensitive")
    func parseLowercase() {
        let color = HexColor.parse("#ff0000")
        #expect(color != nil, "Should parse lowercase hex")
        if let color {
            #expect(abs(color.redComponent - 1.0) < 0.01, "Red should be ~1.0")
        }
    }

    // MARK: - Invalid Parsing

    @Test("parse #GG0000 returns nil for invalid hex characters")
    func parseInvalidHexChars() {
        let color = HexColor.parse("#GG0000")
        #expect(color == nil, "Should return nil for invalid hex characters")
    }

    @Test("parse #FFF returns nil for too-short input")
    func parseTooShort() {
        let color = HexColor.parse("#FFF")
        #expect(color == nil, "Should return nil for 3-char hex (only 6-char supported)")
    }

    @Test("parse # returns nil for hash-only input")
    func parseHashOnly() {
        let color = HexColor.parse("#")
        #expect(color == nil, "Should return nil for hash-only input")
    }

    @Test("parse empty string returns nil")
    func parseEmptyString() {
        let color = HexColor.parse("")
        #expect(color == nil, "Should return nil for empty string")
    }

    @Test("parse #FF00001 returns nil for too-long input")
    func parseTooLong() {
        let color = HexColor.parse("#FF00001")
        #expect(color == nil, "Should return nil for 7-char hex (too long)")
    }

    // MARK: - toHex Conversion

    @Test("toHex from red NSColor returns #FF0000 or close")
    func toHexRed() {
        let red = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let hex = HexColor.toHex(red)
        #expect(hex == "#FF0000", "Red NSColor should convert to #FF0000")
    }

    // MARK: - Round-trip

    @Test("Round-trip: parse(toHex(color)) approximately equals original color")
    func roundTrip() {
        let original = NSColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1.0)
        let hex = HexColor.toHex(original)
        let restored = HexColor.parse(hex)
        #expect(restored != nil, "Round-trip should produce a non-nil color")
        if let restored {
            #expect(
                abs(restored.redComponent - original.redComponent) < 0.01,
                "Red component should survive round-trip"
            )
            #expect(
                abs(restored.greenComponent - original.greenComponent) < 0.01,
                "Green component should survive round-trip"
            )
            #expect(
                abs(restored.blueComponent - original.blueComponent) < 0.01,
                "Blue component should survive round-trip"
            )
        }
    }
}

// MARK: - ThemeColorPreset resolve with Ghostty background Tests

@Suite("ThemeColorPreset resolve with Ghostty background")
struct ThemeColorResolveGhosttyTests {

    @Test("resolve returns ghosttyBackground when preset is ghostty and background provided")
    func resolveGhosttyWithBackground() {
        let bg = NSColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0)
        let result = ThemeColorPreset.resolve(preset: "ghostty", customHex: "", ghosttyBackground: bg)
        let converted = result.usingColorSpace(.sRGB) ?? result
        let bgConverted = bg.usingColorSpace(.sRGB) ?? bg
        #expect(abs(converted.redComponent - bgConverted.redComponent) < 0.01)
        #expect(abs(converted.greenComponent - bgConverted.greenComponent) < 0.01)
        #expect(abs(converted.blueComponent - bgConverted.blueComponent) < 0.01)
    }

    @Test("resolve returns hardcoded ghostty color when preset is ghostty but no background")
    func resolveGhosttyWithoutBackground() {
        let result = ThemeColorPreset.resolve(preset: "ghostty", customHex: "", ghosttyBackground: nil)
        let expected = ThemeColorPreset.ghostty.color
        let r = result.usingColorSpace(.sRGB) ?? result
        let e = expected.usingColorSpace(.sRGB) ?? expected
        #expect(abs(r.redComponent - e.redComponent) < 0.01)
        #expect(abs(r.greenComponent - e.greenComponent) < 0.01)
        #expect(abs(r.blueComponent - e.blueComponent) < 0.01)
    }

    @Test("resolve ignores ghosttyBackground when preset is not ghostty")
    func resolveNonGhosttyIgnoresBackground() {
        let bg = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        let result = ThemeColorPreset.resolve(preset: "original", customHex: "", ghosttyBackground: bg)
        let expected = ThemeColorPreset.original.color
        let r = result.usingColorSpace(.sRGB) ?? result
        let e = expected.usingColorSpace(.sRGB) ?? expected
        #expect(abs(r.redComponent - e.redComponent) < 0.01)
        #expect(abs(r.greenComponent - e.greenComponent) < 0.01)
        #expect(abs(r.blueComponent - e.blueComponent) < 0.01)
    }

    @Test("resolve with default ghosttyBackground nil matches existing behavior")
    func resolveDefaultParameterMatchesExisting() {
        // When ghosttyBackground is omitted (defaults to nil), behavior unchanged
        let result = ThemeColorPreset.resolve(preset: "red", customHex: "")
        let expected = ThemeColorPreset.red.color
        let r = result.usingColorSpace(.sRGB) ?? result
        let e = expected.usingColorSpace(.sRGB) ?? expected
        #expect(abs(r.redComponent - e.redComponent) < 0.01)
    }
}
