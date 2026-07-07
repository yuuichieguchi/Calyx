// SurfaceLocator.swift
// Calyx
//
// Global surfaceID -> live GhosttySurfaceController directory.
// CommandLogStore.shared (and its GhosttyCommandOutputReader) has no
// natural owning Tab/SurfaceRegistry to resolve an arbitrary surfaceID's
// controller across windows/tabs -- SurfaceRegistry itself is owned per
// Tab (Tab.registry), with no cross-tab/cross-window directory. This
// fills that gap. Holds only weak references: this directory must never
// be what keeps a controller alive, and it deliberately has no
// dependency on CommandLogStore or SurfaceRegistry (an earlier version
// had CommandLogStore hold a `var surfaceRegistry = SurfaceRegistry()`,
// whose own `init()` defaults to `commandLogStore = .shared`, re-entering
// `CommandLogStore.shared`'s still-running lazy `static let` initializer
// -- a `dispatch_once` re-entrancy crash, verified at runtime).

import Foundation

/// Generic weak-value registry engine behind `SurfaceLocator`, pulled out
/// as its own type SOLELY so the register/lookup/weak-release mechanics
/// are unit-testable with a lightweight object: a real
/// `GhosttySurfaceController` cannot be constructed in this unit-test
/// host without a live ghostty FFI app (confirmed elsewhere in this
/// codebase to hang the XCTest process -- see
/// AppDelegateAttachWindowTests' header comment), so `SurfaceLocatorTests`
/// exercises this generic engine directly with a lightweight double
/// instead of `SurfaceLocator` itself. `SurfaceLocator` is a thin,
/// concretely-typed wrapper around one instance of this -- not
/// thread-safe on its own; callers are responsible for their own
/// isolation (`SurfaceLocator` provides `@MainActor`).
final class WeakValueRegistry<Key: Hashable, Value: AnyObject> {
    private final class Box {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }

    private var boxes: [Key: Box] = [:]

    init() {}

    /// Current entry count, including any not-yet-pruned stale boxes at
    /// the moment of the call (pruning runs at the START of `register`/
    /// `value(for:)`, so a fresh call to either reflects the count
    /// AFTER pruning).
    var count: Int { boxes.count }

    func register(_ key: Key, value: Value) {
        pruneStaleBoxes()
        boxes[key] = Box(value)
    }

    func unregister(_ key: Key) {
        boxes.removeValue(forKey: key)
    }

    func value(for key: Key) -> Value? {
        pruneStaleBoxes()
        return boxes[key]?.value
    }

    /// Drops every entry whose weak `value` has already been released
    /// (its object deallocated without an explicit `unregister`), so a
    /// caller that forgets to unregister doesn't grow this dictionary
    /// unbounded over the app's lifetime. Opportunistic, not scheduled:
    /// runs on `register`/`value(for:)` rather than a timer, since those
    /// are the only two points that already touch `boxes`.
    private func pruneStaleBoxes() {
        boxes = boxes.filter { _, box in box.value != nil }
    }
}

@MainActor
final class SurfaceLocator {
    static let shared = SurfaceLocator()

    private let registry = WeakValueRegistry<UUID, GhosttySurfaceController>()

    init() {}

    func register(id: UUID, controller: GhosttySurfaceController) {
        registry.register(id, value: controller)
    }

    func unregister(id: UUID) {
        registry.unregister(id)
    }

    func controller(for id: UUID) -> GhosttySurfaceController? {
        registry.value(for: id)
    }
}
