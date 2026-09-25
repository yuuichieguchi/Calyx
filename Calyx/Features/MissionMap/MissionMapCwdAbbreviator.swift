// MissionMapCwdAbbreviator.swift
// Calyx
//
// Formats a pane's cwd for a Mission Map card: short enough for a card
// width, but with more context than the sidebar's bare basename, since
// several cards often sit in sibling directories of one repository.

import Foundation

enum MissionMapCwdAbbreviator {

    /// - `nil` or empty -> `"N/A"`, `AgentRowDisplay.cwdLabel`'s own
    ///   placeholder.
    /// - Under `home`: `"~/"` + the path relative to `home`, keeping only
    ///   its last `maxComponents` components behind `"…/"` when longer.
    /// - Elsewhere: unchanged when it has at most `maxComponents`
    ///   components, otherwise `"…/"` + the last `maxComponents`.
    static func abbreviate(_ path: String?, home: String, maxComponents: Int = 2) -> String {
        guard let path, !path.isEmpty else { return "N/A" }

        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path == home || path + "/" == homePrefix {
            return "~"
        }
        if path.hasPrefix(homePrefix) {
            let relative = components(of: String(path.dropFirst(homePrefix.count)))
            guard relative.count > maxComponents else { return "~/" + relative.joined(separator: "/") }
            return "~/…/" + relative.suffix(maxComponents).joined(separator: "/")
        }

        let all = components(of: path)
        guard all.count > maxComponents else { return path }
        return "…/" + all.suffix(maxComponents).joined(separator: "/")
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
