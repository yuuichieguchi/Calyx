// GhosttyConfig.swift
// Calyx
//
// Wraps ghostty_config_t lifecycle and provides configuration access.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GhosttyConfig")

// MARK: - GhosttyConfigManager

@MainActor
final class GhosttyConfigManager {

    /// The underlying ghostty configuration handle.
    nonisolated(unsafe) private(set) var config: ghostty_config_t? = nil {
        didSet {
            guard let old = oldValue else { return }
            GhosttyFFI.configFree(old)
        }
    }

    /// Whether the configuration has been successfully loaded.
    var isLoaded: Bool { config != nil }

    /// Returns diagnostics (errors/warnings) from the current configuration.
    var diagnostics: [String] {
        guard let cfg = config else { return [] }
        let count = GhosttyFFI.configDiagnosticsCount(cfg)
        var result: [String] = []
        for i in 0..<count {
            let diag = GhosttyFFI.configGetDiagnostic(cfg, index: i)
            result.append(String(cString: diag.message))
        }
        return result
    }

    // MARK: - Initialization

    init() {
        self.config = Self.loadDefaultConfig()
    }

    /// Initialize with a clone of an existing config.
    init(clone source: ghostty_config_t) {
        self.config = GhosttyFFI.configClone(source)
    }

    deinit {
        // Setting to nil triggers the didSet which calls configFree.
        config = nil
    }

    // MARK: - Loading

    /// Creates a new configuration, loads default files, finalizes, and checks diagnostics.
    /// - Returns: A finalized ghostty_config_t, or nil on failure.
    static func loadDefaultConfig() -> ghostty_config_t? {
        guard let cfg = GhosttyFFI.configNew() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }

        // Load configuration from default file locations.
        GhosttyFFI.configLoadDefaultFiles(cfg)

        // Load recursively referenced configuration files.
        GhosttyFFI.configLoadRecursiveFiles(cfg)

        // Finalize makes defaults available.
        GhosttyFFI.configFinalize(cfg)

        // Log any configuration diagnostics.
        let diagCount = GhosttyFFI.configDiagnosticsCount(cfg)
        if diagCount > 0 {
            logger.warning("Configuration loaded with \(diagCount) diagnostic(s)")
            for i in 0..<diagCount {
                let diag = GhosttyFFI.configGetDiagnostic(cfg, index: i)
                let message = String(cString: diag.message)
                logger.warning("Config diagnostic: \(message)")
            }
        }

        return cfg
    }

    /// Reload the configuration from disk.
    /// - Returns: `true` if the reload succeeded.
    @discardableResult
    func reload() -> Bool {
        guard let newConfig = Self.loadDefaultConfig() else {
            logger.error("Failed to reload configuration")
            return false
        }
        self.config = newConfig
        return true
    }

    /// Clone the current configuration.
    func cloneConfig() -> ghostty_config_t? {
        guard let cfg = config else { return nil }
        return GhosttyFFI.configClone(cfg)
    }

    // MARK: - Config Value Access

    /// Get a boolean configuration value.
    func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    /// Get a string configuration value.
    func getString(_ key: String) -> String? {
        guard let cfg = config else { return nil }
        var v: UnsafePointer<Int8>? = nil
        let found = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &v, ptr, UInt(key.utf8.count))
        }
        guard found, let ptr = v else { return nil }
        return String(cString: ptr)
    }

    /// Get a double configuration value.
    func getDouble(_ key: String, default defaultValue: Double = 0) -> Double {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    /// Get an integer configuration value.
    func getInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    /// Get a UInt configuration value.
    func getUInt(_ key: String, default defaultValue: UInt = 0) -> UInt {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    /// Get a color configuration value.
    func getColor(_ key: String) -> ghostty_config_color_s? {
        guard let cfg = config else { return nil }
        var color = ghostty_config_color_s()
        let found = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &color, ptr, UInt(key.utf8.count))
        }
        return found ? color : nil
    }

    /// Generic typed config access via pointer.
    /// - Parameters:
    ///   - key: The configuration key.
    ///   - value: Pointer to the value to populate.
    /// - Returns: `true` if the value was found.
    func get<T>(_ key: String, value: inout T) -> Bool {
        guard let cfg = config else { return false }
        return key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
    }

    // MARK: - Derived Properties

    var initialWindow: Bool {
        getBool("initial-window", default: true)
    }

    var shouldQuitAfterLastWindowClosed: Bool {
        getBool("quit-after-last-window-closed", default: false)
    }

    var title: String? {
        getString("title")
    }

    var windowDecorations: Bool {
        guard let str = getString("window-decoration") else { return true }
        return str != "none"
    }

    var windowStepResize: Bool {
        getBool("window-step-resize", default: false)
    }

    var backgroundOpacity: Double {
        getDouble("background-opacity", default: 1.0)
    }

    var backgroundColor: NSColor {
        guard let color = getColor("background") else { return .windowBackgroundColor }
        return NSColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }

    var focusFollowsMouse: Bool {
        getBool("focus-follows-mouse", default: false)
    }
}
