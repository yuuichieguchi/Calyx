// SessionRemotePayloadResolver.swift
// Calyx
//
// Resolves the bundled resources `RemoteInstallArgvBuilder` needs for
// a remote-install run: the cross-compiled Linux musl payloads (per
// arch) and the bundled ghostty terminfo entry. Bundle layout (see
// project.yml's "Bundle Remote Session Binaries"/"Copy Ghostty
// Resources" postBuildScripts):
//   - Resources/session-remote/<x86_64|aarch64>/calyx-session
//   - Resources/terminfo/78/xterm-ghostty ("78" is 'x' hashed by
//     ncurses' first-letter convention, matching the CLI's own
//     REMOTE_TERMINFO_DIR "$HOME/.terminfo/x" layout)

import Foundation

protocol SessionRemotePayloadResolverProtocol: Sendable {
    /// The bundled cross-compiled `calyx-session` payload's absolute
    /// path for `arch` ("x86_64" or "aarch64"), or `nil` if not
    /// bundled (e.g. a Debug build without a prior `--all` build).
    func payloadPath(forArch arch: String) -> String?
    /// The bundled ghostty terminfo entry's absolute path, or `nil` if
    /// not bundled.
    func terminfoPath() -> String?
}

struct SessionRemotePayloadResolver: SessionRemotePayloadResolverProtocol {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func payloadPath(forArch arch: String) -> String? {
        bundle.url(forResource: "calyx-session", withExtension: nil, subdirectory: "session-remote/\(arch)")?.path
    }

    func terminfoPath() -> String? {
        bundle.url(forResource: "xterm-ghostty", withExtension: nil, subdirectory: "terminfo/78")?.path
    }
}
