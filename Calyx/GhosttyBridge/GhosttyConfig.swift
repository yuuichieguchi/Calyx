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
    background-blur = macos-glass-regular
    # --- End Calyx Glass Preset ---
    """

    /// Keys that Calyx manages (overrides from user's ghostty config).
    /// Used for UI display in Settings and drift-prevention tests.
    static let managedKeys: [String] = [
        "background-opacity",
        "background-blur",
        "background-opacity-cells",
        "font-codepoint-map",
    ]

    private static var calyxConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calyx", isDirectory: true)
    }

    private static var calyxGlassPresetURL: URL {
        calyxConfigDir.appendingPathComponent("calyx-glass.conf", isDirectory: false)
    }

    private static var calyxRuntimeOverrideURL: URL {
        calyxConfigDir.appendingPathComponent("calyx-runtime.conf", isDirectory: false)
    }

    /// Remove lines whose key (left-hand side of `=`) matches any entry in `keys`.
    /// Comment lines (starting with `#`) are preserved. Blank lines are preserved.
    static func removeConfigKeys(_ keys: [String], from text: String) -> String {
        let keySet = Set(keys)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let eqIndex = trimmed.firstIndex(of: "=") else {
                    return true  // keep blank lines, comments, and non-assignment lines
                }
                let key = trimmed[trimmed.startIndex..<eqIndex]
                    .trimmingCharacters(in: .whitespaces)
                return !keySet.contains(key)
            }
            .joined(separator: "\n")
    }

    static func removeCursorClickToMoveLine(from text: String) -> String {
        removeConfigKeys(["cursor-click-to-move"], from: text)
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

    /// Guards one-time setup (file creation, migration, stale block cleanup).
    /// Note: configLoadFile for calyx-glass.conf runs on EVERY loadDefaultConfig call regardless of this flag.
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

        // Load Calyx glass preset after default files so its values take precedence.
        let presetPath = calyxGlassPresetURL.path
        if FileManager.default.fileExists(atPath: presetPath) {
            GhosttyFFI.configLoadFile(cfg, path: presetPath)
        }

        // Load runtime override last so UI slider state always wins.
        applyRuntimeOverrides(cfg)

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

    private static func applyRuntimeOverrides(_ cfg: ghostty_config_t) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: calyxConfigDir, withIntermediateDirectories: true)

            let sliderOpacity = UserDefaults.standard.object(forKey: "terminalGlassOpacity") as? Double ?? 0.7
            let clampedOpacity = max(0.0, min(1.0, sliderOpacity))
            let text = """
            # --- Calyx Runtime Override (managed) ---
            background-opacity = \(String(format: "%.3f", clampedOpacity))
            background-blur = macos-glass-regular
            background-opacity-cells = false
            font-codepoint-map = U+2600-U+27BF=Apple Color Emoji
            font-codepoint-map = U+1F300-U+1F5FF=Apple Color Emoji
            font-codepoint-map = U+1F600-U+1F64F=Apple Color Emoji
            font-codepoint-map = U+1F680-U+1F6FF=Apple Color Emoji
            font-codepoint-map = U+1F7E0-U+1F7FF=Apple Color Emoji
            font-codepoint-map = U+1F900-U+1F9FF=Apple Color Emoji
            font-codepoint-map = U+1FA70-U+1FAFF=Apple Color Emoji
            font-codepoint-map = U+FE00-U+FE0F=Apple Color Emoji
            # --- End Calyx Runtime Override ---
            """

            try (text + "\n").write(to: calyxRuntimeOverrideURL, atomically: true, encoding: .utf8)
            GhosttyFFI.configLoadFile(cfg, path: calyxRuntimeOverrideURL.path)
        } catch {
            logger.warning("Failed to apply runtime overrides: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func applyCalyxGlassPresetIfPossible() {
        let fm = FileManager.default
        let presetConfigURL = calyxGlassPresetURL

        do {
            // 1. Create ~/.config/calyx/ directory if needed.
            try fm.createDirectory(at: calyxConfigDir, withIntermediateDirectories: true)

            // 2. Migrate from old Application Support path if needed.
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

            // 3. Create calyx-glass.conf with defaults if it doesn't exist.
            if !fm.fileExists(atPath: presetConfigURL.path) {
                try (glassPresetTemplate + "\n").write(to: presetConfigURL, atomically: true, encoding: .utf8)
            } else {
                // 4. Remove deprecated keys from existing calyx-glass.conf (migration).
                let existing = try String(contentsOf: presetConfigURL, encoding: .utf8)
                let migrated = removeConfigKeys(
                    ["cursor-click-to-move", "font-thicken", "minimum-contrast"],
                    from: existing
                )
                if migrated != existing {
                    try migrated.write(to: presetConfigURL, atomically: true, encoding: .utf8)
                }
            }

            // 5. One-time cleanup: remove stale managed blocks from the main ghostty config.
            cleanupMainGhosttyConfig(fileManager: fm)
        } catch {
            logger.warning("Failed to apply Calyx glass preset: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes any stale Calyx-managed blocks from the main ghostty config file.
    /// Resolves symlinks and verifies the path is safe before writing.
    private static func cleanupMainGhosttyConfig(fileManager fm: FileManager) {
        let ghosttyPath = GhosttyFFI.configOpenPath()
        defer { GhosttyFFI.freeString(ghosttyPath) }

        guard let ptr = ghosttyPath.ptr else { return }
        let pathData = Data(bytes: ptr, count: Int(ghosttyPath.len))
        guard let effectiveConfigPath = String(data: pathData, encoding: .utf8),
              !effectiveConfigPath.isEmpty else { return }

        let effectiveConfigURL = URL(fileURLWithPath: effectiveConfigPath)

        // Resolve symlinks to get the real path.
        let resolvedPath = effectiveConfigURL.resolvingSymlinksInPath().path
        let homeDir = fm.homeDirectoryForCurrentUser.path

        // Safety: only write if resolved path is under ~/.config/ or ~/Library/Application Support/.
        let allowedPrefixes = [
            homeDir + "/.config/",
            homeDir + "/Library/Application Support/",
        ]
        guard allowedPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) else {
            logger.warning("Skipping main config cleanup: resolved path '\(resolvedPath, privacy: .public)' is outside allowed directories")
            return
        }

        guard let existingMain = try? String(contentsOf: effectiveConfigURL, encoding: .utf8) else { return }
        var cleaned = existingMain

        // Remove all known Calyx-managed block types.
        cleaned = removeManagedBlock(
            from: cleaned,
            startMarker: "# --- Calyx Visual Defaults (managed) ---",
            endMarker: "# --- End Calyx Visual Defaults ---"
        )
        cleaned = removeManagedBlock(
            from: cleaned,
            startMarker: "# --- Calyx Glass Preset (managed) ---",
            endMarker: "# --- End Calyx Glass Preset ---"
        )
        cleaned = removeManagedBlock(
            from: cleaned,
            startMarker: "# --- Calyx Include (managed) ---",
            endMarker: "# --- End Calyx Include ---"
        )

        // Write back only if changes were made.
        if cleaned != existingMain {
            do {
                try cleaned.write(to: effectiveConfigURL, atomically: true, encoding: .utf8)
                logger.info("Cleaned stale Calyx managed blocks from ghostty config")
            } catch {
                logger.warning("Failed to clean main ghostty config: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func removeManagedBlock(from text: String, startMarker: String, endMarker: String) -> String {
        var mutable = text
        while let startRange = mutable.range(of: startMarker),
              let endRange = mutable.range(of: endMarker, range: startRange.lowerBound..<mutable.endIndex) {
            mutable.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            mutable = mutable.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return mutable
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
