import AppKit
import GhosttyKit

// Protocol for testability
@MainActor
protocol ConfigFileOpening {
    func configOpenPath() -> String
    func fileExists(at path: String) -> Bool
    func isDirectory(at path: String) -> Bool
    func isSymlink(at path: String) -> Bool
    mutating func createParentDirectory(for path: String) throws
    mutating func createFileExclusively(at path: String) throws
    func openFile(at url: URL) -> Bool
    func revealInFinder(url: URL)
}

enum ConfigFileOpenResult: Equatable {
    case opened
    case createdAndOpened
    case error(ConfigFileOpenError)
}

enum ConfigFileOpenError: Equatable {
    case emptyPath
    case isDirectory
    case isSymlink
    case createFailed(String)
    case openFailed
}

/// Namespace for config file operations.
enum ConfigFileOpener {
    /// Opens the ghostty config file, creating it if needed.
    @MainActor
    static func openConfigFile<T: ConfigFileOpening>(using opener: inout T) -> ConfigFileOpenResult {
        let rawPath = opener.configOpenPath()
        guard !rawPath.isEmpty else { return .error(.emptyPath) }

        let normalizedPath = URL(fileURLWithPath: rawPath).standardized.path

        // Check if path is a directory
        if opener.isDirectory(at: normalizedPath) {
            return .error(.isDirectory)
        }

        // Check if path is a symlink
        if opener.isSymlink(at: normalizedPath) {
            return .error(.isSymlink)
        }

        let fileURL = URL(fileURLWithPath: normalizedPath)

        if opener.fileExists(at: normalizedPath) {
            // File exists — just open it
            if opener.openFile(at: fileURL) {
                return .opened
            } else {
                return .error(.openFailed)
            }
        }

        // File doesn't exist — create parent dir, create file, then open
        do {
            try opener.createParentDirectory(for: normalizedPath)
            try opener.createFileExclusively(at: normalizedPath)
        } catch {
            return .error(.createFailed(String(describing: error)))
        }

        if opener.openFile(at: fileURL) {
            return .createdAndOpened
        } else {
            return .error(.openFailed)
        }
    }
}

/// Real implementation using FileManager and NSWorkspace.
@MainActor
struct SystemConfigFileOpener: ConfigFileOpening {
    func configOpenPath() -> String {
        let ghosttyPath = GhosttyFFI.configOpenPath()
        defer { GhosttyFFI.freeString(ghosttyPath) }
        guard let ptr = ghosttyPath.ptr else { return "" }
        let data = Data(bytes: ptr, count: Int(ghosttyPath.len))
        return String(data: data, encoding: .utf8) ?? ""
    }

    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func isDirectory(at path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    func isSymlink(at path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    func createParentDirectory(for path: String) throws {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        // Verify it's actually a directory via lstat
        var st = stat()
        guard lstat(parentURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw NSError(domain: "ConfigFileOpener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Parent path is not a directory"])
        }
    }

    func createFileExclusively(at path: String) throws {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: "ConfigFileOpener", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        // Verify it's a regular file via fstat
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw NSError(domain: "ConfigFileOpener", code: 2, userInfo: [NSLocalizedDescriptionKey: "Created file is not a regular file"])
        }
        Darwin.close(fd)
    }

    func openFile(at url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
