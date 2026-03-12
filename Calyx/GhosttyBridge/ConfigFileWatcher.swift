// ConfigFileWatcher.swift
// Calyx
//
// Watches the ghostty config file for changes using DispatchSource.
// libghostty does not include a file watcher — this is the app runtime's responsibility.

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "ConfigFileWatcher")

/// Watches the ghostty config file (and any config-file includes) for modifications.
/// Uses GCD DispatchSource for efficient kernel-level file monitoring.
@MainActor
final class ConfigFileWatcher {

    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: @MainActor () -> Void

    /// Initialize and start watching the ghostty config file.
    /// - Parameter onChange: Called on the main thread when a config file is modified.
    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        startWatching()
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }

    private func startWatching() {
        // Get the config file path from ghostty.
        let ghosttyPath = GhosttyFFI.configOpenPath()
        defer { GhosttyFFI.freeString(ghosttyPath) }

        guard let ptr = ghosttyPath.ptr else {
            logger.warning("Could not determine ghostty config path")
            return
        }

        let pathData = Data(bytes: ptr, count: Int(ghosttyPath.len))
        guard let configPath = String(data: pathData, encoding: .utf8),
              !configPath.isEmpty else {
            logger.warning("Empty ghostty config path")
            return
        }

        // Collect all config paths to watch.
        var pathsToWatch: Set<String> = [configPath]

        // Also watch ~/.config/ghostty/config (XDG default location).
        let xdgPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        if FileManager.default.fileExists(atPath: xdgPath) {
            pathsToWatch.insert(xdgPath)
        }

        for path in pathsToWatch {
            watchFile(at: path)
            let dir = (path as NSString).deletingLastPathComponent
            watchDirectory(at: dir, fileName: (path as NSString).lastPathComponent)
        }

        logger.info("Watching \(pathsToWatch.count) config path(s)")
    }

    private func watchFile(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open config file for watching: \(path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleFileEvent()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
    }

    private func watchDirectory(at dirPath: String, fileName: String) {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleFileEvent()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
    }

    private func handleFileEvent() {
        onChange()
    }
}
