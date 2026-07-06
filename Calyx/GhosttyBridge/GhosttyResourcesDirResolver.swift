// GhosttyResourcesDirResolver.swift
// Calyx
//
// Checks whether Calyx's bundled ghostty resources (Contents/Resources/
// ghostty, see project.yml's "Copy Ghostty Resources" postBuildScript)
// actually contain a shell-integration directory, before
// GhosttyResourcesDirEnvironment ever points GHOSTTY_RESOURCES_DIR at
// them. Parameterized on a resources root URL rather than Bundle.main
// (mirrors SessionRemotePayloadResolver's `init(bundle: Bundle = .main)`
// testability precedent, but as a raw root URL here since this is a
// plain directory-existence check, not a Bundle resource lookup).

import Foundation

struct GhosttyResourcesDirResolver {
    private let resourcesRoot: URL

    init(resourcesRoot: URL) {
        self.resourcesRoot = resourcesRoot
    }

    /// `resourcesRoot`'s bundled `ghostty` directory's own path, or `nil`
    /// if that directory has no `shell-integration` subdirectory (e.g. a
    /// Debug build without a prior full resource-copy build, or an
    /// incomplete/corrupt bundle layout).
    func resolve() -> String? {
        let ghosttyDir = resourcesRoot.appendingPathComponent("ghostty")
        let shellIntegrationDir = ghosttyDir.appendingPathComponent("shell-integration")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: shellIntegrationDir.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return nil
        }

        return ghosttyDir.path
    }
}
