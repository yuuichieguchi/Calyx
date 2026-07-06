//
//  GhosttyResourcesDirResolverTests.swift
//  CalyxTests
//
//  TDD Red phase (persistent-session shell-integration fix). ROOT CAUSE
//  (architecture.md §3's documented gap): Calyx never sets
//  GHOSTTY_RESOURCES_DIR, so ghostty's shell-integration scripts are never
//  forwarded to attached persistent-session panes in a Finder/Dock
//  launch. Calyx bundles its OWN version-matched copy of those scripts at
//  Contents/Resources/ghostty (see project.yml's "Copy Ghostty Resources"
//  postBuildScript; contains shell-integration/zsh/.zshenv etc.). This
//  resolver is the pure "does the bundle actually have shell-integration"
//  check the fix's environment-application half
//  (GhosttyResourcesDirEnvironment, sibling RED file
//  GhosttyResourcesDirEnvironmentTests.swift) gates on before ever
//  touching the process environment -- it must never point
//  GHOSTTY_RESOURCES_DIR at an incomplete or missing bundle layout (e.g.
//  a Debug build without a prior full resource-copy build).
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): GhosttyResourcesDirResolver
//  does not exist yet anywhere in the codebase, so this file fails to
//  compile until the Green phase adds it. That compile failure IS this
//  file's RED evidence.
//
//  Proposed API (Calyx/GhosttyBridge/GhosttyResourcesDirResolver.swift),
//  parameterized on a resources root URL rather than Bundle.main so it is
//  directly testable against temp-dir fixtures, mirroring
//  SessionRemotePayloadResolver's own `init(bundle: Bundle = .main)`
//  testability precedent one layer up (a raw root URL here instead of a
//  Bundle, since the check below is a plain directory-existence check,
//  not a Bundle resource lookup):
//
//    struct GhosttyResourcesDirResolver {
//        init(resourcesRoot: URL)
//        func resolve() -> String?   // resourcesRoot/ghostty's path, or nil
//    }
//
//  Bundle layout under test: resourcesRoot is the app bundle's Resources/
//  directory; resourcesRoot/ghostty/shell-integration/... is Calyx's own
//  bundled copy of ghostty's shell-integration scripts.
//
//  Coverage:
//  - resourcesRoot/ghostty/shell-integration exists as a directory:
//    resolve() returns resourcesRoot/ghostty's own path
//  - resourcesRoot has no ghostty/ subdirectory at all: resolve() returns nil
//  - resourcesRoot/ghostty exists but has no shell-integration
//    subdirectory: resolve() returns nil
//  - resourcesRoot/ghostty/shell-integration exists but as a plain FILE,
//    not a directory: resolve() returns nil (a real, if unlikely, bundle
//    corruption case -- must not be mistaken for the real directory)
//

import XCTest
@testable import Calyx

final class GhosttyResourcesDirResolverTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a fresh, isolated temp directory URL per test, and schedule
    /// its removal. Mirrors WorkspaceResolverTests.makeTempDir's convention:
    /// resolve symlinks so paths under /var (a symlink to /private/var on
    /// macOS) compare correctly against whatever the resolver returns.
    private func makeTempDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyResourcesDirResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    @discardableResult
    private func mkdir(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func touch(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: - resolve()

    func test_resolve_returnsGhosttyDirPath_whenShellIntegrationDirectoryExists() throws {
        let root = try makeTempDir()
        let ghosttyDir = try mkdir("ghostty", under: root)
        try mkdir("shell-integration", under: ghosttyDir)

        let resolver = GhosttyResourcesDirResolver(resourcesRoot: root)

        XCTAssertEqual(
            resolver.resolve(), ghosttyDir.path,
            "with a bundled ghostty/shell-integration directory present, resolve() must return the ghostty directory's own path"
        )
    }

    func test_resolve_returnsNil_whenGhosttySubdirectoryIsMissingEntirely() throws {
        let root = try makeTempDir()
        // root deliberately has no "ghostty" subdirectory at all.

        let resolver = GhosttyResourcesDirResolver(resourcesRoot: root)

        XCTAssertNil(
            resolver.resolve(),
            "with no ghostty/ subdirectory at all under resourcesRoot, resolve() must return nil"
        )
    }

    func test_resolve_returnsNil_whenGhosttyDirectoryHasNoShellIntegrationSubdirectory() throws {
        let root = try makeTempDir()
        let ghosttyDir = try mkdir("ghostty", under: root)
        try mkdir("themes", under: ghosttyDir) // some other bundled content, but no shell-integration

        let resolver = GhosttyResourcesDirResolver(resourcesRoot: root)

        XCTAssertNil(
            resolver.resolve(),
            "with a ghostty/ directory that has no shell-integration subdirectory, resolve() must return nil rather than pointing at an incomplete bundle"
        )
    }

    func test_resolve_returnsNil_whenShellIntegrationExistsAsAFileNotADirectory() throws {
        let root = try makeTempDir()
        let ghosttyDir = try mkdir("ghostty", under: root)
        try touch("shell-integration", under: ghosttyDir)

        let resolver = GhosttyResourcesDirResolver(resourcesRoot: root)

        XCTAssertNil(
            resolver.resolve(),
            "a plain file named shell-integration must not be mistaken for the real directory"
        )
    }
}
