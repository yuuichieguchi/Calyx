// DiffLayoutSettingsResolverTests.swift
// CalyxTests
//
// Tests for DiffLayoutSettings.effectiveLayout and DiffLayoutPreference
// (VS Code renderSideBySide / useInlineViewWhenSpaceIsLimited /
// renderSideBySideInlineBreakpoint = 900).

import CoreGraphics
import Testing
@testable import Calyx

@Suite("DiffLayoutSettings resolver")
struct DiffLayoutSettingsResolverTests {

    @Test func breakpointIs900() {
        #expect(DiffLayoutSettings.sideBySideInlineBreakpoint == 900)
    }

    @Test(arguments: [CGFloat(0), 500, 900, 901, 2000])
    func inlinePreference_ignoresWidth(width: CGFloat) {
        #expect(DiffLayoutSettings.effectiveLayout(preference: .inline, width: width) == .inline)
    }

    @Test(arguments: [CGFloat(0), 500, 900, 901, 2000])
    func sideBySidePreference_ignoresWidth(width: CGFloat) {
        #expect(DiffLayoutSettings.effectiveLayout(preference: .sideBySide, width: width) == .sideBySide)
    }

    @Test func automatic_inlineAtOrBelowBreakpoint() {
        #expect(DiffLayoutSettings.effectiveLayout(preference: .automatic, width: 0) == .inline)
        #expect(DiffLayoutSettings.effectiveLayout(preference: .automatic, width: 900) == .inline)
    }

    @Test func automatic_sideBySideAboveBreakpoint() {
        #expect(DiffLayoutSettings.effectiveLayout(preference: .automatic, width: 901) == .sideBySide)
        #expect(DiffLayoutSettings.effectiveLayout(preference: .automatic, width: 2000) == .sideBySide)
    }

    @Test func toggledInline() {
        #expect(DiffLayoutPreference.automatic.toggledInline == .inline)
        #expect(DiffLayoutPreference.sideBySide.toggledInline == .inline)
        #expect(DiffLayoutPreference.inline.toggledInline == .sideBySide)
    }

    @Test func allCasesOrder() {
        #expect(DiffLayoutPreference.allCases == [.automatic, .inline, .sideBySide])
    }

    @Test func displayNames() {
        #expect(DiffLayoutPreference.automatic.displayName == "Automatic")
        #expect(DiffLayoutPreference.inline.displayName == "Inline")
        #expect(DiffLayoutPreference.sideBySide.displayName == "Side by Side")
    }
}
