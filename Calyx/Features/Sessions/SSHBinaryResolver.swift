// SSHBinaryResolver.swift
// Calyx
//
// Resolves the system `ssh` binary's path for `SessionCommandSynthesizer.
// remoteAttachCommand`, mirroring `SessionBinaryResolver`'s own
// env-override-then-production-default shape so both binary resolvers in
// this feature agree on the same seam pattern and can each be swapped for
// a fake in tests without poking global environment state at the call
// site.

import Foundation

protocol SSHBinaryResolverProtocol: Sendable {
    /// The system `ssh` binary's absolute path to exec as
    /// `remoteAttachCommand`'s first word.
    func resolve() -> String
}

/// Production resolver: `CALYX_SSH_BIN` env override (dev workflow /
/// test injection), then the literal absolute `/usr/bin/ssh`.
/// Deliberately an absolute path rather than a bare `"ssh"` literal
/// resolved via `PATH`: ghostty execs `remoteAttachCommand`'s first word
/// directly (see `SessionCommandSynthesizer.remoteAttachCommand`'s own
/// doc comment), and while a slashless word like `"ssh"` would still
/// PATH-search correctly under `/bin/sh -c`, the absolute path removes
/// any ambiguity and matches `SessionBinaryResolver`'s own local-binary
/// precedent of never relying on `PATH` for a security-relevant
/// executable.
struct SSHBinaryResolver: SSHBinaryResolverProtocol {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> String {
        if let override = environment["CALYX_SSH_BIN"], !override.isEmpty {
            return override
        }
        return "/usr/bin/ssh"
    }
}
