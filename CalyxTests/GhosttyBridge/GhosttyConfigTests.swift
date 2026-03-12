// GhosttyConfigTests.swift
// CalyxTests
//
// Tests for GhosttyConfigManager preset template and migration helpers.
// Verifies cursor-click-to-move is removed from preset and existing configs.

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

    // MARK: - Managed Keys Tests

    @Test("managedKeys contains all expected keys")
    func managedKeysContainsExpectedKeys() {
        let expectedKeys = [
            "background-opacity",
            "background-blur",
            "font-thicken",
            "minimum-contrast",
            "background-opacity-cells",
            "font-codepoint-map",
        ]
        let managed = GhosttyConfigManager.managedKeys
        for key in expectedKeys {
            #expect(managed.contains(key), "managedKeys should contain '\(key)'")
        }
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
            "font-codepoint-map",
        ]

        let managed = Set(GhosttyConfigManager.managedKeys)
        for key in runtimeKeys {
            #expect(managed.contains(key),
                    "managedKeys should contain runtime override key '\(key)'")
        }
    }
}
