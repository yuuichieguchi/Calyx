import Foundation

enum ShellEscape {
    /// Escapes shell-sensitive characters by prefixing each with a backslash.
    /// Escape set matches Ghostty rev 332b2aefc (`Ghostty.Shell.swift` line 4).
    static func escape(_ str: String) -> String {
        // Backslash must be first to prevent double-escaping.
        let specialChars = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = str
        for char in specialChars {
            result = result.replacingOccurrences(
                of: String(char),
                with: "\\\(char)"
            )
        }
        return result
    }
}
