// ConfigFileOpenerTests.swift
// CalyxTests
//
// TDD red-phase tests for ConfigFileOpener protocol and openConfigFile(using:) logic.
// Tests use a mock to verify all code paths without touching the real filesystem.

import Foundation
import Testing
@testable import Calyx

/// Mock implementation of ConfigFileOpener for deterministic testing.
@MainActor
private struct MockConfigFileOpener: ConfigFileOpening {
    var configPath: String = "/Users/test/.config/ghostty/config"
    var existingFiles: Set<String> = []
    var directories: Set<String> = []
    var symlinks: Set<String> = []
    var createFileShouldThrow: Error? = nil
    var createParentShouldThrow: Error? = nil
    var openFileResult: Bool = true

    private(set) var createdFiles: [String] = []
    private(set) var createdParentDirs: [String] = []
    private(set) var openedURLs: [URL] = []
    private(set) var revealedURLs: [URL] = []

    func configOpenPath() -> String {
        configPath
    }

    func fileExists(at path: String) -> Bool {
        existingFiles.contains(path)
    }

    func isDirectory(at path: String) -> Bool {
        directories.contains(path)
    }

    func isSymlink(at path: String) -> Bool {
        symlinks.contains(path)
    }

    mutating func createParentDirectory(for path: String) throws {
        if let error = createParentShouldThrow {
            throw error
        }
        createdParentDirs.append(path)
    }

    mutating func createFileExclusively(at path: String) throws {
        if let error = createFileShouldThrow {
            throw error
        }
        createdFiles.append(path)
    }

    func openFile(at url: URL) -> Bool {
        openFileResult
    }

    func revealInFinder(url: URL) {
        // No-op for tests
    }
}

/// Simple error for testing create failures.
private struct MockCreateError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
@Suite("ConfigFileOpener Tests")
struct ConfigFileOpenerTests {

    // MARK: - Happy Path: File Exists

    @Test("File exists at config path → opens successfully → .opened")
    func fileExistsOpensSuccessfully() {
        let normalizedPath = URL(fileURLWithPath: "/Users/test/.config/ghostty/config").standardized.path
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty/config",
            existingFiles: [normalizedPath],
            openFileResult: true
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .opened)
    }

    // MARK: - Happy Path: File Does Not Exist → Create

    @Test("File does not exist → creates and opens → .createdAndOpened")
    func fileDoesNotExistCreatesAndOpens() {
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty/config",
            existingFiles: [],
            openFileResult: true
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .createdAndOpened)
    }

    // MARK: - Error: Empty Path

    @Test("Empty config path → .error(.emptyPath)")
    func emptyPathReturnsError() {
        var opener = MockConfigFileOpener(configPath: "")
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .error(.emptyPath))
    }

    // MARK: - Error: Path is a Directory

    @Test("Path is a directory → .error(.isDirectory)")
    func pathIsDirectoryReturnsError() {
        let normalizedPath = URL(fileURLWithPath: "/Users/test/.config/ghostty").standardized.path
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty",
            directories: [normalizedPath]
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .error(.isDirectory))
    }

    // MARK: - Error: Path is a Symlink

    @Test("Path is a symlink → .error(.isSymlink)")
    func pathIsSymlinkReturnsError() {
        let normalizedPath = URL(fileURLWithPath: "/Users/test/.config/ghostty/config").standardized.path
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty/config",
            existingFiles: [normalizedPath],
            symlinks: [normalizedPath]
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .error(.isSymlink))
    }

    // MARK: - Error: File Creation Fails

    @Test("File creation throws → .error(.createFailed(message))")
    func fileCreationFailsReturnsError() {
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty/config",
            existingFiles: [],
            createFileShouldThrow: MockCreateError(description: "Permission denied")
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        // The error message should contain the thrown error's description
        if case .error(.createFailed(let message)) = result {
            #expect(message.contains("Permission denied"))
        } else {
            Issue.record("Expected .error(.createFailed) but got \(result)")
        }
    }

    // MARK: - Error: File Exists but Open Fails

    @Test("File exists but open returns false → .error(.openFailed)")
    func fileExistsButOpenFailsReturnsError() {
        let normalizedPath = URL(fileURLWithPath: "/Users/test/.config/ghostty/config").standardized.path
        var opener = MockConfigFileOpener(
            configPath: "/Users/test/.config/ghostty/config",
            existingFiles: [normalizedPath],
            openFileResult: false
        )
        let result = ConfigFileOpener.openConfigFile(using: &opener)
        #expect(result == .error(.openFailed))
    }
}
