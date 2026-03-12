//
//  InstallSourceTests.swift
//  CalyxTests
//
//  TDD red-phase tests for InstallSource.
//  InstallSource determines whether the app was installed via
//  Homebrew Cask or direct download by resolving symlinks and
//  checking path components for /Caskroom/calyx/.
//

import Foundation
import Testing
@testable import Calyx

@MainActor
@Suite("InstallSource Tests")
struct InstallSourceTests {

    // MARK: - Homebrew detection

    @Test("Homebrew ARM path detected as .homebrew")
    func homebrewArmPath() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/calyx/0.3.5/Calyx.app")
        )
        #expect(source.source == .homebrew)
        #expect(source.isHomebrew == true)
    }

    @Test("Homebrew Intel path detected as .homebrew")
    func homebrewIntelPath() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/usr/local/Caskroom/calyx/0.3.5/Calyx.app")
        )
        #expect(source.source == .homebrew)
        #expect(source.isHomebrew == true)
    }

    // MARK: - Direct download detection

    @Test("/Applications path detected as .direct")
    func applicationsPath() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/Applications/Calyx.app")
        )
        #expect(source.source == .direct)
        #expect(source.isHomebrew == false)
    }

    @Test("Random user path detected as .direct")
    func randomUserPath() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/Users/test/Desktop/Calyx.app")
        )
        #expect(source.source == .direct)
        #expect(source.isHomebrew == false)
    }

    // MARK: - Token-based matching (not substring)

    @Test("Different cask name in Caskroom detected as .direct")
    func differentCaskName() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/other-app/1.0/Calyx.app")
        )
        #expect(source.source == .direct)
        #expect(source.isHomebrew == false)
    }

    // MARK: - Edge cases

    @Test("URL with trailing slashes handled correctly")
    func trailingSlashes() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/calyx/0.3.5/Calyx.app/")
        )
        #expect(source.source == .homebrew)
        #expect(source.isHomebrew == true)
    }

    @Test("Caskroom/calyx directory without app name detected as .homebrew")
    func caskroomDirectoryOnly() {
        let source = InstallSource(
            bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/calyx/")
        )
        #expect(source.source == .homebrew)
        #expect(source.isHomebrew == true)
    }
}
