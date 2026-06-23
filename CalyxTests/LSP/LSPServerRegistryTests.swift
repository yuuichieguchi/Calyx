//
//  LSPServerRegistryTests.swift
//  Calyx
//
//  Tests for the LSPServerRegistry — the hard-coded data table mapping the
//  15 languages Calyx ships with to their launch command, auto-install
//  command, prerequisite package managers, and detection rules.
//
//  TDD phase: RED. None of the registry types exist yet. This file is
//  expected to fail to compile until the swift-specialist implements them
//  under `Calyx/Features/LSP/LSPServerRegistry.swift`.
//
//  Types under test (all 4 must live in the same file in the implementation):
//    - LSPServerRegistry
//    - LSPServerDefinition
//    - LSPInstallationSpec
//    - LSPPrerequisite
//

import XCTest
@testable import Calyx

final class LSPServerRegistryTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Generate a fresh, isolated temp directory URL per test.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPServerRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Write a JSON string atomically to a file URL and return that URL.
    private func writeJSON(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    // ====================================================================
    // MARK: - builtIn() — completeness & shape
    // ====================================================================

    /// Snapshot of every expected language entry. Test-side source of truth.
    private struct ExpectedEntry {
        let languageId: String
        let displayName: String
        let executable: String
        let arguments: [String]
        let installCommand: String
        let prerequisiteExecutables: [String]
        let prerequisiteInstallCommands: [String?]
        let primaryFileExtension: String
    }

    private let expectedEntries: [ExpectedEntry] = [
        ExpectedEntry(
            languageId: "typescript",
            displayName: "TypeScript / JavaScript",
            executable: "typescript-language-server",
            arguments: ["--stdio"],
            installCommand: "npm install -g typescript-language-server typescript",
            prerequisiteExecutables: ["npm"],
            prerequisiteInstallCommands: ["brew install node"],
            primaryFileExtension: ".ts"
        ),
        ExpectedEntry(
            languageId: "python",
            displayName: "Python",
            executable: "pyright-langserver",
            arguments: ["--stdio"],
            installCommand: "npm install -g pyright",
            prerequisiteExecutables: ["npm"],
            prerequisiteInstallCommands: ["brew install node"],
            primaryFileExtension: ".py"
        ),
        ExpectedEntry(
            languageId: "swift",
            displayName: "Swift / Objective-C / C / C++",
            executable: "xcrun",
            arguments: ["sourcekit-lsp"],
            installCommand: "xcode-select --install",
            prerequisiteExecutables: [],
            prerequisiteInstallCommands: [],
            primaryFileExtension: ".swift"
        ),
        ExpectedEntry(
            languageId: "rust",
            displayName: "Rust",
            executable: "rust-analyzer",
            arguments: [],
            installCommand: "rustup component add rust-analyzer",
            prerequisiteExecutables: ["rustup"],
            prerequisiteInstallCommands: [
                "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            ],
            primaryFileExtension: ".rs"
        ),
        ExpectedEntry(
            languageId: "go",
            displayName: "Go",
            executable: "gopls",
            arguments: ["serve"],
            installCommand: "go install golang.org/x/tools/gopls@latest",
            prerequisiteExecutables: ["go"],
            prerequisiteInstallCommands: ["brew install go"],
            primaryFileExtension: ".go"
        ),
        ExpectedEntry(
            languageId: "ruby",
            displayName: "Ruby",
            executable: "ruby-lsp",
            arguments: [],
            installCommand: "gem install ruby-lsp",
            prerequisiteExecutables: ["gem"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".rb"
        ),
        ExpectedEntry(
            languageId: "java",
            displayName: "Java",
            executable: "jdtls",
            arguments: [],
            installCommand: "brew install jdtls",
            prerequisiteExecutables: ["brew"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".java"
        ),
        ExpectedEntry(
            languageId: "kotlin",
            displayName: "Kotlin",
            executable: "kotlin-language-server",
            arguments: [],
            // The bare `brew install kotlin-language-server` formula does
            // not exist in homebrew/core; the project is distributed via
            // the fwcd/kls tap, so the install command must use the
            // fully-qualified formula path.
            installCommand: "brew install fwcd/kls/kotlin-language-server",
            prerequisiteExecutables: ["brew"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".kt"
        ),
        ExpectedEntry(
            languageId: "php",
            displayName: "PHP",
            executable: "intelephense",
            arguments: ["--stdio"],
            installCommand: "npm install -g intelephense",
            prerequisiteExecutables: ["npm"],
            prerequisiteInstallCommands: ["brew install node"],
            primaryFileExtension: ".php"
        ),
        ExpectedEntry(
            languageId: "csharp",
            displayName: "C#",
            // The `omnisharp` Homebrew formula has been removed; the
            // C# language server now ships as a `dotnet` global tool.
            executable: "csharp-ls",
            arguments: [],
            installCommand: "dotnet tool install -g csharp-ls",
            prerequisiteExecutables: ["dotnet"],
            prerequisiteInstallCommands: ["brew install --cask dotnet-sdk"],
            primaryFileExtension: ".cs"
        ),
        ExpectedEntry(
            languageId: "lua",
            displayName: "Lua",
            executable: "lua-language-server",
            arguments: [],
            installCommand: "brew install lua-language-server",
            prerequisiteExecutables: ["brew"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".lua"
        ),
        ExpectedEntry(
            languageId: "elixir",
            displayName: "Elixir",
            executable: "elixir-ls",
            arguments: [],
            installCommand: "brew install elixir-ls",
            prerequisiteExecutables: ["brew"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".ex"
        ),
        ExpectedEntry(
            languageId: "haskell",
            displayName: "Haskell",
            executable: "haskell-language-server-wrapper",
            arguments: ["--lsp"],
            installCommand: "ghcup install hls",
            prerequisiteExecutables: ["ghcup"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".hs"
        ),
        ExpectedEntry(
            languageId: "zig",
            displayName: "Zig",
            executable: "zls",
            arguments: [],
            installCommand: "brew install zls",
            prerequisiteExecutables: ["brew"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".zig"
        ),
        ExpectedEntry(
            languageId: "ocaml",
            displayName: "OCaml",
            executable: "ocamllsp",
            arguments: [],
            installCommand: "opam install ocaml-lsp-server",
            prerequisiteExecutables: ["opam"],
            prerequisiteInstallCommands: [nil],
            primaryFileExtension: ".ml"
        ),
    ]

    func test_builtIn_containsAllFifteenLanguages() {
        let registry = LSPServerRegistry.builtIn()
        XCTAssertEqual(
            registry.entries.count, 15,
            "Built-in registry must define exactly 15 language entries."
        )
    }

    func test_builtIn_languageIdsAreUnique() {
        let registry = LSPServerRegistry.builtIn()
        let ids = registry.entries.map(\.languageId)
        let unique = Set(ids)
        XCTAssertEqual(
            ids.count, unique.count,
            "Built-in registry must not contain duplicate languageIds. Got: \(ids)"
        )
    }

    func test_builtIn_eachExpectedLanguage_hasCorrectLaunchAndInstall() throws {
        let registry = LSPServerRegistry.builtIn()
        for expected in expectedEntries {
            guard let entry = registry.entry(forLanguageId: expected.languageId) else {
                XCTFail("Missing built-in entry for languageId=\(expected.languageId)")
                continue
            }
            XCTAssertEqual(
                entry.displayName, expected.displayName,
                "displayName mismatch for \(expected.languageId)"
            )
            XCTAssertEqual(
                entry.executable, expected.executable,
                "executable mismatch for \(expected.languageId)"
            )
            XCTAssertEqual(
                entry.arguments, expected.arguments,
                "arguments mismatch for \(expected.languageId)"
            )
            XCTAssertEqual(
                entry.installation.command, expected.installCommand,
                "installation.command mismatch for \(expected.languageId)"
            )
        }
    }

    func test_builtIn_eachExpectedLanguage_hasCorrectPrerequisites() throws {
        let registry = LSPServerRegistry.builtIn()
        for expected in expectedEntries {
            guard let entry = registry.entry(forLanguageId: expected.languageId) else {
                XCTFail("Missing built-in entry for languageId=\(expected.languageId)")
                continue
            }
            let prereqs = entry.installation.prerequisites
            XCTAssertEqual(
                prereqs.count, expected.prerequisiteExecutables.count,
                "Prerequisite count mismatch for \(expected.languageId)"
            )
            for (index, expectedExec) in expected.prerequisiteExecutables.enumerated() {
                guard index < prereqs.count else { break }
                XCTAssertEqual(
                    prereqs[index].executable, expectedExec,
                    "Prerequisite[\(index)] executable mismatch for \(expected.languageId)"
                )
                if index < expected.prerequisiteInstallCommands.count {
                    XCTAssertEqual(
                        prereqs[index].installCommand,
                        expected.prerequisiteInstallCommands[index],
                        "Prerequisite[\(index)] installCommand mismatch for \(expected.languageId)"
                    )
                }
            }
        }
    }

    func test_builtIn_eachEntry_hasNonEmptyFileExtensions() {
        let registry = LSPServerRegistry.builtIn()
        for expected in expectedEntries {
            guard let entry = registry.entry(forLanguageId: expected.languageId) else {
                XCTFail("Missing built-in entry for languageId=\(expected.languageId)")
                continue
            }
            XCTAssertFalse(
                entry.fileExtensions.isEmpty,
                "fileExtensions must be non-empty for \(expected.languageId)"
            )
            XCTAssertTrue(
                entry.fileExtensions.contains(expected.primaryFileExtension),
                "fileExtensions for \(expected.languageId) must contain primary " +
                "extension \(expected.primaryFileExtension); got \(entry.fileExtensions)"
            )
        }
    }

    func test_builtIn_eachEntry_hasNonEmptyWorkspaceMarkers() {
        let registry = LSPServerRegistry.builtIn()
        for expected in expectedEntries {
            guard let entry = registry.entry(forLanguageId: expected.languageId) else {
                XCTFail("Missing built-in entry for languageId=\(expected.languageId)")
                continue
            }
            XCTAssertFalse(
                entry.workspaceMarkers.isEmpty,
                "workspaceMarkers must be non-empty for \(expected.languageId)"
            )
        }
    }

    // ====================================================================
    // MARK: - entry(forLanguageId:) — specific lookups
    // ====================================================================

    func test_entry_forLanguageId_typescript_returnsExpectedCommand() {
        let entry = LSPServerRegistry.builtIn().entry(forLanguageId: "typescript")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.executable, "typescript-language-server")
        XCTAssertEqual(entry?.arguments, ["--stdio"])
        XCTAssertEqual(
            entry?.installation.command,
            "npm install -g typescript-language-server typescript"
        )
    }

    func test_entry_forLanguageId_swift_returnsXcrunSourcekitLsp() {
        let entry = LSPServerRegistry.builtIn().entry(forLanguageId: "swift")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.executable, "xcrun")
        XCTAssertEqual(entry?.arguments, ["sourcekit-lsp"])
        XCTAssertTrue(
            entry?.installation.prerequisites.isEmpty ?? false,
            "Swift has no package-manager prerequisites (ships with Xcode)."
        )
    }

    func test_entry_forLanguageId_rust_hasRustupPrerequisite() throws {
        let entry = try XCTUnwrap(
            LSPServerRegistry.builtIn().entry(forLanguageId: "rust")
        )
        XCTAssertEqual(entry.installation.command, "rustup component add rust-analyzer")
        XCTAssertEqual(entry.installation.prerequisites.count, 1)
        XCTAssertEqual(entry.installation.prerequisites.first?.executable, "rustup")
        XCTAssertEqual(
            entry.installation.prerequisites.first?.installCommand,
            "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        )
    }

    func test_entry_forLanguageId_unknown_returnsNil() {
        let entry = LSPServerRegistry.builtIn().entry(forLanguageId: "fortran")
        XCTAssertNil(entry)
    }

    // ====================================================================
    // MARK: - entry(forFileExtension:) — extension routing
    // ====================================================================

    func test_entry_forFileExtension_routesToCorrectLanguage() throws {
        let registry = LSPServerRegistry.builtIn()
        let cases: [(String, String)] = [
            (".ts",    "typescript"),
            (".py",    "python"),
            (".swift", "swift"),
            (".rs",    "rust"),
            (".go",    "go"),
            (".rb",    "ruby"),
            (".java",  "java"),
            (".kt",    "kotlin"),
            (".php",   "php"),
            (".cs",    "csharp"),
            (".lua",   "lua"),
            (".ex",    "elixir"),
            (".hs",    "haskell"),
            (".zig",   "zig"),
            (".ml",    "ocaml"),
        ]
        for (ext, expectedLanguageId) in cases {
            let entry = registry.entry(forFileExtension: ext)
            XCTAssertEqual(
                entry?.languageId, expectedLanguageId,
                "Extension \(ext) should map to languageId=\(expectedLanguageId), " +
                "got \(String(describing: entry?.languageId))"
            )
        }
    }

    func test_entry_forFileExtension_unknown_returnsNil() {
        let entry = LSPServerRegistry.builtIn().entry(forFileExtension: ".xyz123")
        XCTAssertNil(entry)
    }

    // ====================================================================
    // MARK: - Codable round-trip (for ~/.config/calyx/lsp.json override)
    // ====================================================================

    func test_lspPrerequisite_codableRoundtrip() throws {
        let original = LSPPrerequisite(
            executable: "brew",
            installCommand: "/bin/bash -c \"$(curl -fsSL https://example.com/install.sh)\"",
            manualInstructions: "See https://brew.sh"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LSPPrerequisite.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_lspPrerequisite_codableRoundtrip_withNils() throws {
        let original = LSPPrerequisite(
            executable: "gem",
            installCommand: nil,
            manualInstructions: nil
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LSPPrerequisite.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_lspInstallationSpec_codableRoundtrip() throws {
        let original = LSPInstallationSpec(
            command: "npm install -g typescript-language-server typescript",
            prerequisites: [
                LSPPrerequisite(
                    executable: "npm",
                    installCommand: "brew install node",
                    manualInstructions: nil
                )
            ],
            safeToAutoRun: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LSPInstallationSpec.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_lspServerDefinition_codableRoundtrip() throws {
        let original = LSPServerDefinition(
            languageId: "typescript",
            displayName: "TypeScript / JavaScript",
            executable: "typescript-language-server",
            arguments: ["--stdio"],
            versionArguments: ["--version"],
            fileExtensions: [".ts", ".tsx", ".js", ".jsx"],
            workspaceMarkers: ["tsconfig.json", "package.json"],
            installation: LSPInstallationSpec(
                command: "npm install -g typescript-language-server typescript",
                prerequisites: [
                    LSPPrerequisite(
                        executable: "npm",
                        installCommand: "brew install node",
                        manualInstructions: nil
                    )
                ],
                safeToAutoRun: true
            ),
            defaultInitializationOptions: nil
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LSPServerDefinition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // ====================================================================
    // MARK: - loaded(overridePath:) — user override merging
    // ====================================================================

    func test_loaded_withNilOverridePath_matchesBuiltIn() throws {
        let loaded = try LSPServerRegistry.loaded(overridePath: nil)
        let builtIn = LSPServerRegistry.builtIn()
        XCTAssertEqual(loaded, builtIn)
    }

    func test_loaded_withMissingOverrideFile_matchesBuiltIn() throws {
        let tempDir = try makeTempDir()
        let missing = tempDir.appendingPathComponent("does-not-exist.json")
        let loaded = try LSPServerRegistry.loaded(overridePath: missing)
        let builtIn = LSPServerRegistry.builtIn()
        XCTAssertEqual(loaded, builtIn)
    }

    func test_loaded_withOverride_appendsNewEntry() throws {
        let tempDir = try makeTempDir()
        let overrideURL = tempDir.appendingPathComponent("lsp.json")
        // A brand-new language not in the built-in list.
        let json = """
        {
          "entries": [
            {
              "languageId": "nim",
              "displayName": "Nim",
              "executable": "nimlsp",
              "arguments": [],
              "versionArguments": ["--version"],
              "fileExtensions": [".nim"],
              "workspaceMarkers": ["nim.cfg"],
              "installation": {
                "command": "nimble install nimlsp",
                "prerequisites": [
                  {
                    "executable": "nimble",
                    "installCommand": null,
                    "manualInstructions": "Install via choosenim"
                  }
                ],
                "safeToAutoRun": false
              },
              "defaultInitializationOptions": null
            }
          ]
        }
        """
        try writeJSON(json, to: overrideURL)

        let loaded = try LSPServerRegistry.loaded(overridePath: overrideURL)
        XCTAssertEqual(
            loaded.entries.count, 16,
            "Override that adds 1 entry should produce 15 + 1 = 16 entries."
        )
        let nim = loaded.entry(forLanguageId: "nim")
        XCTAssertNotNil(nim)
        XCTAssertEqual(nim?.executable, "nimlsp")
        XCTAssertEqual(nim?.installation.command, "nimble install nimlsp")
        XCTAssertEqual(nim?.installation.safeToAutoRun, false)

        // Built-in entries must still be present.
        XCTAssertNotNil(loaded.entry(forLanguageId: "typescript"))
        XCTAssertNotNil(loaded.entry(forLanguageId: "swift"))
    }

    func test_loaded_withOverride_replacesExistingLanguageId() throws {
        let tempDir = try makeTempDir()
        let overrideURL = tempDir.appendingPathComponent("lsp.json")
        // Override the built-in TypeScript entry with a different executable.
        let json = """
        {
          "entries": [
            {
              "languageId": "typescript",
              "displayName": "TypeScript (custom)",
              "executable": "vtsls",
              "arguments": ["--stdio"],
              "versionArguments": ["--version"],
              "fileExtensions": [".ts", ".tsx"],
              "workspaceMarkers": ["tsconfig.json"],
              "installation": {
                "command": "npm install -g @vtsls/language-server",
                "prerequisites": [
                  {
                    "executable": "npm",
                    "installCommand": "brew install node",
                    "manualInstructions": null
                  }
                ],
                "safeToAutoRun": true
              },
              "defaultInitializationOptions": null
            }
          ]
        }
        """
        try writeJSON(json, to: overrideURL)

        let loaded = try LSPServerRegistry.loaded(overridePath: overrideURL)
        XCTAssertEqual(
            loaded.entries.count, 15,
            "Override that replaces an existing entry must not change the total count."
        )
        let ts = loaded.entry(forLanguageId: "typescript")
        XCTAssertEqual(ts?.executable, "vtsls",
                       "Override must replace the built-in executable.")
        XCTAssertEqual(ts?.displayName, "TypeScript (custom)")
        XCTAssertEqual(
            ts?.installation.command,
            "npm install -g @vtsls/language-server"
        )
    }

    func test_loaded_withMalformedJSON_throws() throws {
        let tempDir = try makeTempDir()
        let overrideURL = tempDir.appendingPathComponent("lsp.json")
        try writeJSON("{ this is not valid json", to: overrideURL)

        XCTAssertThrowsError(
            try LSPServerRegistry.loaded(overridePath: overrideURL),
            "Malformed override JSON must throw."
        )
    }

    // ====================================================================
    // MARK: - loaded(overridePath:) — symlink redirect rejection
    // ====================================================================

    /// The override file's `executable` field is spawned directly by the
    /// LSP proxy. If `loaded(overridePath:)` followed symlinks, any
    /// process with write access to the link's destination could redirect
    /// Calyx into launching an attacker-controlled binary. All other
    /// config managers (Claude / Codex / OpenCode / Hermes) reject
    /// symlinks via `ConfigFileUtils.isSymlink(at:)`; the LSP registry
    /// must do the same.
    func test_loaded_symlinkOverride_throws() throws {
        let tempDir = try makeTempDir()
        let target = tempDir.appendingPathComponent("real-override.json")
        let link = tempDir.appendingPathComponent("symlink-override.json")
        try writeJSON(#"{"entries":[]}"#, to: target)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target
        )

        XCTAssertThrowsError(
            try LSPServerRegistry.loaded(overridePath: link),
            "Symlinked override path must be rejected."
        ) { error in
            guard case LSPServerRegistryError.symlinkRedirect(let url) = error
            else {
                XCTFail(
                    "Expected LSPServerRegistryError.symlinkRedirect, " +
                    "got \(error)"
                )
                return
            }
            XCTAssertEqual(url, link)
        }
    }
}
