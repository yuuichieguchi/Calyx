import Foundation

struct InstallSource {
    enum Source: Equatable {
        case homebrew
        case direct
    }

    let bundleURL: URL

    var source: Source {
        // Resolve symlinks to get the real path
        let resolved = bundleURL.resolvingSymlinksInPath().standardized
        let components = resolved.pathComponents

        // Check for /Caskroom/calyx/ in path components (token-based, not substring)
        // Look for consecutive components: "Caskroom" followed by "calyx"
        for i in 0..<components.count - 1 {
            if components[i] == "Caskroom" && components[i + 1] == "calyx" {
                return .homebrew
            }
        }

        return .direct
    }

    var isHomebrew: Bool { source == .homebrew }
}
