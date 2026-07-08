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

    /// Reverse lookup: the key whose (pruned, still-live) weak-boxed
    /// value is identical (`===`) to `value`. Kept inside
    /// `WeakValueRegistry` rather than exposing box iteration to callers,
    /// so the weak-box internals stay encapsulated -- O(n) entries, fine
    /// at the pane/surface counts this engine is used at. Pruning on
    /// every read (here and in `value(for:)`) is O(n) too, on a path
    /// (`SurfacePropertyStore`'s per-notification title/pwd resolution)
    /// that can fire once per OSC 7/title write -- acceptable at normal
    /// pane counts; revisit (e.g. prune on a timer instead of every
    /// read) if a shell that title-spams at very high pane counts ever
    /// makes this measurably hot.
    func key(forValue value: Value) -> Key? {
        pruneStaleBoxes()
        return boxes.first(where: { $0.value.value === value })?.key
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

    #if DEBUG
    /// Test-only: drops every entry regardless of liveness. DO NOT use
    /// from production code.
    func removeAll() {
        boxes.removeAll()
    }
    #endif
}

@MainActor
final class SurfaceLocator {
    static let shared = SurfaceLocator()

    private let registry = WeakValueRegistry<UUID, GhosttySurfaceController>()

    /// Second weak index, surfaceID -> live `SurfaceView`, kept in
    /// lockstep with `registry` (registered/unregistered at the same
    /// call sites in `SurfaceRegistry`). Added for `SurfacePropertyStore`
    /// (Cockpit's app-wide per-surface title/cwd tracker): its
    /// `.ghosttySetTitle`/`.ghosttySetPwd` handlers only ever see a
    /// `SurfaceView` (the notification's `object`), with no owning
    /// Tab/SurfaceRegistry of their own to resolve it against -- the
    /// same cross-tab/cross-window gap `registry` above already exists
    /// to fill, just in the opposite direction.
    private let viewsByID = WeakValueRegistry<UUID, SurfaceView>()

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

    func registerView(id: UUID, view: SurfaceView) {
        viewsByID.register(id, value: view)
    }

    func unregisterView(id: UUID) {
        viewsByID.unregister(id)
    }

    func id(forView view: SurfaceView) -> UUID? {
        viewsByID.key(forValue: view)
    }

    #if DEBUG
    /// Test-only: clears both the controller and view weak indices.
    /// `SurfaceLocator.shared` is a global singleton that persists
    /// across test cases within the same process -- entries registered
    /// by `SurfaceRegistry._testInsert` (or `createSurface`) in one test
    /// would otherwise leak into an unrelated test's lookups. DO NOT use
    /// from production code.
    func _testReset() {
        registry.removeAll()
        viewsByID.removeAll()
    }
    #endif
}
