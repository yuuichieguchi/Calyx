//
//  LSPServerRegistryBugSpecTests.swift
//  Calyx
//
//  Regression tests pinning four bugs in `LSPServerRegistry.builtIn()`:
//
//    1. Swift entry's "is installed?" probe uses `executable: "xcrun"`,
//       which is always present on macOS. The current installed-ness
//       check (in `LSPInstaller.checkInstallation`) therefore reports
//       Swift as installed on every Mac, even when the actual
//       sourcekit-lsp Xcode component is missing. The fix introduces
//       a new `InstallationProbe` value on the entry that asks
//       `xcrun -f sourcekit-lsp` and requires exit 0 for "installed".
//
//    2. C# entry installs via `brew install omnisharp`, but the
//       `omnisharp` formula no longer exists in homebrew/core, so the
//       install command can never succeed. The fix switches the C#
//       server to `csharp-ls` installed via `dotnet tool install -g
//       csharp-ls`, with `dotnet` as the (new) prerequisite.
//
//    3. Kotlin entry installs via bare `brew install
//       kotlin-language-server`, but there is no such formula in
//       homebrew/core; the project lives in the fwcd/kls tap. The fix
//       switches the command to use the fully-qualified tap path
//       (`brew install fwcd/kls/kotlin-language-server`).
//
//    4. PHP / Intelephense ships under a commercial license that is
//       free for evaluation only. The registry currently surfaces no
//       indication of this to the user. The fix adds a `note: String?`
//       field on `LSPServerDefinition` that the PHP entry uses to
//       declare its license / trial caveat.
//
//  TDD phase: RED. Until the fixes land:
//    * Bug 1 and Bug 4 reference symbols / members that do not exist
//      on the current `LSPServerRegistry.swift` (`installationCheck`,
//      `InstallationProbe`, `note`). Those tests therefore fail to
//      compile — and compile failure IS the RED signal per the bug
//      spec for this file.
//    * Bug 2 and Bug 3 are runtime assertions that would also fail
//      if the file did compile, because the built-in table still
//      ships the broken brew commands.
//
//  This file MUST fail (compile or runtime) against the current
//  production `LSPServerRegistry.swift`. Do not soften any assertion
//  to make it "pass" against the buggy registry.
//

import XCTest
@testable import Calyx

final class LSPServerRegistryBugSpecTests: XCTestCase {

    // MARK: - Helpers

    private func swiftEntry() throws -> LSPServerDefinition {
        try XCTUnwrap(
            LSPServerRegistry.builtIn().entry(forLanguageId: "swift"),
            "Built-in registry must contain a Swift entry."
        )
    }

    private func csharpEntry() throws -> LSPServerDefinition {
        try XCTUnwrap(
            LSPServerRegistry.builtIn().entry(forLanguageId: "csharp"),
            "Built-in registry must contain a C# entry."
        )
    }

    private func kotlinEntry() throws -> LSPServerDefinition {
        try XCTUnwrap(
            LSPServerRegistry.builtIn().entry(forLanguageId: "kotlin"),
            "Built-in registry must contain a Kotlin entry."
        )
    }

    private func phpEntry() throws -> LSPServerDefinition {
        try XCTUnwrap(
            LSPServerRegistry.builtIn().entry(forLanguageId: "php"),
            "Built-in registry must contain a PHP entry."
        )
    }

    // ====================================================================
    // MARK: - Bug 1: Swift `xcrun` false-positive installed-ness
    // ====================================================================
    //
    // The current Swift entry sets `executable = "xcrun"`. The installer's
    // probe is `runner.locate("xcrun")` — which always succeeds on macOS,
    // regardless of whether sourcekit-lsp is actually available. The fix
    // introduces an explicit `InstallationProbe` value the installer
    // consults instead of (or in addition to) the launch executable.
    //
    // Required post-fix shape for the Swift entry:
    //
    //     installationCheck: .command(
    //         executable: "xcrun",
    //         arguments: ["-f", "sourcekit-lsp"],
    //         expectExit0: true
    //     )
    //
    // The integration test below uses MockCommandRunner to confirm that,
    // given xcrun is locatable but `xcrun -f sourcekit-lsp` exits
    // non-zero, the installation check reports NOT installed.

    /// Asserts the Swift entry's `installationCheck` field equals the
    /// expected `.command(...)` probe (the new, intended shape). This
    /// test currently fails to compile because neither `installationCheck`
    /// nor `InstallationProbe` exists on the production types — compile
    /// failure IS the RED signal here.
    func test_bug1_swift_installationCheck_isXcrunFindSourceKitLSPCommand() throws {
        let entry = try swiftEntry()
        let expected = InstallationProbe.command(
            executable: "xcrun",
            arguments: ["-f", "sourcekit-lsp"],
            expectExit0: true
        )
        XCTAssertEqual(
            entry.installationCheck,
            expected,
            "Swift's installed-ness must be checked via `xcrun -f sourcekit-lsp`, " +
            "not via mere existence of `xcrun` (which always exists on macOS)."
        )
    }

    /// End-to-end behavioural assertion driven through MockCommandRunner:
    /// `xcrun` is locatable but `xcrun -f sourcekit-lsp` exits non-zero,
    /// so `checkInstallation(forLanguageId: "swift")` must report
    /// `isInstalled == false`. This pins the actual user-visible bug:
    /// the registry must not produce a false "installed" verdict on
    /// machines without the sourcekit-lsp Xcode component.
    func test_bug1_swift_checkInstallation_reportsNotInstalled_whenXcrunFSourceKitLSPExitsNonZero() async throws {
        let runner = MockCommandRunner()
        // xcrun itself is locatable on every Mac.
        await runner.setLocateResult("xcrun", url: URL(fileURLWithPath: "/usr/bin/xcrun"))
        // But `xcrun -f sourcekit-lsp` fails on machines without the
        // sourcekit-lsp Xcode component.
        await runner.enqueueRunResult(
            "xcrun",
            result: .success(
                CommandResult(
                    exitCode: 72,
                    stdout: "",
                    stderr: "xcrun: error: unable to find utility \"sourcekit-lsp\""
                )
            )
        )

        let installer = LSPInstaller(
            registry: LSPServerRegistry.builtIn(),
            runner: runner
        )
        let check = await installer.checkInstallation(forLanguageId: "swift")
        XCTAssertFalse(
            check.isInstalled,
            "Swift must NOT be reported as installed when " +
            "`xcrun -f sourcekit-lsp` exits non-zero."
        )
    }

    // ====================================================================
    // MARK: - Bug 2: C# entry uses defunct `brew install omnisharp`
    // ====================================================================
    //
    // The `omnisharp` Homebrew formula has been removed. The replacement
    // is `csharp-ls`, installed via `dotnet tool install -g csharp-ls`,
    // and the prerequisite is `dotnet` (not `brew`).

    func test_bug2_csharp_installCommand_isDotnetToolInstallCsharpLS() throws {
        let entry = try csharpEntry()
        XCTAssertEqual(
            entry.installation.command,
            "dotnet tool install -g csharp-ls",
            "C# must install via `dotnet tool install -g csharp-ls`; " +
            "the legacy `brew install omnisharp` formula no longer exists."
        )
    }

    func test_bug2_csharp_executable_isCsharpLS() throws {
        let entry = try csharpEntry()
        XCTAssertEqual(
            entry.executable,
            "csharp-ls",
            "C# must launch the `csharp-ls` binary; `omnisharp` is no " +
            "longer the shipped C# language server."
        )
    }

    func test_bug2_csharp_prerequisites_includeDotnet() throws {
        let entry = try csharpEntry()
        let executables = entry.installation.prerequisites.map(\.executable)
        XCTAssertTrue(
            executables.contains("dotnet"),
            "C# install requires `dotnet` on PATH; got prerequisites = \(executables)."
        )
        XCTAssertFalse(
            executables.contains("brew"),
            "C# must no longer list `brew` as a prerequisite — the " +
            "install command no longer goes through Homebrew."
        )
    }

    // ====================================================================
    // MARK: - Bug 3: Kotlin uses bare brew formula not in homebrew/core
    // ====================================================================
    //
    // `brew install kotlin-language-server` fails because no such
    // formula exists in homebrew/core. The kotlin-language-server
    // project is distributed via the fwcd/kls tap, so the install
    // command must use the fully-qualified tap path
    // `fwcd/kls/kotlin-language-server`.

    func test_bug3_kotlin_installCommand_usesFwcdKlsTap() throws {
        let entry = try kotlinEntry()
        let command = entry.installation.command
        XCTAssertTrue(
            command.contains("fwcd/kls/kotlin-language-server"),
            "Kotlin install command must reference the fwcd/kls tap with " +
            "its fully-qualified formula path " +
            "`fwcd/kls/kotlin-language-server`; got \(command)."
        )
        XCTAssertNotEqual(
            command,
            "brew install kotlin-language-server",
            "Bare `brew install kotlin-language-server` does not resolve " +
            "in homebrew/core and must be replaced with the tap-qualified form."
        )
    }

    // ====================================================================
    // MARK: - Bug 4: PHP / Intelephense license note is not surfaced
    // ====================================================================
    //
    // Intelephense is a commercial product whose npm package is free
    // for evaluation only. The registry must expose this caveat to
    // the user via a new optional `note` field on `LSPServerDefinition`.

    /// Pins the existence and content of the new `note` field on the PHP
    /// entry. This test currently fails to compile because
    /// `LSPServerDefinition` does not yet declare a `note` member —
    /// compile failure IS the RED signal.
    func test_bug4_php_note_mentionsLicenseOrTrial() throws {
        let entry = try phpEntry()
        let note = try XCTUnwrap(
            entry.note,
            "PHP / Intelephense must declare a non-nil `note` describing " +
            "its commercial / evaluation-only licensing."
        )
        let lower = note.lowercased()
        XCTAssertTrue(
            lower.contains("license") || lower.contains("trial"),
            "PHP entry's `note` must mention `license` or `trial` so the " +
            "user is warned about Intelephense's evaluation-only terms; " +
            "got: \(note)"
        )
    }
}
