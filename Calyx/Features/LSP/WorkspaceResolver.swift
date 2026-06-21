//
//  WorkspaceResolver.swift
//  Calyx
//
//  Actor that, given a working directory or a file URL, infers the LSP
//  workspace root and the LSP `languageId` to use by consulting the
//  `LSPServerRegistry` and walking the file system upwards looking for
//  the workspace markers each registry entry declares.
//
//  Resolution rules:
//    - `resolveWorkspaceRoot(from:)` walks parent directories starting
//      at `cwd`. For each directory, it returns immediately if either:
//        (a) a `.git` directory is present, or
//        (b) any registry entry's `workspaceMarkers` is present.
//      Markers may be literal names (`"Cargo.toml"`) or wildcard
//      patterns (`"*.xcodeproj"`); both forms are matched against the
//      directory's actual contents. The walk stops at the user's home
//      directory or the filesystem root without producing a false
//      positive.
//    - `resolveLanguageId(for:)` consults the registry by file
//      extension first, then falls back to matching the file name
//      against any registry entry's `workspaceMarkers` (so e.g.
//      `Cargo.toml` resolves to `"rust"` even though the `.toml`
//      extension is generic).
//    - `inferLanguageId(fromWorkspace:)` enumerates the workspace
//      root's immediate children and returns the first registry-known
//      language id.
//
//  Both `resolveWorkspaceRoot` and `resolveLanguageId` cache results
//  per standardized input URL; `clearCache()` empties both caches.
//
//  Path standardization: all keys are normalised via
//  `.standardizedFileURL.resolvingSymlinksInPath()` so that macOS
//  symlinks such as `/var` → `/private/var` and `/tmp` → `/private/tmp`
//  do not produce divergent cache entries.
//

import Foundation

/// Resolves an LSP workspace root and `languageId` for a given path by
/// walking the file system and consulting `LSPServerRegistry`.
actor WorkspaceResolver {

    // MARK: - State

    /// The registry of supported languages. Held by value; immutable.
    private let registry: LSPServerRegistry

    /// Cache: standardized cwd path → workspace root URL (or `nil` if
    /// the resolver previously failed to find one). The optional is
    /// double-wrapped so we can distinguish "cached miss" (`.some(nil)`)
    /// from "never looked up" (`nil`).
    private var workspaceRootCache: [String: URL?] = [:]

    /// Cache: standardized file path → languageId (or `nil` for a
    /// cached miss). Same double-wrap rationale as above.
    private var languageIdCache: [String: String?] = [:]

    /// Hard upper bound on how many parent directories we will walk
    /// before giving up. The deepest reasonable project layout (incl.
    /// `/private/var/folders/.../T/.../a/b/c` in tests) is ~15 levels;
    /// 32 is a comfortable safety margin that still bounds I/O.
    private static let maxAscendSteps = 32

    // MARK: - Init

    init(registry: LSPServerRegistry = .builtIn()) {
        self.registry = registry
    }

    // MARK: - Public API

    /// Walk upwards from `cwd` and return the first ancestor (inclusive)
    /// that looks like a workspace root, or `nil` if no marker is found
    /// before reaching the home directory or filesystem root.
    func resolveWorkspaceRoot(from cwd: URL) -> URL? {
        let normalized = Self.normalize(cwd)
        let cacheKey = normalized.path

        if let cached = workspaceRootCache[cacheKey] {
            return cached
        }

        let resolved = walkUpwards(from: normalized)
        workspaceRootCache[cacheKey] = resolved
        return resolved
    }

    /// Resolve the LSP `languageId` for `file`. Lookup order:
    ///   1. by file extension via `registry.entry(forFileExtension:)`,
    ///   2. by exact file-name match against any entry's
    ///      `workspaceMarkers` (literal markers only — wildcards make no
    ///      sense for a per-file lookup).
    /// Returns `nil` if neither path matches.
    func resolveLanguageId(for file: URL) -> String? {
        let normalized = Self.normalize(file)
        let cacheKey = normalized.path

        if let cached = languageIdCache[cacheKey] {
            return cached
        }

        let resolved = computeLanguageId(for: normalized)
        languageIdCache[cacheKey] = resolved
        return resolved
    }

    /// Infer a `languageId` from the contents of `root` by enumerating
    /// its immediate children and returning the first language we can
    /// identify (either by extension or by marker file name). Returns
    /// `nil` for an empty or wholly-unrecognised directory.
    func inferLanguageId(fromWorkspace root: URL) -> String? {
        let normalized = Self.normalize(root)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: normalized,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return nil
        }
        for child in children {
            if let id = resolveLanguageId(for: child) {
                return id
            }
        }
        return nil
    }

    /// Empty both the workspace-root and language-id caches.
    func clearCache() {
        workspaceRootCache.removeAll()
        languageIdCache.removeAll()
    }

    // MARK: - Workspace root walk

    /// Walk from `start` upwards toward the filesystem root, returning
    /// the first directory that contains a recognised marker.
    ///
    /// Termination boundaries (all yield `nil`):
    ///   * the user's home directory — user-level config files there
    ///     would otherwise produce false positives;
    ///   * the system temporary directory (`NSTemporaryDirectory()`) —
    ///     residual scratch files (e.g. xcodebuild's stray `.sln`
    ///     files in `/var/folders/.../T`) must never count as
    ///     workspace markers;
    ///   * the filesystem root `/`;
    ///   * a hard cap of `maxAscendSteps` iterations.
    private func walkUpwards(from start: URL) -> URL? {
        let home = Self.normalize(FileManager.default.homeDirectoryForCurrentUser)
        let tempRoot = Self.normalize(FileManager.default.temporaryDirectory)
        let homePath = home.path
        let tempPath = tempRoot.path

        var current = start
        for _ in 0..<Self.maxAscendSteps {
            // Stop *before* descending into HOME or the system temp
            // root: neither is a meaningful project root in our model,
            // and stepping into them would risk false positives from
            // user-level config files or scratch artifacts.
            if current.path == homePath || current.path == tempPath {
                return nil
            }

            if directoryLooksLikeWorkspaceRoot(current) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            // `deletingLastPathComponent` on `/` returns `/` itself,
            // which is the natural termination signal.
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Return `true` if `dir` contains either `.git` or any of the
    /// workspace markers declared by any registry entry.
    private func directoryLooksLikeWorkspaceRoot(_ dir: URL) -> Bool {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                // Hidden entries must NOT be skipped: `.git` itself is
                // hidden, and so is e.g. `.luarc.json`.
                options: []
            )
        } catch {
            return false
        }

        // Build a set of immediate child names for O(1) literal lookup.
        var names: Set<String> = []
        names.reserveCapacity(entries.count)
        for url in entries {
            names.insert(url.lastPathComponent)
        }

        if names.contains(".git") {
            return true
        }

        for entry in registry.entries {
            for marker in entry.workspaceMarkers {
                if marker.contains("*") {
                    // Wildcard pattern (e.g. `"*.xcodeproj"`).
                    if names.contains(where: { Self.matches(name: $0, pattern: marker) }) {
                        return true
                    }
                } else {
                    if names.contains(marker) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Language id resolution

    private func computeLanguageId(for file: URL) -> String? {
        let ext = file.pathExtension
        if !ext.isEmpty,
           let entry = registry.entry(forFileExtension: ext) {
            return entry.languageId
        }

        // Fallback: match the bare file name against any literal
        // `workspaceMarkers` entry. Wildcard markers are intentionally
        // ignored here — they only make sense for directory scans.
        let name = file.lastPathComponent
        for entry in registry.entries {
            if entry.workspaceMarkers.contains(name) {
                return entry.languageId
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Normalize a URL for use as a cache key or for path comparison:
    /// resolve symlinks first (so `/var/...` becomes `/private/var/...`
    /// on macOS), then apply `.standardizedFileURL` for component
    /// normalization.
    private static func normalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Match a directory entry `name` against a workspace-marker
    /// `pattern`. Supports a single `*` segment matching a (possibly
    /// empty) run of any characters — the only wildcard form used in
    /// the built-in registry (e.g. `"*.xcodeproj"`, `"*.csproj"`,
    /// `"*.opam"`).
    static func matches(name: String, pattern: String) -> Bool {
        guard pattern.contains("*") else {
            return name == pattern
        }
        // Split on `*` and require every fragment to appear in order,
        // anchored at the appropriate end. Two-fragment patterns
        // (prefix/suffix split) cover everything in the registry, but
        // the general loop is no harder to write.
        let fragments = pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map(String.init)

        var cursor = name.startIndex
        for (index, fragment) in fragments.enumerated() {
            if fragment.isEmpty { continue }
            let isFirst = index == 0
            let isLast = index == fragments.count - 1
            if isFirst {
                guard name[cursor...].hasPrefix(fragment) else { return false }
                cursor = name.index(cursor, offsetBy: fragment.count)
            } else if isLast {
                guard name[cursor...].hasSuffix(fragment) else { return false }
                // Ensure the suffix consumes characters at or after the
                // current cursor (no overlap with previously-matched
                // fragments).
                let suffixStart = name.index(name.endIndex, offsetBy: -fragment.count)
                guard suffixStart >= cursor else { return false }
                cursor = name.endIndex
            } else {
                guard let range = name.range(of: fragment, range: cursor..<name.endIndex) else {
                    return false
                }
                cursor = range.upperBound
            }
        }
        return true
    }
}
