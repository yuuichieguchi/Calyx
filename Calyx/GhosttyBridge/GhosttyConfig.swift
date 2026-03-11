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

    static let glassPresetTemplate: String = """
    # --- Calyx Glass Preset (managed) ---
    background-opacity = 0.82
    font-thicken = true
    minimum-contrast = 1.5
    # --- End Calyx Glass Preset ---
    """

    private static var calyxConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calyx", isDirectory: true)
    }

    private static var calyxGlassPresetURL: URL {
        calyxConfigDir.appendingPathComponent("calyx-glass.conf", isDirectory: false)
    }

    static func removeCursorClickToMoveLine(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("cursor-click-to-move") }
            .joined(separator: "\n")
    }

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

    /// Ensures applyCalyxGlassPresetIfPossible runs only once (prevents file watcher cascading reloads).
    private static var hasAppliedPreset = false

    // MARK: - Loading

    /// Creates a new configuration, loads default files, finalizes, and checks diagnostics.
    /// - Returns: A finalized ghostty_config_t, or nil on failure.
    static func loadDefaultConfig() -> ghostty_config_t? {
        guard let cfg = GhosttyFFI.configNew() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }

        if !hasAppliedPreset {
            applyCalyxGlassPresetIfPossible()
            hasAppliedPreset = true
        }

        // Load configuration from default file locations.
        GhosttyFFI.configLoadDefaultFiles(cfg)

        // Load recursively referenced configuration files.
        GhosttyFFI.configLoadRecursiveFiles(cfg)

        // Explicitly load the Calyx glass preset (bypasses config-file include path issues).
        do {
            let presetPath = calyxGlassPresetURL.path
            if FileManager.default.fileExists(atPath: presetPath) {
                GhosttyFFI.configLoadFile(cfg, path: presetPath)
            }
        }

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

    private static func applyCalyxGlassPresetIfPossible() {
        let ghosttyPath = GhosttyFFI.configOpenPath()
        defer { GhosttyFFI.freeString(ghosttyPath) }

        guard let ptr = ghosttyPath.ptr else { return }
        let pathData = Data(bytes: ptr, count: Int(ghosttyPath.len))
        guard let effectiveConfigPath = String(data: pathData, encoding: .utf8), !effectiveConfigPath.isEmpty else { return }

        let effectiveConfigURL = URL(fileURLWithPath: effectiveConfigPath)
        let fm = FileManager.default
        let appConfigDir = calyxConfigDir
        let presetConfigURL = calyxGlassPresetURL

        let presetStart = "# --- Calyx Glass Preset (managed) ---"
        let presetEnd = "# --- End Calyx Glass Preset ---"

        let includeStart = "# --- Calyx Include (managed) ---"
        let includeEnd = "# --- End Calyx Include ---"
        let includeBlock = """
        \(includeStart)
        config-file = \(presetConfigURL.path)
        \(includeEnd)
        """

        do {
            try fm.createDirectory(at: calyxConfigDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: effectiveConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Migrate from old Application Support path if needed
            if let oldBundleID = Bundle.main.bundleIdentifier,
               let oldAppSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let oldPath = oldAppSupport
                    .appendingPathComponent(oldBundleID, isDirectory: true)
                    .appendingPathComponent("calyx-glass.conf", isDirectory: false)
                if fm.fileExists(atPath: oldPath.path) && !fm.fileExists(atPath: presetConfigURL.path) {
                    try? fm.copyItem(at: oldPath, to: presetConfigURL)
                    try? fm.removeItem(at: oldPath)
                }
            }

            if !fm.fileExists(atPath: presetConfigURL.path) {
                try (glassPresetTemplate + "\n").write(to: presetConfigURL, atomically: true, encoding: .utf8)
            } else {
                let existing = try String(contentsOf: presetConfigURL, encoding: .utf8)
                let migrated = removeCursorClickToMoveLine(from: existing)
                if migrated != existing {
                    try migrated.write(to: presetConfigURL, atomically: true, encoding: .utf8)
                }
            }

            let existingMain = (try? String(contentsOf: effectiveConfigURL, encoding: .utf8)) ?? ""
            var normalizedMain = existingMain

            // Remove legacy managed blocks that directly overrode shared Ghostty config.
            normalizedMain = removeManagedBlock(
                from: normalizedMain,
                startMarker: "# --- Calyx Visual Defaults (managed) ---",
                endMarker: "# --- End Calyx Visual Defaults ---"
            )
            normalizedMain = removeManagedBlock(
                from: normalizedMain,
                startMarker: presetStart,
                endMarker: presetEnd
            )

            if let startRange = normalizedMain.range(of: includeStart),
               let endRange = normalizedMain.range(of: includeEnd, range: startRange.lowerBound..<normalizedMain.endIndex) {
                let replacementRange = startRange.lowerBound..<endRange.upperBound
                normalizedMain = normalizedMain.replacingCharacters(in: replacementRange, with: includeBlock)
            } else if !normalizedMain.contains("config-file = \(presetConfigURL.path)") {
                let separator = normalizedMain.isEmpty || normalizedMain.hasSuffix("\n") ? "" : "\n"
                normalizedMain += separator + "\n" + includeBlock + "\n"
            }

            if normalizedMain != existingMain {
                try normalizedMain.write(to: effectiveConfigURL, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.warning("Failed to apply Calyx glass preset: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removeManagedBlock(from text: String, startMarker: String, endMarker: String) -> String {
        guard let startRange = text.range(of: startMarker),
              let endRange = text.range(of: endMarker, range: startRange.lowerBound..<text.endIndex) else {
            return text
        }
        var mutable = text
        let removeRange = startRange.lowerBound..<endRange.upperBound
        mutable.removeSubrange(removeRange)
        return mutable.replacingOccurrences(of: "\n\n\n", with: "\n\n")
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

    // MARK: - Scrollbar

    enum ScrollbarMode: String {
        case system
        case never
    }

    var scrollbarMode: ScrollbarMode {
        guard let str = getString("scrollbar") else { return .system }
        return ScrollbarMode(rawValue: str) ?? .system
    }
}
