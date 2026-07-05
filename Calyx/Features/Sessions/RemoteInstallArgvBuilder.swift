// RemoteInstallArgvBuilder.swift
// Calyx
//
// Pure function turning (host, bundled resource paths) into the
// calyx-session CLI's own `remote-install` argv
// (calyx-session/crates/cli/src/commands/remote_install.rs: positional
// host, --payload-x86-64/--payload-aarch64/--host-binary/--terminfo).
// Missing bundled payloads/terminfo simply omit their flags entirely —
// this builder never duplicates the CLI's own MissingPayload fail-fast
// validation locally.

import Foundation

enum RemoteInstallArgvBuilder {
    static func buildArgv(
        host: String,
        payloadX86_64Path: String?,
        payloadAarch64Path: String?,
        hostBinaryPath: String?,
        terminfoPath: String?
    ) -> [String] {
        var argv = ["remote-install", host]
        if let payloadX86_64Path {
            argv += ["--payload-x86-64", payloadX86_64Path]
        }
        if let payloadAarch64Path {
            argv += ["--payload-aarch64", payloadAarch64Path]
        }
        if let hostBinaryPath {
            argv += ["--host-binary", hostBinaryPath]
        }
        if let terminfoPath {
            argv += ["--terminfo", terminfoPath]
        }
        return argv
    }
}
