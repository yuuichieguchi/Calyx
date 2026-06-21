//
//  LSPServerRegistry.swift
//  Calyx
//
//  Hard-coded data table mapping the 15 languages Calyx ships with to
//  their launch command, auto-install command, prerequisite package
//  managers, file extensions, and workspace-root markers.
//
//  The registry is the single source of truth that the LSP proxy uses
//  to (a) decide which server to spawn for a given file, (b) tell the
//  user how to install that server when it isn't present, and (c) merge
//  user overrides from ~/.config/calyx/lsp.json.
//
//  The override file format is a JSON object with a single key,
//  "entries", whose value is an array of LSPServerDefinition. Override
//  entries replace existing built-in entries with the same `languageId`
//  in place; new languageIds are appended at the end. Built-in entry
//  order is otherwise preserved.
//

import Foundation

// MARK: - LSPPrerequisite

/// A single command-line tool that must be present on the user's PATH
/// before `LSPInstallationSpec.command` can succeed.
///
/// - `executable`: the binary name we probe with `which`
///   (e.g. `"npm"`, `"rustup"`, `"brew"`).
/// - `installCommand`: an optional one-liner the UI may offer to run on
///   the user's behalf to bootstrap this prerequisite. `nil` means we
///   can't auto-install; the UI should fall back to `manualInstructions`.
/// - `manualInstructions`: optional free-text guidance (URL, short
///   sentence) for the user when auto-install is unavailable.
struct LSPPrerequisite: Sendable, Codable, Equatable {
    let executable: String
    let installCommand: String?
    let manualInstructions: String?

    init(
        executable: String,
        installCommand: String? = nil,
        manualInstructions: String? = nil
    ) {
        self.executable = executable
        self.installCommand = installCommand
        self.manualInstructions = manualInstructions
    }
}

// MARK: - LSPInstallationSpec

/// How to install a language server.
///
/// - `command`: the shell one-liner that installs the LSP itself
///   (e.g. `"npm install -g typescript-language-server typescript"`).
/// - `prerequisites`: tools `command` depends on. The proxy verifies
///   each `executable` is on PATH before running `command`.
/// - `safeToAutoRun`: if `true`, the UI may offer a one-click install.
///   `false` means the command requires user interaction (e.g. macOS
///   `xcode-select --install` shows a GUI prompt) and must be surfaced
///   as instructions only.
struct LSPInstallationSpec: Sendable, Codable, Equatable {
    let command: String
    let prerequisites: [LSPPrerequisite]
    let safeToAutoRun: Bool

    init(
        command: String,
        prerequisites: [LSPPrerequisite],
        safeToAutoRun: Bool
    ) {
        self.command = command
        self.prerequisites = prerequisites
        self.safeToAutoRun = safeToAutoRun
    }
}

// MARK: - LSPServerDefinition

/// Everything Calyx needs to know about one language server.
///
/// - `languageId`: the LSP `languageId` we send in
///   `textDocument/didOpen` (e.g. `"typescript"`, `"swift"`). Doubles
///   as the stable primary key in this registry.
/// - `displayName`: human-readable label for Settings UI.
/// - `executable` / `arguments`: how to launch the server over stdio.
/// - `versionArguments`: arguments passed to `executable` to print the
///   server's version (used by health-check UI). `nil` if the server
///   has no standard version flag.
/// - `fileExtensions`: lower-cased, dot-prefixed (e.g. `".ts"`).
/// - `workspaceMarkers`: file/directory names whose presence in a
///   directory marks it as a project root for this language. Wildcard
///   tokens like `"*.csproj"` are stored verbatim; actual matching is
///   the responsibility of the root-detection layer.
/// - `installation`: how to install this server.
/// - `defaultInitializationOptions`: free-form JSON forwarded as
///   `initializationOptions` on `initialize`. `nil` for now; reserved
///   for per-server tuning.
struct LSPServerDefinition: Sendable, Codable, Equatable {
    let languageId: String
    let displayName: String
    let executable: String
    let arguments: [String]
    let versionArguments: [String]?
    let fileExtensions: [String]
    let workspaceMarkers: [String]
    let installation: LSPInstallationSpec
    let defaultInitializationOptions: AnyCodable?

    init(
        languageId: String,
        displayName: String,
        executable: String,
        arguments: [String],
        versionArguments: [String]?,
        fileExtensions: [String],
        workspaceMarkers: [String],
        installation: LSPInstallationSpec,
        defaultInitializationOptions: AnyCodable?
    ) {
        self.languageId = languageId
        self.displayName = displayName
        self.executable = executable
        self.arguments = arguments
        self.versionArguments = versionArguments
        self.fileExtensions = fileExtensions
        self.workspaceMarkers = workspaceMarkers
        self.installation = installation
        self.defaultInitializationOptions = defaultInitializationOptions
    }
}

// MARK: - LSPServerRegistryError

/// Errors thrown while loading the user override file.
///
/// - `symlinkRedirect`: the override path is a symlink. Following it
///   would allow another process with write access to the link's
///   destination to redirect Calyx into spawning an attacker-controlled
///   `executable`. Mirrors the symlink rejection policy already used by
///   the Claude / Codex / OpenCode / Hermes config managers via
///   `ConfigFileUtils.isSymlink(at:)`.
enum LSPServerRegistryError: Error, Sendable, Equatable {
    case symlinkRedirect(URL)
}

// MARK: - LSPServerRegistry

/// Immutable in-memory table of every language server Calyx knows
/// about. Built from `builtIn()` and optionally merged with a user
/// override file via `loaded(overridePath:)`.
struct LSPServerRegistry: Sendable, Equatable, Codable {
    let entries: [LSPServerDefinition]

    init(entries: [LSPServerDefinition]) {
        self.entries = entries
    }

    // MARK: Lookup

    /// O(n) linear scan. n == 15 for the built-in table; with user
    /// overrides realistically n < 30, so a hash map is unnecessary.
    func entry(forLanguageId id: String) -> LSPServerDefinition? {
        entries.first { $0.languageId == id }
    }

    /// Looks up the language server responsible for a given file
    /// extension. The lookup is case-insensitive (`".TS"` and `".ts"`
    /// both match TypeScript) and accepts both dot-prefixed (`".ts"`)
    /// and bare (`"ts"`) forms. The registry always stores extensions
    /// in dot-prefixed lower-cased form.
    func entry(forFileExtension ext: String) -> LSPServerDefinition? {
        let normalized = ext.lowercased()
        let dotted = normalized.hasPrefix(".") ? normalized : "." + normalized
        if let match = entries.first(where: { $0.fileExtensions.contains(dotted) }) {
            return match
        }
        // Fall back to a bare-form match in case stored extensions are
        // ever non-dotted (future-proofing for user overrides).
        let bare = normalized.hasPrefix(".") ? String(normalized.dropFirst()) : normalized
        return entries.first { $0.fileExtensions.contains(bare) }
    }

    // MARK: Loading

    /// Returns the built-in registry merged with optional user
    /// overrides from `overridePath`.
    ///
    /// Behavior:
    /// - `overridePath == nil`             → built-in only.
    /// - file does not exist               → built-in only (no throw).
    /// - file is a symlink                 → throws
    ///   `LSPServerRegistryError.symlinkRedirect`. We refuse to follow
    ///   symlinks because the override's `executable` field is spawned
    ///   directly; a symlink redirect would let any process with write
    ///   access to the link's destination control which LSP binary
    ///   Calyx launches.
    /// - file exists and parses as JSON    → merge applied:
    ///     • override entries whose `languageId` matches a built-in
    ///       replace the built-in in place (order preserved).
    ///     • override entries with a new `languageId` are appended.
    /// - file exists but is malformed JSON → re-throws decoder error.
    static func loaded(overridePath: URL?) throws -> LSPServerRegistry {
        let builtIn = LSPServerRegistry.builtIn()
        guard let overridePath else { return builtIn }
        guard FileManager.default.fileExists(atPath: overridePath.path) else {
            return builtIn
        }
        // Reject symlink redirects to prevent the override from being
        // pointed at an arbitrary writable file controlled by another
        // process. Mirrors the policy used by every other config
        // manager that consumes paths under ~/.config/calyx.
        if ConfigFileUtils.isSymlink(at: overridePath.path) {
            throw LSPServerRegistryError.symlinkRedirect(overridePath)
        }
        let data = try Data(contentsOf: overridePath)
        let override = try JSONDecoder().decode(LSPServerRegistry.self, from: data)

        var merged: [LSPServerDefinition] = builtIn.entries
        for overrideEntry in override.entries {
            if let existingIdx = merged.firstIndex(where: {
                $0.languageId == overrideEntry.languageId
            }) {
                merged[existingIdx] = overrideEntry
            } else {
                merged.append(overrideEntry)
            }
        }
        return LSPServerRegistry(entries: merged)
    }

    // MARK: Built-in Table

    /// The 15 languages Calyx ships with. Order here is the order
    /// surfaced in Settings UI. Do not reorder without coordinating
    /// with UI snapshots.
    static func builtIn() -> LSPServerRegistry {
        LSPServerRegistry(entries: [
            // 1. TypeScript / JavaScript
            LSPServerDefinition(
                languageId: "typescript",
                displayName: "TypeScript / JavaScript",
                executable: "typescript-language-server",
                arguments: ["--stdio"],
                versionArguments: ["--version"],
                fileExtensions: [
                    ".ts", ".tsx", ".js", ".jsx",
                    ".mjs", ".cjs", ".mts", ".cts",
                ],
                workspaceMarkers: ["tsconfig.json", "package.json", "jsconfig.json"],
                installation: LSPInstallationSpec(
                    command: "npm install -g typescript-language-server typescript",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "npm",
                            installCommand: "brew install node",
                            manualInstructions: nil
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 2. Python
            LSPServerDefinition(
                languageId: "python",
                displayName: "Python",
                executable: "pyright-langserver",
                arguments: ["--stdio"],
                versionArguments: ["--version"],
                fileExtensions: [".py", ".pyi"],
                workspaceMarkers: [
                    "pyproject.toml", "setup.py", "requirements.txt", "Pipfile",
                ],
                installation: LSPInstallationSpec(
                    command: "npm install -g pyright",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "npm",
                            installCommand: "brew install node",
                            manualInstructions: nil
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 3. Swift / Objective-C / C / C++
            LSPServerDefinition(
                languageId: "swift",
                displayName: "Swift / Objective-C / C / C++",
                executable: "xcrun",
                arguments: ["sourcekit-lsp"],
                versionArguments: nil,
                fileExtensions: [
                    ".swift", ".m", ".mm",
                    ".c", ".h",
                    ".cpp", ".cc", ".cxx", ".hpp", ".hh",
                ],
                workspaceMarkers: ["Package.swift", "*.xcodeproj"],
                installation: LSPInstallationSpec(
                    command: "xcode-select --install",
                    prerequisites: [],
                    // GUI prompt — never run silently.
                    safeToAutoRun: false
                ),
                defaultInitializationOptions: nil
            ),

            // 4. Rust
            LSPServerDefinition(
                languageId: "rust",
                displayName: "Rust",
                executable: "rust-analyzer",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".rs"],
                workspaceMarkers: ["Cargo.toml"],
                installation: LSPInstallationSpec(
                    command: "rustup component add rust-analyzer",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "rustup",
                            installCommand:
                                "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
                            manualInstructions: nil
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 5. Go
            LSPServerDefinition(
                languageId: "go",
                displayName: "Go",
                executable: "gopls",
                arguments: ["serve"],
                versionArguments: ["version"],
                fileExtensions: [".go"],
                workspaceMarkers: ["go.mod"],
                installation: LSPInstallationSpec(
                    command: "go install golang.org/x/tools/gopls@latest",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "go",
                            installCommand: "brew install go",
                            manualInstructions: nil
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 6. Ruby
            LSPServerDefinition(
                languageId: "ruby",
                displayName: "Ruby",
                executable: "ruby-lsp",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".rb", ".rake", ".gemspec"],
                workspaceMarkers: ["Gemfile", "*.gemspec"],
                installation: LSPInstallationSpec(
                    command: "gem install ruby-lsp",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "gem",
                            installCommand: nil,
                            manualInstructions:
                                "Ruby (and `gem`) ships with macOS; if missing, install Ruby."
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 7. Java
            LSPServerDefinition(
                languageId: "java",
                displayName: "Java",
                executable: "jdtls",
                arguments: [],
                versionArguments: nil,
                fileExtensions: [".java"],
                workspaceMarkers: ["pom.xml", "build.gradle", "build.gradle.kts"],
                installation: LSPInstallationSpec(
                    command: "brew install jdtls",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 8. Kotlin
            LSPServerDefinition(
                languageId: "kotlin",
                displayName: "Kotlin",
                executable: "kotlin-language-server",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".kt", ".kts"],
                workspaceMarkers: ["build.gradle.kts", "build.gradle"],
                installation: LSPInstallationSpec(
                    command: "brew install kotlin-language-server",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 9. PHP
            LSPServerDefinition(
                languageId: "php",
                displayName: "PHP",
                executable: "intelephense",
                arguments: ["--stdio"],
                versionArguments: ["--version"],
                fileExtensions: [".php"],
                workspaceMarkers: ["composer.json"],
                installation: LSPInstallationSpec(
                    command: "npm install -g intelephense",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "npm",
                            installCommand: "brew install node",
                            manualInstructions: nil
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 10. C#
            LSPServerDefinition(
                languageId: "csharp",
                displayName: "C#",
                executable: "omnisharp",
                arguments: ["--languageserver"],
                versionArguments: ["--version"],
                fileExtensions: [".cs", ".csx"],
                workspaceMarkers: ["*.csproj", "*.sln"],
                installation: LSPInstallationSpec(
                    command: "brew install omnisharp",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 11. Lua
            LSPServerDefinition(
                languageId: "lua",
                displayName: "Lua",
                executable: "lua-language-server",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".lua"],
                workspaceMarkers: [".luarc.json"],
                installation: LSPInstallationSpec(
                    command: "brew install lua-language-server",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 12. Elixir
            LSPServerDefinition(
                languageId: "elixir",
                displayName: "Elixir",
                executable: "elixir-ls",
                arguments: [],
                versionArguments: nil,
                fileExtensions: [".ex", ".exs"],
                workspaceMarkers: ["mix.exs"],
                installation: LSPInstallationSpec(
                    command: "brew install elixir-ls",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 13. Haskell
            LSPServerDefinition(
                languageId: "haskell",
                displayName: "Haskell",
                executable: "haskell-language-server-wrapper",
                arguments: ["--lsp"],
                versionArguments: ["--version"],
                fileExtensions: [".hs", ".lhs"],
                workspaceMarkers: ["*.cabal", "stack.yaml", "package.yaml"],
                installation: LSPInstallationSpec(
                    command: "ghcup install hls",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "ghcup",
                            installCommand: nil,
                            manualInstructions: "Install GHCup: https://www.haskell.org/ghcup/"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 14. Zig
            LSPServerDefinition(
                languageId: "zig",
                displayName: "Zig",
                executable: "zls",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".zig"],
                workspaceMarkers: ["build.zig"],
                installation: LSPInstallationSpec(
                    command: "brew install zls",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "brew",
                            installCommand: nil,
                            manualInstructions: "Install Homebrew: https://brew.sh"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),

            // 15. OCaml
            LSPServerDefinition(
                languageId: "ocaml",
                displayName: "OCaml",
                executable: "ocamllsp",
                arguments: [],
                versionArguments: ["--version"],
                fileExtensions: [".ml", ".mli"],
                workspaceMarkers: ["dune-project", "*.opam"],
                installation: LSPInstallationSpec(
                    command: "opam install ocaml-lsp-server",
                    prerequisites: [
                        LSPPrerequisite(
                            executable: "opam",
                            installCommand: nil,
                            manualInstructions: "Install opam: https://opam.ocaml.org/doc/Install.html"
                        ),
                    ],
                    safeToAutoRun: true
                ),
                defaultInitializationOptions: nil
            ),
        ])
    }
}
