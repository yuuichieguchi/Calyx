//
//  LSPServerRegistryBugSpecGroupBTests.swift
//  Calyx
//
//  Regression tests pinning two structural bugs in
//  `LSPServerRegistry.builtIn()` related to launcher / version-flag
//  discovery:
//
//    1. The Java entry hardcodes `executable: "jdtls"` and the default
//       `installationCheck: .which(name: "jdtls")`. In practice the
//       community installs the JDT language server under multiple
//       launcher names — Coursier ships it as `jdt-language-server`;
//       script-based installs land at
//       `~/.local/share/eclipse.jdt.ls/bin/jdtls`; the binary itself is
//       conventionally named `eclipse.jdt.ls` in some packagings.
//       Locking the probe to a single `which("jdtls")` causes
//       `lsp_check_installation` to report Java as "not installed" for
//       users with perfectly valid Coursier-based installs.
//
//       FIX SPEC: add a fallback chain at the entry level — e.g. a new
//       `executableCandidates: [String]` field — so the registry can
//       probe multiple known launcher names. Concrete fallback chain:
//       `["jdtls", "jdt-language-server", "eclipse.jdt.ls"]`.
//
//    2. The Go entry uses `versionArguments: ["version"]` (a positional
//       subcommand) while every other entry uses `["--version"]`.
//       gopls's CLI flag surface has churned across versions; some
//       releases expect `gopls version`, others `gopls --version`, and
//       older builds support both. The single hardcoded form is brittle.
//
//       FIX SPEC: add a list-of-candidates field — e.g. a new
//       `versionArgumentCandidates: [[String]]` — and probe each in
//       order; accept the first that exits 0 with non-empty stdout.
//       The Go entry's list must include both `["--version"]` AND
//       `["version"]`.
//
//  TDD phase: RED. Until the fixes land, these tests reference symbols
//  (`executableCandidates`, `versionArgumentCandidates`) that do not
//  exist on the current `LSPServerRegistry.swift`. The file therefore
//  FAILS TO COMPILE — and compile failure IS the RED signal per the
//  bug spec.
//
//  This file MUST fail (compile or runtime) against the current
//  production `LSPServerRegistry.swift`. Do not soften any assertion
//  to make it "pass" against the buggy registry.
//

import XCTest
@testable import Calyx

final class LSPServerRegistryBugSpecGroupBTests: XCTestCase {

    // MARK: - Bug 1: Java executable fallback chain

    /// Java entry must expose a structural fallback API listing every
    /// known launcher name for the JDT language server, not just a
    /// single hardcoded `executable`.
    ///
    /// The Java entry's candidate list MUST include AT LEAST `"jdtls"`
    /// and `"jdt-language-server"` so that Coursier-based installs are
    /// detected by `lsp_check_installation`.
    ///
    /// RED signal: until `LSPServerDefinition` grows an
    /// `executableCandidates: [String]` field, this test fails to
    /// compile.
    func test_java_entry_hasFallbackExecutableCandidates() throws {
        let registry = LSPServerRegistry.builtIn()
        guard let java = registry.entry(forLanguageId: "java") else {
            XCTFail("Java entry missing from built-in registry")
            return
        }

        // This member access is what makes the RED phase a compile
        // failure: `executableCandidates` does not exist yet on
        // `LSPServerDefinition`. After the fix, this read should
        // return the full fallback chain.
        let candidates: [String] = java.executableCandidates

        XCTAssertTrue(
            candidates.contains("jdtls"),
            "Java fallback chain must include the canonical `jdtls` " +
            "launcher name; got \(candidates)"
        )
        XCTAssertTrue(
            candidates.contains("jdt-language-server"),
            "Java fallback chain must include `jdt-language-server` " +
            "(Coursier's binary name); got \(candidates)"
        )
        XCTAssertGreaterThanOrEqual(
            candidates.count, 2,
            "Java fallback chain must list at least two launcher " +
            "names; got \(candidates)"
        )
    }

    // MARK: - Bug 2: gopls multiple version-probe arg sets

    /// Go entry must expose a structural way to declare multiple
    /// version-probe argument lists so the health-check probe is
    /// resilient to gopls's churning CLI surface.
    ///
    /// The Go entry's candidate list MUST include BOTH `["--version"]`
    /// AND `["version"]` so that any gopls release Calyx encounters can
    /// be successfully version-probed.
    ///
    /// RED signal: until `LSPServerDefinition` grows a
    /// `versionArgumentCandidates: [[String]]` field, this test fails
    /// to compile.
    func test_gopls_entry_probesMultipleVersionFlags() throws {
        let registry = LSPServerRegistry.builtIn()
        guard let go = registry.entry(forLanguageId: "go") else {
            XCTFail("Go entry missing from built-in registry")
            return
        }

        // This member access is what makes the RED phase a compile
        // failure: `versionArgumentCandidates` does not exist yet on
        // `LSPServerDefinition`. After the fix, this read should
        // return the full candidate list of arg sets.
        let candidates: [[String]] = go.versionArgumentCandidates

        XCTAssertTrue(
            candidates.contains(["--version"]),
            "Go version-probe candidates must include `[\"--version\"]`; " +
            "got \(candidates)"
        )
        XCTAssertTrue(
            candidates.contains(["version"]),
            "Go version-probe candidates must include `[\"version\"]`; " +
            "got \(candidates)"
        )
        XCTAssertGreaterThanOrEqual(
            candidates.count, 2,
            "Go version-probe must list at least two candidate arg " +
            "sets; got \(candidates)"
        )
    }
}
