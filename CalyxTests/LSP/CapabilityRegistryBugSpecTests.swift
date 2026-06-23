//
//  CapabilityRegistryBugSpecTests.swift
//  Calyx
//
//  Regression tests for `CapabilityRegistry.providerIsTruthy` semantics.
//
//  Bug under test:
//    The private helper `providerIsTruthy(_:)` previously returned `true`
//    when JSON encode/decode of the provider value failed, silently
//    advertising capabilities the LSP server did not actually support.
//    Downstream MCP tools then dispatched LSP methods that the server
//    could not serve.
//
//  Post-fix contract:
//    * boolean `true`  -> capability enabled
//    * boolean `false` -> capability disabled
//    * empty options object `{}` -> capability enabled (LSP convention)
//    * JSON null / introspection failure -> capability disabled (the bug)
//
//  These tests pin the contract through the public surface
//  `CapabilityRegistry.isCapable(method:)`, which is the only consumer
//  of the private `providerIsTruthy` helper.
//
//  Independent from `CapabilityRegistryTests.swift`: different class
//  name, different sample inputs, focused on the truthiness contract
//  rather than the static/dynamic union or registration lifecycle.
//

import XCTest
@testable import Calyx

@MainActor
final class CapabilityRegistryBugSpecTests: XCTestCase {

    // MARK: - Helpers

    /// Build a `ServerCapabilities` whose hover provider is the supplied
    /// test value. Every other field is left nil so that
    /// `isCapable(method: "textDocument/hover")` evaluates exactly one
    /// provider — the one we are pinning.
    private func hoverOnlyCaps(provider: AnyCodable) -> ServerCapabilities {
        return ServerCapabilities(hoverProvider: provider)
    }

    /// Drive a fresh registry through `setStaticCapabilities` with the
    /// supplied hover provider and return what `isCapable` reports for
    /// `textDocument/hover`. The actor is created per call so cases never
    /// leak state into each other.
    private func hoverIsCapable(provider: AnyCodable) async -> Bool {
        let registry = CapabilityRegistry()
        await registry.setStaticCapabilities(hoverOnlyCaps(provider: provider))
        return await registry.isCapable(method: "textDocument/hover")
    }

    // ====================================================================
    // MARK: - Branch 1: explicit boolean `true`
    // ====================================================================

    /// LSP `boolean | Options`: a literal `true` advertises the capability
    /// with default options. The registry must report it enabled. Pinning
    /// the positive bool path guards against an over-correction of the
    /// encode/decode-failure default ever flipping `true` to disabled.
    func test_providerLiteralTrue_enablesCapability() async {
        let capable = await hoverIsCapable(provider: AnyCodable(true))
        XCTAssertTrue(
            capable,
            "boolean `true` provider must enable the LSP capability"
        )
    }

    // ====================================================================
    // MARK: - Branch 2: explicit boolean `false`
    // ====================================================================

    /// LSP `boolean | Options`: a literal `false` explicitly opts the
    /// server OUT of the capability. The registry must NOT report it as
    /// enabled even though the field is present (non-nil) on the static
    /// capabilities snapshot.
    func test_providerLiteralFalse_doesNotEnableCapability() async {
        let capable = await hoverIsCapable(provider: AnyCodable(false))
        XCTAssertFalse(
            capable,
            "boolean `false` provider must NOT enable the LSP capability"
        )
    }

    // ====================================================================
    // MARK: - Branch 3: empty-object `{}` (LSP "enabled, no options")
    // ====================================================================

    /// LSP allows an empty options object `{}` as the sentinel for
    /// "capability supported, no further configuration". The registry
    /// must treat it as enabled. This case shares the trailing
    /// `return true` arm with array / non-bool dictionary providers, and
    /// is the canonical positive example for the Options half of the
    /// `boolean | Options` union.
    func test_providerEmptyOptionsObject_enablesCapability() async {
        let provider = AnyCodable([String: AnyCodable]())
        let capable = await hoverIsCapable(provider: provider)
        XCTAssertTrue(
            capable,
            "empty options object `{}` must enable the LSP capability"
        )
    }

    // ====================================================================
    // MARK: - Branch 4a: non-truthy provider (JSON null)
    // ====================================================================

    /// `AnyCodable(NSNull())` routes through the `init(_ value: Any)`
    /// default arm and stores `.null`, encoding as JSON `null`. After
    /// JSON round-trip `providerIsTruthy` sees an `NSNull` and must
    /// short-circuit to disabled — the registry must NOT advertise a
    /// capability whose provider value is null.
    func test_providerJSONNull_doesNotEnableCapability() async {
        let provider = AnyCodable(NSNull())
        let capable = await hoverIsCapable(provider: provider)
        XCTAssertFalse(
            capable,
            "JSON null provider must NOT enable the LSP capability"
        )
    }

    // ====================================================================
    // MARK: - Branch 4b: introspection failure (the actual regression)
    // ====================================================================

    /// THE regression case. `JSONEncoder`'s default
    /// `NonConformingFloatEncodingStrategy = .throw` rejects
    /// `Double.infinity`, so encoding a provider wrapping it throws.
    /// Pre-fix, `providerIsTruthy` swallowed the throw and returned
    /// `true`, silently advertising a capability whose value could not
    /// even be introspected. Post-fix it must default to `false`.
    ///
    /// Uses `.infinity` rather than `.nan` (which the sibling
    /// `CapabilityRegistryTests` already exercises) so this file
    /// independently pins the introspection-failure default without
    /// duplicating that assertion.
    func test_providerEncodeFailure_defaultsToDisabled() async {
        let provider = AnyCodable(Double.infinity)
        let capable = await hoverIsCapable(provider: provider)
        XCTAssertFalse(
            capable,
            "introspection-failure provider must default to disabled (was incorrectly `true` before the fix)"
        )
    }
}
