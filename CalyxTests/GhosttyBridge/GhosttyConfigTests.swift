// GhosttyConfigTests.swift
// CalyxTests
//
// Tests for GhosttyConfigManager preset template and migration helpers.
// Verifies deprecated keys are removed from preset and existing configs.

import Testing
@testable import Calyx

@MainActor
@Suite("GhosttyConfig Tests")
struct GhosttyConfigTests {

    // MARK: - Preset Template Tests

    @Test("Glass preset template does not contain cursor-click-to-move")
    func glassPresetTemplateDoesNotContainCursorClickToMove() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("cursor-click-to-move"),
                "Glass preset template should not contain cursor-click-to-move (ghostty default is used)")
    }

    @Test("Glass preset template does not contain font-thicken")
    func glassPresetTemplateDoesNotContainFontThicken() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("font-thicken"),
                "Glass preset template should not contain font-thicken (ghostty default is used)")
    }

    @Test("Glass preset template does not contain minimum-contrast")
    func glassPresetTemplateDoesNotContainMinimumContrast() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("minimum-contrast"),
                "Glass preset template should not contain minimum-contrast (ghostty default is used)")
    }

    // MARK: - Migration Tests

    @Test("removeCursorClickToMoveLine removes 'cursor-click-to-move = true'")
    func removeCursorClickToMoveLineRemovesTrue() {
        let input = """
        # --- Calyx Glass Preset (managed) ---
        background-opacity = 0.82
        cursor-click-to-move = true
        # --- End Calyx Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("# --- Calyx Glass Preset (managed) ---"))
        #expect(result.contains("# --- End Calyx Glass Preset ---"))
    }

    @Test("removeCursorClickToMoveLine removes 'cursor-click-to-move = false'")
    func removeCursorClickToMoveLineRemovesFalse() {
        let input = """
        # --- Calyx Glass Preset (managed) ---
        background-opacity = 0.82
        cursor-click-to-move = false
        # --- End Calyx Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeCursorClickToMoveLine is no-op when line is absent")
    func removeCursorClickToMoveLineNoOpWhenAbsent() {
        let input = """
        # --- Calyx Glass Preset (managed) ---
        background-opacity = 0.82
        # --- End Calyx Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(result == input)
    }

    @Test("removeCursorClickToMoveLine handles extra whitespace")
    func removeCursorClickToMoveLineHandlesExtraWhitespace() {
        let input = "  cursor-click-to-move = true  \nbackground-opacity = 0.82\n"
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    // MARK: - removeConfigKeys Tests

    @Test("removeConfigKeys removes exact key matches")
    func removeConfigKeysRemovesExactKeyMatch() {
        let input = """
        background-opacity = 0.82
        font-thicken = true
        background-blur = macos-glass-regular
        minimum-contrast = 1.5
        background-opacity-cells = false
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(!result.contains("minimum-contrast"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("background-blur = macos-glass-regular"))
        #expect(result.contains("background-opacity-cells = false"))
    }

    @Test("removeConfigKeys preserves comment lines containing key names")
    func removeConfigKeysPreservesCommentLines() {
        let input = """
        # font-thicken = true
        background-opacity = 0.82
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(result.contains("# font-thicken = true"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeConfigKeys handles leading and trailing whitespace")
    func removeConfigKeysHandlesLeadingTrailingWhitespace() {
        let input = "  font-thicken = true  \nbackground-opacity = 0.82\n"
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeConfigKeys is no-op when target keys are absent")
    func removeConfigKeysNoOpWhenKeysAbsent() {
        let input = """
        background-opacity = 0.82
        background-blur = macos-glass-regular
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast"], from: input
        )
        #expect(result == input)
    }

    @Test("removeConfigKeys preserves blank lines")
    func removeConfigKeysPreservesBlankLines() {
        let input = "background-opacity = 0.82\n\nbackground-blur = macos-glass-regular\n"
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(result == input)
    }

    // MARK: - File-Backed Migration Test

    @Test("removeConfigKeys migrates old format file correctly")
    func removeConfigKeysMigratesOldFormatFile() {
        let input = """
        # --- Calyx Glass Preset (managed) ---
        background-opacity = 0.82
        background-blur = macos-glass-regular
        font-thicken = true
        minimum-contrast = 1.5
        # --- End Calyx Glass Preset ---
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast", "cursor-click-to-move"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(!result.contains("minimum-contrast"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("background-blur = macos-glass-regular"))
        #expect(result.contains("# --- Calyx Glass Preset (managed) ---"))
        #expect(result.contains("# --- End Calyx Glass Preset ---"))
    }

    // MARK: - Managed Keys Tests

    @Test("managedKeys contains all expected keys")
    func managedKeysContainsExpectedKeys() {
        let expectedKeys = [
            "background-opacity",
            "background-blur",
            "background-opacity-cells",
            "foreground",
        ]
        let managed = GhosttyConfigManager.managedKeys
        for key in expectedKeys {
            #expect(managed.contains(key), "managedKeys should contain '\(key)'")
        }
        #expect(!managed.contains("font-codepoint-map"), "font-codepoint-map must not be a Calyx-managed key (#50)")
    }

    @Test("managedKeys has no duplicates")
    func managedKeysHasNoDuplicates() {
        let managed = GhosttyConfigManager.managedKeys
        let uniqueSet = Set(managed)
        #expect(managed.count == uniqueSet.count,
                "managedKeys has \(managed.count - uniqueSet.count) duplicate(s)")
    }

    @Test("managedKeys covers all keys from glassPresetTemplate")
    func managedKeysCoverGlassPresetTemplate() {
        let template = GhosttyConfigManager.glassPresetTemplate
        let managed = Set(GhosttyConfigManager.managedKeys)

        // Parse key=value lines from the template (skip comments and blank lines)
        let templateKeys = template
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> String? in
                guard let eqIndex = line.firstIndex(of: "=") else { return nil }
                return line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            }

        #expect(!templateKeys.isEmpty, "Should have parsed at least one key from glassPresetTemplate")
        for key in templateKeys {
            #expect(managed.contains(key),
                    "managedKeys should contain glass preset key '\(key)'")
        }
    }

    @Test("managedKeys covers all keys from applyRuntimeOverrides output")
    func managedKeysCoverRuntimeOverrides() {
        // The runtime override text is generated inside applyRuntimeOverrides.
        // We verify against the known keys it produces. These are the key names
        // that appear as "key = value" lines in the runtime override block.
        let runtimeKeys = [
            "background-opacity",
            "background-blur",
            "background-opacity-cells",
        ]

        let managed = Set(GhosttyConfigManager.managedKeys)
        for key in runtimeKeys {
            #expect(managed.contains(key),
                    "managedKeys should contain runtime override key '\(key)'")
        }
    }
}

// MARK: - foregroundOverrideLine Tests

@MainActor
@Suite("GhosttyConfigManager.foregroundOverrideLine Tests")
struct GhosttyConfigForegroundOverrideTests {

    @Test("Dark preset returns foreground = #FFFFFF")
    func darkPresetReturnsWhiteForeground() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "original",
            customHex: "#000000",
            glassOpacity: 0.7
        )
        #expect(result == "foreground = #FFFFFF",
                "Dark preset 'original' at default opacity should return white foreground")
    }

    @Test("Light custom color returns foreground = #000000")
    func lightCustomReturnsBlackForeground() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 0.7
        )
        #expect(result == "foreground = #000000",
                "Light custom #F0F0F0 at default opacity should return black foreground")
    }

    @Test("Ghostty preset returns nil (no override)")
    func ghosttyPresetReturnsNil() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "ghostty",
            customHex: "#AABBCC",
            glassOpacity: 0.5
        )
        #expect(result == nil,
                "Ghostty preset should return nil (foreground managed by user's ghostty config)")
    }

    @Test("Opacity affects foreground decision for light color")
    func opacityAffectsForegroundDecision() {
        // At opacity 0.0, the effective tint is nearly transparent over a dark base,
        // so the result should differ from opacity 1.0 where the color is fully opaque.
        let resultAtZero = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 0.0
        )
        let resultAtOne = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 1.0
        )
        #expect(resultAtZero != resultAtOne,
                "Opacity 0.0 vs 1.0 should produce different foreground decisions for #F0F0F0")
    }
}

// MARK: - runtimeOverrideText Tests
//
// Proposed API:
//
//   static func runtimeOverrideText(
//       glassOpacity: Double,
//       opacityCells: Bool,
//       preset: String,
//       customHex: String
//   ) -> String
//
// Pure extraction of the text-generation inlined in
// applyRuntimeOverrides(_:) (GhosttyConfig.swift). Builds the
// managed block plus, when foregroundOverrideLine(preset:customHex:glassOpacity:)
// is non-nil, an appended "\nforeground = ..." line.

@MainActor
@Suite("GhosttyConfigManager.runtimeOverrideText Tests")
struct GhosttyConfigRuntimeOverrideTextTests {

    // Every field in this block is determined by the spec, not by reading
    // the current inline implementation: 0.7 formats as "0.700" under
    // "%.3f", "ghostty" preset makes foregroundOverrideLine return nil
    // (pinned above by ghosttyPresetReturnsNil), so this is the complete,
    // exact output for that input with no trailing foreground line and no
    // trailing newline (the call site appends its own "\n" before writing).
    @Test("Exact output for glassOpacity 0.7, opacityCells false, ghostty preset")
    func exactOutputForCanonicalInputs() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let expected = """
        # --- Calyx Runtime Override (managed) ---
        background-opacity = 0.700
        background-blur = macos-glass-regular
        background-opacity-cells = false
        # --- End Calyx Runtime Override ---
        """
        #expect(result == expected,
                "runtimeOverrideText must produce exactly this managed block for the canonical inputs")
    }

    @Test("opacityCells true emits the exact line 'background-opacity-cells = true'")
    func opacityCellsTrueEmitsTrueLine() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: true,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let lines = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("background-opacity-cells = true"),
                "opacityCells: true must produce the exact line 'background-opacity-cells = true'")
        #expect(!lines.contains("background-opacity-cells = false"))
    }

    @Test("opacityCells false emits the exact line 'background-opacity-cells = false'")
    func opacityCellsFalseEmitsFalseLine() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let lines = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("background-opacity-cells = false"),
                "opacityCells: false must produce the exact line 'background-opacity-cells = false'")
        #expect(!lines.contains("background-opacity-cells = true"))
    }

    @Test("glassOpacity formats with three decimal places in the background-opacity line")
    func glassOpacityFormatsWithThreeDecimals() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.5,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let lines = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("background-opacity = 0.500"),
                "glassOpacity 0.5 must format as 'background-opacity = 0.500'")
    }

    @Test("glassOpacity below 0.0 is clamped to 0.000")
    func glassOpacityClampsBelowZero() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: -0.5,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let lines = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("background-opacity = 0.000"),
                "glassOpacity -0.5 must clamp to 'background-opacity = 0.000'")
    }

    @Test("glassOpacity above 1.0 is clamped to 1.000")
    func glassOpacityClampsAboveOne() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 1.5,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let lines = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("background-opacity = 1.000"),
                "glassOpacity 1.5 must clamp to 'background-opacity = 1.000'")
    }

    @Test("Managed block start and end comment lines are present")
    func managedBlockCommentsPresent() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        #expect(result.contains("# --- Calyx Runtime Override (managed) ---"))
        #expect(result.contains("# --- End Calyx Runtime Override ---"))
    }

    @Test("No font-codepoint-map lines are emitted (#50)")
    func noFontCodepointMapLines() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        let mapLineCount = result.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("font-codepoint-map = ") }
            .count
        #expect(mapLineCount == 0,
                "No font-codepoint-map lines may be emitted (#50), found \(mapLineCount)")
    }

    // "original" at glassOpacity 0.7 is pinned by darkPresetReturnsWhiteForeground
    // above to yield "foreground = #FFFFFF", so a non-"ghostty" preset must append
    // that exact line after the managed block.
    @Test("Non-ghostty preset appends the exact foreground override line")
    func nonGhosttyPresetAppendsForegroundLine() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "original",
            customHex: "#000000"
        )
        #expect(result.hasSuffix("\nforeground = #FFFFFF"),
                "A non-ghostty preset must append '\\nforeground = #FFFFFF' after the managed block")
    }

    @Test("ghostty preset appends no foreground line")
    func ghosttyPresetAppendsNoForegroundLine() {
        let result = GhosttyConfigManager.runtimeOverrideText(
            glassOpacity: 0.7,
            opacityCells: false,
            preset: "ghostty",
            customHex: "#AABBCC"
        )
        #expect(!result.contains("foreground ="),
                "The ghostty preset must not append a foreground override line")
    }
}
