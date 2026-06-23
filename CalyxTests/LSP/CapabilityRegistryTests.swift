//
//  CapabilityRegistryTests.swift
//  Calyx
//
//  Tests for the `CapabilityRegistry` actor that tracks an LSP server's
//  combined static + dynamic capabilities.
//
//  Spec references:
//    - ServerCapabilities (static, from `initialize` response):
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
//    - client/registerCapability / client/unregisterCapability (dynamic):
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_registerCapability
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_unregisterCapability
//
//  Behaviour under test:
//    - `isCapable(method:)` integrates static + dynamic state. A method is
//      capable iff the static `ServerCapabilities` advertises the relevant
//      provider OR there is a live dynamic registration for it.
//    - `register` / `unregister` mutate the dynamic registration table
//      keyed by registration `id`.
//    - `setStaticCapabilities` overwrites the static slot.
//    - `currentRegistrations` returns a snapshot keyed by `id`.
//    - `currentStaticCapabilities` returns the last-set static caps.
//    - `reset` returns the registry to its empty initial state.
//
//  TDD phase: RED. `CapabilityRegistry` does not exist yet. This file is
//  expected to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/CapabilityRegistry.swift`.
//

import XCTest
@testable import Calyx

@MainActor
final class CapabilityRegistryTests: XCTestCase {

    // MARK: - Helpers

    private func makeRegistry() -> CapabilityRegistry {
        return CapabilityRegistry()
    }

    /// A `ServerCapabilities` advertising a hover provider and a definition
    /// provider via the boolean-true convention.
    private func staticCapsHoverDefinition() -> ServerCapabilities {
        return ServerCapabilities(
            hoverProvider: AnyCodable(true),
            definitionProvider: AnyCodable(true)
        )
    }

    // ====================================================================
    // MARK: - Initial state
    // ====================================================================

    func test_initialState_isCapable_returnsFalseForEverything() async {
        let registry = makeRegistry()
        let methods = [
            "textDocument/hover",
            "textDocument/definition",
            "textDocument/completion",
            "textDocument/didChange",
            "workspace/symbol",
            "foobar/nonsense"
        ]
        for m in methods {
            let capable = await registry.isCapable(method: m)
            XCTAssertFalse(capable, "expected false for \(m) on empty registry")
        }
    }

    func test_initialState_currentRegistrations_isEmpty() async {
        let registry = makeRegistry()
        let regs = await registry.currentRegistrations()
        XCTAssertTrue(regs.isEmpty)
    }

    func test_initialState_currentStaticCapabilities_isNil() async {
        let registry = makeRegistry()
        let caps = await registry.currentStaticCapabilities()
        XCTAssertNil(caps)
    }

    // ====================================================================
    // MARK: - Static capabilities
    // ====================================================================

    func test_setStaticCapabilities_enablesAdvertisedMethods() async {
        let registry = makeRegistry()
        await registry.setStaticCapabilities(staticCapsHoverDefinition())

        let hover = await registry.isCapable(method: "textDocument/hover")
        let def   = await registry.isCapable(method: "textDocument/definition")
        let comp  = await registry.isCapable(method: "textDocument/completion")
        XCTAssertTrue(hover)
        XCTAssertTrue(def)
        XCTAssertFalse(comp, "completion was not advertised; must be false")
    }

    func test_setStaticCapabilities_storesAndReturnsSnapshot() async {
        let registry = makeRegistry()
        let caps = staticCapsHoverDefinition()
        await registry.setStaticCapabilities(caps)
        let got = await registry.currentStaticCapabilities()
        XCTAssertNotNil(got)
        XCTAssertEqual(got, caps)
    }

    func test_setStaticCapabilities_falseProviderDoesNotEnable() async {
        let registry = makeRegistry()
        let caps = ServerCapabilities(hoverProvider: AnyCodable(false))
        await registry.setStaticCapabilities(caps)
        let hover = await registry.isCapable(method: "textDocument/hover")
        XCTAssertFalse(hover)
    }

    // ====================================================================
    // MARK: - Dynamic registration
    // ====================================================================

    func test_register_addsDynamicCapability() async {
        let registry = makeRegistry()
        let reg = Registration(
            id: "reg-1",
            method: "textDocument/didChange",
            registerOptions: nil
        )
        await registry.register([reg])

        let capable = await registry.isCapable(method: "textDocument/didChange")
        XCTAssertTrue(capable)
    }

    func test_register_storesById() async {
        let registry = makeRegistry()
        let r1 = Registration(id: "reg-1", method: "textDocument/didChange")
        let r2 = Registration(id: "reg-2", method: "textDocument/didOpen")
        await registry.register([r1, r2])

        let snapshot = await registry.currentRegistrations()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot["reg-1"], r1)
        XCTAssertEqual(snapshot["reg-2"], r2)
    }

    func test_unregister_removesPreviouslyRegistered() async {
        let registry = makeRegistry()
        let r = Registration(id: "reg-1", method: "textDocument/didChange")
        await registry.register([r])
        var capable = await registry.isCapable(method: "textDocument/didChange")
        XCTAssertTrue(capable)

        await registry.unregister([Unregistration(id: "reg-1", method: "textDocument/didChange")])
        capable = await registry.isCapable(method: "textDocument/didChange")
        XCTAssertFalse(capable, "method should no longer be capable after unregister")

        let snapshot = await registry.currentRegistrations()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_unregister_unknownId_isNoOp() async {
        let registry = makeRegistry()
        let r = Registration(id: "reg-1", method: "textDocument/didChange")
        await registry.register([r])

        // Unregister with a different id; existing registration must survive.
        await registry.unregister([Unregistration(id: "does-not-exist", method: "whatever")])
        let snapshot = await registry.currentRegistrations()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot["reg-1"], r)
    }

    // ====================================================================
    // MARK: - Static + Dynamic union
    // ====================================================================

    func test_isCapable_isUnionOfStaticAndDynamic() async {
        let registry = makeRegistry()
        await registry.setStaticCapabilities(staticCapsHoverDefinition())
        await registry.register([
            Registration(id: "reg-x", method: "textDocument/didChange")
        ])
        let hover     = await registry.isCapable(method: "textDocument/hover")
        let dyn       = await registry.isCapable(method: "textDocument/didChange")
        let stillFalse = await registry.isCapable(method: "textDocument/completion")
        XCTAssertTrue(hover, "static-advertised method should be capable")
        XCTAssertTrue(dyn, "dynamic-registered method should be capable")
        XCTAssertFalse(stillFalse, "method neither advertised nor registered must be false")
    }

    // ====================================================================
    // MARK: - Provider introspection failure
    // ====================================================================

    /// Regression: previously `providerIsTruthy(_:)` returned `true` on JSON
    /// encode/decode failure, so a provider value that cannot be introspected
    /// silently advertised the capability. Downstream MCP tools then
    /// dispatched LSP methods the server could not actually serve. The
    /// helper now returns `false` on introspection failure.
    ///
    /// `AnyCodable(Double.nan)` exercises the encode-failure branch:
    /// `JSONEncoder`'s default `NonConformingFloatEncodingStrategy` is
    /// `.throw`, so encoding a NaN provider value fails and the registry
    /// must report the capability as disabled.
    func test_setStaticCapabilities_nonEncodableProviderIsDisabled() async {
        let registry = makeRegistry()
        let caps = ServerCapabilities(hoverProvider: AnyCodable(Double.nan))
        await registry.setStaticCapabilities(caps)

        let hover = await registry.isCapable(method: "textDocument/hover")
        XCTAssertFalse(
            hover,
            "non-encodable provider value must default to disabled, not enabled"
        )
    }

    // ====================================================================
    // MARK: - Reset
    // ====================================================================

    func test_reset_clearsStaticAndDynamic() async {
        let registry = makeRegistry()
        await registry.setStaticCapabilities(staticCapsHoverDefinition())
        await registry.register([
            Registration(id: "reg-1", method: "textDocument/didChange")
        ])

        // Sanity precondition.
        let preHover = await registry.isCapable(method: "textDocument/hover")
        let preDyn   = await registry.isCapable(method: "textDocument/didChange")
        XCTAssertTrue(preHover)
        XCTAssertTrue(preDyn)

        await registry.reset()

        let postHover = await registry.isCapable(method: "textDocument/hover")
        let postDyn   = await registry.isCapable(method: "textDocument/didChange")
        let staticAfter = await registry.currentStaticCapabilities()
        let regsAfter   = await registry.currentRegistrations()

        XCTAssertFalse(postHover)
        XCTAssertFalse(postDyn)
        XCTAssertNil(staticAfter)
        XCTAssertTrue(regsAfter.isEmpty)
    }
}
