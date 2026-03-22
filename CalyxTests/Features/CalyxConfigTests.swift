// CalyxConfigTests.swift
// CalyxTests
//
// Tests for CalyxConfigFile parser/writer.
// Covers parsing, writing, roundtrips, defaults, and edge cases.

import Foundation
import Testing
@testable import Calyx

@Suite("CalyxConfigFile Parsing Tests")
struct CalyxConfigFileParsingTests {

    // MARK: - Defaults

    @Test("Empty string returns all defaults")
    func emptyStringReturnsDefaults() {
        let config = CalyxConfigFile.parse("")
        #expect(config.glassOpacity == 0.7)
        #expect(config.themeColorPreset == "original")
        #expect(config.themeColorCustomHex == "#050D1C")
        #expect(config.ipcRandomToken == true)
        #expect(config.ipcToken == "")
    }

    @Test("Missing file returns defaults")
    func missingFileReturnsDefaults() {
        let config = CalyxConfigFile.read(from: "/nonexistent/path/that/does/not/exist/config")
        #expect(config.glassOpacity == 0.7)
        #expect(config.themeColorPreset == "original")
        #expect(config.themeColorCustomHex == "#050D1C")
        #expect(config.ipcRandomToken == true)
        #expect(config.ipcToken == "")
    }

    @Test("Static defaults property returns default instance")
    func staticDefaultsReturnsDefaultInstance() {
        let config = CalyxConfigFile.defaults
        #expect(config.glassOpacity == 0.7)
        #expect(config.themeColorPreset == "original")
        #expect(config.themeColorCustomHex == "#050D1C")
        #expect(config.ipcRandomToken == true)
        #expect(config.ipcToken == "")
    }

    // MARK: - Parsing All Keys

    @Test("Parses all known keys correctly")
    func parsesAllKeys() {
        let content = """
        glass-opacity = 0.5
        theme-color-preset = dark
        theme-color-custom-hex = #FF0000
        ipc-random-token = false
        ipc-token = my-secret-token
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.5)
        #expect(config.themeColorPreset == "dark")
        #expect(config.themeColorCustomHex == "#FF0000")
        #expect(config.ipcRandomToken == false)
        #expect(config.ipcToken == "my-secret-token")
    }

    // MARK: - Comments and Blank Lines

    @Test("Comments and blank lines are ignored during parsing")
    func commentsAndBlankLinesIgnored() {
        let content = """
        # This is a comment
        glass-opacity = 0.3

        # Another comment
        theme-color-preset = midnight

        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.3)
        #expect(config.themeColorPreset == "midnight")
        // Other values should be defaults
        #expect(config.themeColorCustomHex == "#050D1C")
        #expect(config.ipcRandomToken == true)
        #expect(config.ipcToken == "")
    }

    // MARK: - Unknown Keys

    @Test("Unknown keys are ignored")
    func unknownKeysIgnored() {
        let content = """
        glass-opacity = 0.5
        unknown-key = some-value
        another-unknown = 42
        theme-color-preset = custom
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.5)
        #expect(config.themeColorPreset == "custom")
    }

    // MARK: - Invalid Values

    @Test("Invalid double value uses default")
    func invalidDoubleUsesDefault() {
        let content = """
        glass-opacity = not-a-number
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.7)
    }

    @Test("Invalid bool value uses default")
    func invalidBoolUsesDefault() {
        let content = """
        ipc-random-token = maybe
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.ipcRandomToken == true)
    }

    // MARK: - Bool Values

    @Test("Bool true values parsed correctly")
    func boolTrueValues() {
        let content = "ipc-random-token = true"
        let config = CalyxConfigFile.parse(content)
        #expect(config.ipcRandomToken == true)
    }

    @Test("Bool false values parsed correctly")
    func boolFalseValues() {
        let content = "ipc-random-token = false"
        let config = CalyxConfigFile.parse(content)
        #expect(config.ipcRandomToken == false)
    }

    // MARK: - Whitespace Handling

    @Test("Extra whitespace around key and value is trimmed")
    func whitespaceIsTrimmed() {
        let content = "  glass-opacity  =  0.4  "
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.4)
    }

    @Test("Empty value for string key results in empty string")
    func emptyStringValue() {
        let content = "ipc-token = "
        let config = CalyxConfigFile.parse(content)
        #expect(config.ipcToken == "")
    }

    @Test("IPC token persists across read/write roundtrip")
    func ipcTokenPersistsAcrossRoundtrip() {
        let content = """
        ipc-token = my-persistent-token
        ipc-random-token = false
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.ipcToken == "my-persistent-token")
        #expect(config.ipcRandomToken == false)
    }

    @Test("Lines without equals sign are ignored")
    func linesWithoutEqualSignIgnored() {
        let content = """
        this line has no equals sign
        glass-opacity = 0.6
        """
        let config = CalyxConfigFile.parse(content)
        #expect(config.glassOpacity == 0.6)
    }
}

@Suite("CalyxConfigFile Writing Tests")
struct CalyxConfigFileWritingTests {

    private func tempPath() -> String {
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("calyx-test-\(UUID().uuidString)/config")
    }

    private func cleanup(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Writing creates file with all keys")
    func writeCreatesFileWithAllKeys() {
        let path = tempPath()
        defer { cleanup(path) }

        var config = CalyxConfigFile.defaults
        config.glassOpacity = 0.5
        config.themeColorPreset = "dark"
        config.themeColorCustomHex = "#00FF00"
        config.ipcRandomToken = false
        config.ipcToken = "test-token"

        CalyxConfigFile.write(config, to: path)

        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("glass-opacity = 0.5"))
        #expect(content.contains("theme-color-preset = dark"))
        #expect(content.contains("theme-color-custom-hex = #00FF00"))
        #expect(content.contains("ipc-random-token = false"))
        #expect(content.contains("ipc-token = test-token"))
    }

    @Test("Write then read roundtrip preserves all values")
    func writeReadRoundtrip() {
        let path = tempPath()
        defer { cleanup(path) }

        var config = CalyxConfigFile.defaults
        config.glassOpacity = 0.42
        config.themeColorPreset = "ocean"
        config.themeColorCustomHex = "#ABCDEF"
        config.ipcRandomToken = false
        config.ipcToken = "roundtrip-token"

        CalyxConfigFile.write(config, to: path)
        let loaded = CalyxConfigFile.read(from: path)

        #expect(loaded.glassOpacity == 0.42)
        #expect(loaded.themeColorPreset == "ocean")
        #expect(loaded.themeColorCustomHex == "#ABCDEF")
        #expect(loaded.ipcRandomToken == false)
        #expect(loaded.ipcToken == "roundtrip-token")
    }

    @Test("Write preserves comments from existing file")
    func writePreservesComments() {
        let path = tempPath()
        defer { cleanup(path) }

        // Create initial file with comments
        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let initial = """
        # My custom comment
        glass-opacity = 0.7
        # Another comment
        theme-color-preset = original
        theme-color-custom-hex = #050D1C
        ipc-random-token = true
        ipc-token = 
        """
        try! initial.write(toFile: path, atomically: true, encoding: .utf8)

        // Read, modify, write back
        var config = CalyxConfigFile.read(from: path)
        config.glassOpacity = 0.9
        CalyxConfigFile.write(config, to: path)

        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("# My custom comment"))
        #expect(content.contains("# Another comment"))
        #expect(content.contains("glass-opacity = 0.9"))
    }

    @Test("Write creates directory if needed")
    func writeCreatesDirectory() {
        let dir = NSTemporaryDirectory()
        let nestedDir = (dir as NSString).appendingPathComponent("calyx-test-\(UUID().uuidString)/nested/deep")
        let path = (nestedDir as NSString).appendingPathComponent("config")
        defer {
            let base = (dir as NSString).appendingPathComponent(
                (nestedDir as NSString).lastPathComponent
            )
            // Clean up the top-level temp dir we created
            let components = nestedDir.replacingOccurrences(of: dir, with: "").split(separator: "/")
            if let first = components.first {
                try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(String(first)))
            }
        }

        let config = CalyxConfigFile.defaults
        CalyxConfigFile.write(config, to: path)

        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Write updates existing keys in-place and appends new ones")
    func writeUpdatesInPlaceAndAppendsNew() {
        let path = tempPath()
        defer { cleanup(path) }

        // Create initial file with only some keys
        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let initial = """
        # Header comment
        glass-opacity = 0.7
        theme-color-preset = original
        """
        try! initial.write(toFile: path, atomically: true, encoding: .utf8)

        // Write full config — should update existing keys in-place
        // and append missing keys at end
        var config = CalyxConfigFile.defaults
        config.glassOpacity = 0.8
        config.themeColorPreset = "dark"
        config.ipcToken = "new-token"
        CalyxConfigFile.write(config, to: path)

        let content = try! String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Header comment should still be first
        #expect(lines[0] == "# Header comment")
        // Updated keys should be in-place
        #expect(content.contains("glass-opacity = 0.8"))
        #expect(content.contains("theme-color-preset = dark"))
        // New keys should be appended
        #expect(content.contains("theme-color-custom-hex = #050D1C"))
        #expect(content.contains("ipc-random-token = true"))
        #expect(content.contains("ipc-token = new-token"))
    }

    @Test("Write preserves unknown lines from existing file")
    func writePreservesUnknownLines() {
        let path = tempPath()
        defer { cleanup(path) }

        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let initial = """
        some-future-key = future-value
        glass-opacity = 0.7
        """
        try! initial.write(toFile: path, atomically: true, encoding: .utf8)

        var config = CalyxConfigFile.read(from: path)
        config.glassOpacity = 0.5
        CalyxConfigFile.write(config, to: path)

        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("some-future-key = future-value"))
        #expect(content.contains("glass-opacity = 0.5"))
    }

    @Test("IPC token persists across write and read")
    func ipcTokenPersistsAcrossWriteAndRead() {
        let path = tempPath()
        defer { cleanup(path) }

        var config = CalyxConfigFile.defaults
        config.ipcToken = "persistent-secret"
        config.ipcRandomToken = false

        CalyxConfigFile.write(config, to: path)
        let loaded = CalyxConfigFile.read(from: path)

        #expect(loaded.ipcToken == "persistent-secret")
        #expect(loaded.ipcRandomToken == false)
    }
}
