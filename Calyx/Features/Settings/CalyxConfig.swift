// CalyxConfig.swift
// Calyx
//
// CalyxConfigFile: Sendable value type that parses/writes ~/.config/calyx/config
// CalyxConfig: @MainActor ObservableObject singleton for SwiftUI/AppKit reactivity

import Foundation
import OSLog
import Combine

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxConfig"
)

// MARK: - CalyxConfigFile (Sendable value type)

/// Parses and writes `~/.config/calyx/config` in Ghostty-style `key = value` format.
struct CalyxConfigFile: Sendable, Equatable {

    var glassOpacity: Double = 0.7
    var themeColorPreset: String = "original"
    var themeColorCustomHex: String = "#050D1C"
    var ipcRandomToken: Bool = true
    var ipcToken: String = ""

    // MARK: - Key Mapping

    private enum Key: String, CaseIterable {
        case glassOpacity = "glass-opacity"
        case themeColorPreset = "theme-color-preset"
        case themeColorCustomHex = "theme-color-custom-hex"
        case ipcRandomToken = "ipc-random-token"
        case ipcToken = "ipc-token"
    }

    // MARK: - Defaults

    static var defaults: CalyxConfigFile {
        CalyxConfigFile()
    }

    // MARK: - Read

    /// Reads config from a file path. Returns defaults if file doesn't exist or can't be read.
    static func read(from path: String) -> CalyxConfigFile {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .defaults
        }
        return parse(content)
    }

    // MARK: - Parse

    /// Parses config content string into a CalyxConfigFile. Unknown keys, comments, and
    /// blank lines are ignored. Invalid values fall back to defaults.
    static func parse(_ content: String) -> CalyxConfigFile {
        var config = CalyxConfigFile()

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Must contain '='
            guard let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[trimmed.startIndex..<equalsIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)

            guard let knownKey = Key(rawValue: key) else {
                continue // Unknown key — ignore
            }

            switch knownKey {
            case .glassOpacity:
                if let doubleValue = Double(value) {
                    config.glassOpacity = doubleValue
                }
                // else: keep default
            case .themeColorPreset:
                config.themeColorPreset = value
            case .themeColorCustomHex:
                config.themeColorCustomHex = value
            case .ipcRandomToken:
                if value == "true" {
                    config.ipcRandomToken = true
                } else if value == "false" {
                    config.ipcRandomToken = false
                }
                // else: keep default
            case .ipcToken:
                config.ipcToken = value
            }
        }

        return config
    }

    // MARK: - Write

    /// Writes config to a file path. Creates directories if needed.
    /// Preserves comments and unknown lines when updating an existing file.
    /// Updates known keys in-place, appends new keys at end.
    static func write(_ config: CalyxConfigFile, to path: String) {
        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Track which keys have been written
        var writtenKeys = Set<Key>()

        // Build output lines, preserving existing file structure
        var outputLines: [String] = []

        if let existingContent = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = existingContent.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Preserve comments and blank lines
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    outputLines.append(line)
                    continue
                }

                // Check if this is a known key line
                if let equalsIndex = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[trimmed.startIndex..<equalsIndex])
                        .trimmingCharacters(in: .whitespaces)

                    if let knownKey = Key(rawValue: key) {
                        // Update known key in-place
                        let newValue = config.valueForKey(knownKey)
                        outputLines.append("\(key) = \(newValue)")
                        writtenKeys.insert(knownKey)
                        continue
                    }
                }

                // Preserve unknown lines as-is
                outputLines.append(line)
            }
        }

        // Append any keys not yet written
        for key in Key.allCases where !writtenKeys.contains(key) {
            let value = config.valueForKey(key)
            outputLines.append("\(key.rawValue) = \(value)")
        }

        let output = outputLines.joined(separator: "\n")

        do {
            try output.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write config file: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func valueForKey(_ key: Key) -> String {
        switch key {
        case .glassOpacity:
            return formatDouble(glassOpacity)
        case .themeColorPreset:
            return themeColorPreset
        case .themeColorCustomHex:
            return themeColorCustomHex
        case .ipcRandomToken:
            return ipcRandomToken ? "true" : "false"
        case .ipcToken:
            return ipcToken
        }
    }

    /// Formats a Double, stripping unnecessary trailing zeros.
    private func formatDouble(_ value: Double) -> String {
        // If it's a whole number, show without decimal (e.g., "1" not "1.0")
        if value == value.rounded() && value >= 0 && value <= 1000 {
            let formatted = String(format: "%.1f", value)
            // But keep at least one decimal for values like 0.5
            return formatted
        }
        // For fractional values, use full precision but strip trailing zeros
        let formatted = String(value)
        return formatted
    }
}

// MARK: - CalyxConfig (ObservableObject)

/// Main-actor-isolated observable singleton for SwiftUI/AppKit reactivity.
/// Reads from and writes to `~/.config/calyx/config`.
@MainActor
final class CalyxConfig: ObservableObject {

    static let shared = CalyxConfig()

    static let defaultConfigPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/calyx/config")
    }()

    private let configPath: String
    private var isSuppressingSave = false
    private var pendingSaveWork: DispatchWorkItem?

    @Published var glassOpacity: Double = 0.7 {
        didSet { if !isSuppressingSave { scheduleSave() } }
    }

    @Published var themeColorPreset: String = "original" {
        didSet { if !isSuppressingSave { scheduleSave() } }
    }

    @Published var themeColorCustomHex: String = "#050D1C" {
        didSet { if !isSuppressingSave { scheduleSave() } }
    }

    @Published var ipcRandomToken: Bool = true {
        didSet { if !isSuppressingSave { scheduleSave() } }
    }

    @Published var ipcToken: String = "" {
        didSet { if !isSuppressingSave { scheduleSave() } }
    }

    // MARK: - Init

    private convenience init() {
        self.init(path: CalyxConfig.defaultConfigPath)
    }

    init(path: String) {
        self.configPath = path
        load(from: path)
    }

    // MARK: - Load

    func load(from path: String? = nil) {
        let targetPath = path ?? configPath
        let file = CalyxConfigFile.read(from: targetPath)

        isSuppressingSave = true
        glassOpacity = file.glassOpacity
        themeColorPreset = file.themeColorPreset
        themeColorCustomHex = file.themeColorCustomHex
        ipcRandomToken = file.ipcRandomToken
        ipcToken = file.ipcToken
        isSuppressingSave = false
    }

    // MARK: - Save

    func save(to path: String? = nil) {
        let targetPath = path ?? configPath

        var file = CalyxConfigFile()
        file.glassOpacity = glassOpacity
        file.themeColorPreset = themeColorPreset
        file.themeColorCustomHex = themeColorCustomHex
        file.ipcRandomToken = ipcRandomToken
        file.ipcToken = ipcToken

        CalyxConfigFile.write(file, to: targetPath)

        // Dual-write to UserDefaults for backward compatibility
        UserDefaults.standard.set(glassOpacity, forKey: "terminalGlassOpacity")
        UserDefaults.standard.set(themeColorPreset, forKey: "themeColorPreset")
        UserDefaults.standard.set(themeColorCustomHex, forKey: "themeColorCustomHex")
    }

    // MARK: - Debounced Save

    private func scheduleSave() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.save()
            }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Migration

    /// Migrates settings from UserDefaults to config file if the config file doesn't exist.
    func migrateFromUserDefaultsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configPath) else { return }

        logger.info("Config file not found, migrating from UserDefaults")

        isSuppressingSave = true

        if let opacity = UserDefaults.standard.object(forKey: "terminalGlassOpacity") as? Double {
            glassOpacity = opacity
        }
        if let preset = UserDefaults.standard.string(forKey: "themeColorPreset") {
            themeColorPreset = preset
        }
        if let hex = UserDefaults.standard.string(forKey: "themeColorCustomHex") {
            themeColorCustomHex = hex
        }

        isSuppressingSave = false

        // Write the migrated values to the config file
        save()
    }
}
