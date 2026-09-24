// HerdrPaneRegistry.swift
// Calyx
//
// The paneID-to-surfaceID side table, keyed both ways:
//   surfaceID -> HerdrPaneRef (which herdr pane a given ghostty surface
//   bridges)
//   (socketPath, paneID) -> surfaceID (which surface, if any, currently
//   bridges a given herdr pane)
// Subsumes HerdrHostedSurfaces's role: isBridgeSurface(_:)
// replaces HerdrHostedSurfaces.contains(_:) for every purpose that
// file's own header describes, letting the title-heuristic
// ingestion skip a pane whose "real" state already arrives over herdr's
// own event stream.
//
// SINGLE-CONTROLLER INVARIANT (1 pane, 1 controller): registering a NEW
// surfaceID for a (socketPath, paneID) pair some OTHER surfaceID
// already claims evicts that other surfaceID from the registry entirely
// -- two surfaces must never simultaneously claim to bridge the same
// herdr pane.
//
// BRIDGE OBSERVER (HerdrPaneBridgeObserver, set via setBridgeObserver):
// a single, weakly-held observer notified of every ref whose bridge
// state changed, once the triggering register/unregister mutation has
// already completed -- mirrors HerdrStructureEventObserver's own weak
// single-observer shape (HerdrIntegrationCoordinator.swift) exactly.
// register(surfaceID:ref:) fires once for the newly registered ref, and
// -- only when it displaces a DIFFERENT ref previously held by the SAME
// surfaceID -- once more, first, for that displaced ref. A call that
// changes nothing (the same surfaceID re-registered with the IDENTICAL
// ref) fires nothing at all, mirroring unregister's own "notified only
// when a removal actually happened" contract below. The
// single-controller eviction path above fires only for the newly
// registered ref, never once per surfaceID the mutation happens to
// touch, since the evicted surfaceID's own ref is identical to the one
// already being reported -- adequate for a consumer that matches by the
// ref's own resolved pane, as HerdrAgentMirror does, but not a general
// guarantee: the payload carries the ref alone, never a surfaceID, so
// it cannot tell any observer that a SPECIFIC surfaceID (the evicted
// one) stopped bridging. No call site reaches that gap today --
// register's only two production callers are session restore and
// workspace attach, and workspace attach's own focusExistingTab guard
// (HerdrTabCoordinator.openWorkspace) already returns before
// re-attaching a workspace whose panes it previously registered -- but
// an observer needing a per-surface bridge-loss signal would need a
// different notification than this one. The .calyxSurfaceDestroyed
// self-prune path below routes through unregister, so it inherits this
// notification for free, identical to a direct unregister(surfaceID:)
// call.
//
// Pruned via .calyxSurfaceDestroyed (AgentRegistry.swift's notification,
// posted by SurfaceRegistry.destroySurface with userInfo["surfaceID"])
// -- mirrors HerdrHostedSurfaces's identical prune-on-teardown shape
// exactly (same notification, same NSObject/@objc-selector wiring), so
// this class fits the codebase's one established idiom for that
// notification instead of inventing a second one.
//
// HerdrPaneRef is Equatable but deliberately NOT Hashable (see that
// file's own header) and this file must not modify HerdrPaneRef.swift,
// so the reverse (socketPath, paneID) -> surfaceID map is keyed by a
// composite string rather than the ref itself, its socket path
// canonicalized (standardized() + resolvingSymlinksInPath()) so a lookup
// by a differently spelled path to the same socket still matches -- a NUL
// byte joiner
// (socket paths and pane ids are both plain text that cannot contain
// one) rather than a plain colon, since paneID already contains one
// ("wB:p1").
//
// "shared singleton + injectable": .shared is the real, process-wide
// instance every production call site uses, but init() is not private,
// so a test can construct its own throwaway instance instead of
// fighting cross-test pollution on .shared -- identical to
// HerdrHostedSurfaces's own init() shape.

import Foundation

// MARK: - HerdrPaneBridgeObserver

/// Notified whenever a herdr pane's bridge state changes: a
/// (socketPath, paneID) becomes newly bridged to a Calyx surface, an
/// existing bridge moves to a different surface, or a bridge is
/// removed. Fired AFTER the triggering `register`/`unregister` mutation
/// has already completed, with the affected `HerdrPaneRef`.
/// `setBridgeObserver` stores its argument WEAKLY, mirroring
/// `HerdrStructureEventObserver`'s own weak single-observer shape
/// (`HerdrIntegrationCoordinator.swift`) exactly: this registry never
/// owns an observer's own lifecycle.
@MainActor
protocol HerdrPaneBridgeObserver: AnyObject {
    func herdrPaneBridgeDidChange(ref: HerdrPaneRef)
}

// MARK: - HerdrPaneRegistry

@MainActor
final class HerdrPaneRegistry: NSObject {

    static let shared = HerdrPaneRegistry()

    private var refsBySurfaceID: [UUID: HerdrPaneRef] = [:]
    private var surfaceIDByPaneKey: [String: UUID] = [:]
    private var isObserving = false

    /// See `HerdrPaneBridgeObserver`'s own doc comment -- stored
    /// WEAKLY, set via `setBridgeObserver`, never through `init`.
    private weak var bridgeObserver: (any HerdrPaneBridgeObserver)?

    override init() {
        super.init()
    }

    /// Registers `observer` to be notified of every bridge-state change
    /// -- see `HerdrPaneBridgeObserver`'s own doc comment. Stored
    /// WEAKLY: pass `nil` to clear; a deallocated observer simply stops
    /// being notified rather than being kept alive by this registry.
    func setBridgeObserver(_ observer: (any HerdrPaneBridgeObserver)?) {
        bridgeObserver = observer
    }

    /// Idempotent: a second call is a no-op, mirroring
    /// HerdrHostedSurfaces.startObserving()'s own precedent.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    /// Records that `surfaceID` bridges the herdr pane `ref` describes.
    /// Re-registering the same `surfaceID` replaces its ref and clears
    /// the old (socketPath, paneID) reverse mapping. If some OTHER
    /// surfaceID already claims `ref`'s (socketPath, paneID) pair, that
    /// surfaceID is evicted entirely first (single-controller invariant:
    /// see this file's header). Notifies the bridge observer once the
    /// mutation has fully completed, but only when the registry's state
    /// actually changed as a result -- see this file's header "BRIDGE
    /// OBSERVER" for the exact firing rules.
    func register(surfaceID: UUID, ref: HerdrPaneRef) {
        let previousRef = refsBySurfaceID[surfaceID]
        let key = Self.paneKey(ref)
        // Captured BEFORE any mutation below: a fully idempotent
        // re-register (previousRef == ref) removes and immediately
        // re-adds this same key's entry, so reading it any later would
        // see this call's own re-insertion instead of the prior state.
        let priorOwnerOfKey = surfaceIDByPaneKey[key]

        if let previousRef {
            surfaceIDByPaneKey.removeValue(forKey: Self.paneKey(previousRef))
        }
        if let priorSurfaceID = surfaceIDByPaneKey[key], priorSurfaceID != surfaceID {
            refsBySurfaceID.removeValue(forKey: priorSurfaceID)
        }
        refsBySurfaceID[surfaceID] = ref
        surfaceIDByPaneKey[key] = surfaceID

        if let previousRef, previousRef != ref {
            bridgeObserver?.herdrPaneBridgeDidChange(ref: previousRef)
        }
        // Fires for the new ref unless NOTHING changed: this surfaceID
        // already held this exact ref, and this exact ref's key was
        // already owned by this same surfaceID (the two can only ever
        // disagree if the registry's own forward/reverse maps have
        // fallen out of sync with each other).
        if previousRef != ref || priorOwnerOfKey != surfaceID {
            bridgeObserver?.herdrPaneBridgeDidChange(ref: ref)
        }
    }

    /// Removes `surfaceID` from both the forward and reverse mapping.
    /// A `surfaceID` never registered is a no-op -- including for the
    /// bridge observer, which is notified only when a removal actually
    /// happened.
    func unregister(surfaceID: UUID) {
        guard let ref = refsBySurfaceID.removeValue(forKey: surfaceID) else { return }
        surfaceIDByPaneKey.removeValue(forKey: Self.paneKey(ref))
        bridgeObserver?.herdrPaneBridgeDidChange(ref: ref)
    }

    /// Whether `surfaceID` currently bridges a herdr pane.
    func isBridgeSurface(_ surfaceID: UUID) -> Bool {
        refsBySurfaceID[surfaceID] != nil
    }

    /// The herdr pane `surfaceID` bridges, if any.
    func paneRef(forSurfaceID surfaceID: UUID) -> HerdrPaneRef? {
        refsBySurfaceID[surfaceID]
    }

    /// The surfaceID currently bridging `(socketPath, paneID)`, if any.
    /// socketPath is part of the pane's identity: the same paneID text
    /// under a different socket never resolves (HerdrPaneRef.swift's
    /// own header on why two independent herdr sockets can reuse pane
    /// numbering).
    func surfaceID(forPaneID paneID: String, socketPath: String) -> UUID? {
        surfaceIDByPaneKey[Self.paneKey(socketPath: socketPath, paneID: paneID)]
    }

    /// Prunes the destroyed surface's entry, mirroring
    /// HerdrHostedSurfaces.handleSurfaceDestroyed(_:)'s identical
    /// userInfo["surfaceID"] extraction (SurfaceRegistry
    /// .destroySurface's own post shape). A `surfaceID` this instance
    /// never registered is a no-op.
    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        unregister(surfaceID: id)
    }

    private static func paneKey(_ ref: HerdrPaneRef) -> String {
        paneKey(socketPath: ref.socketPath, paneID: ref.paneID)
    }

    /// The socket path is canonicalized first (`standardized` and
    /// `resolvingSymlinksInPath`), so spellings of the same socket that
    /// differ by a trailing slash, a doubled separator, or a symlinked
    /// component key the same pane.
    private static func paneKey(socketPath: String, paneID: String) -> String {
        "\(canonicalSocketPath(socketPath))\u{0}\(paneID)"
    }

    private static func canonicalSocketPath(_ socketPath: String) -> String {
        URL(fileURLWithPath: socketPath).standardized.resolvingSymlinksInPath().path
    }

    #if DEBUG
    /// Test-only: undoes startObserving(), mirroring
    /// HerdrHostedSurfaces._stopObserving()'s own precedent exactly.
    /// Safe to call even if startObserving() was never called. DO NOT
    /// use from production code.
    func _stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }
    #endif
}
