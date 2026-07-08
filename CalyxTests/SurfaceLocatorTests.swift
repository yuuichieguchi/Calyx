//
//  SurfaceLocatorTests.swift
//  CalyxTests
//
//  Unit tests for the weak-reference register/lookup/release mechanics
//  behind SurfaceLocator, exercised through WeakValueRegistry directly
//  (the generic engine SurfaceLocator wraps): a real
//  GhosttySurfaceController cannot be constructed in this unit-test host
//  without a live ghostty FFI app (confirmed elsewhere in this codebase
//  to hang the XCTest process -- see AppDelegateAttachWindowTests'
//  header comment), so this file substitutes a lightweight DummyController
//  double, which is all the engine (and SurfaceLocator itself, a thin
//  wrapper around it) actually requires.
//
//  Coverage:
//  - register then lookup returns the same instance
//  - a never-registered key looks up to nil
//  - unregister removes an entry -- lookup after returns nil
//  - a registered value released (no other strong reference) looks up
//    to nil afterward -- the registry holds it only weakly
//  - a stale box (its value already released) is pruned from internal
//    storage on the next value(for:) access, not just resolved to nil
//  - register(_:) also prunes stale boxes, not just value(for:)
//

import XCTest
@testable import Calyx

private final class DummyController {}

final class SurfaceLocatorTests: XCTestCase {

    func test_register_thenLookup_returnsSameInstance() {
        let registry = WeakValueRegistry<UUID, DummyController>()
        let id = UUID()
        let controller = DummyController()

        registry.register(id, value: controller)

        XCTAssertTrue(registry.value(for: id) === controller)
    }

    func test_lookup_neverRegisteredKey_returnsNil() {
        let registry = WeakValueRegistry<UUID, DummyController>()

        XCTAssertNil(registry.value(for: UUID()))
    }

    func test_unregister_removesEntry() {
        let registry = WeakValueRegistry<UUID, DummyController>()
        let id = UUID()
        let controller = DummyController()
        registry.register(id, value: controller)

        registry.unregister(id)

        XCTAssertNil(registry.value(for: id), "unregister must remove the entry, not just leave a dangling box")
    }

    func test_registeredValueReleased_lookupReturnsNil() {
        let registry = WeakValueRegistry<UUID, DummyController>()
        let id = UUID()

        var controller: DummyController? = DummyController()
        registry.register(id, value: controller!)
        XCTAssertNotNil(registry.value(for: id),
                        "Precondition: the registration must resolve while the controller is still alive")

        controller = nil

        XCTAssertNil(registry.value(for: id),
                     "A registry holding only a weak reference must not keep the controller alive -- once " +
                     "released, lookup must return nil")
    }

    func test_pruneStaleBoxes_releasedController_removedFromStorageOnNextLookup() {
        let registry = WeakValueRegistry<UUID, DummyController>()
        let id = UUID()

        var controller: DummyController? = DummyController()
        registry.register(id, value: controller!)
        XCTAssertEqual(registry.count, 1, "Precondition: the registration must add exactly one entry")

        controller = nil

        XCTAssertNil(registry.value(for: id))
        XCTAssertEqual(registry.count, 0,
                       "A stale box (its weak value already released) must be pruned on the next access, " +
                       "not linger indefinitely")
    }

    func test_pruneStaleBoxes_prunedOnRegister_notJustOnLookup() {
        let registry = WeakValueRegistry<UUID, DummyController>()
        let staleID = UUID()

        var stale: DummyController? = DummyController()
        registry.register(staleID, value: stale!)
        stale = nil

        // Registering a completely different entry must ALSO trigger the
        // stale-box sweep, not just value(for:) lookups.
        let freshID = UUID()
        registry.register(freshID, value: DummyController())

        XCTAssertEqual(registry.count, 1, "register(_:) must prune stale boxes too, not just value(for:)")
    }
}
