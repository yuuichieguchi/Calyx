//
//  HerdrPaneRegistryTests.swift
//  CalyxTests
//
//  Tests: HerdrPaneRegistry, the paneID-to-surfaceID
//  side table, keyed both ways --
//    surfaceID -> HerdrPaneRef (which herdr pane a given ghostty surface
//    bridges)
//    (socketPath, paneID) -> surfaceID (which surface, if any, currently
//    bridges a given herdr pane)
//  -- and the type that subsumes HerdrHostedSurfaces role:
//  isBridgeSurface(_:) replaces HerdrHostedSurfaces.contains(_:) for
//  every purpose HerdrHostedSurfaces.swift's own header describes --
//  letting title-heuristic ingestion skip a pane whose "real"
//  state already arrives over herdr's own event stream.
//
//  DI/lifecycle shape mirrors HerdrHostedSurfaces.swift exactly: a
//  non-private init() so each test constructs its own throwaway
//  instance (no cross-test pollution on a shared singleton),
//  startObserving() idempotently subscribes to .calyxSurfaceDestroyed
//  (AgentRegistry.swift's notification, posted by
//  SurfaceRegistry.destroySurface with userInfo["surfaceID"]), and a
//  DEBUG-only _stopObserving() test teardown hook (SurfacePropertyStore
//  /HerdrHostedSurfaces's own established precedent).
//
//  SINGLE-CONTROLLER INVARIANT (1 pane, 1 controller): registering a
//  NEW surfaceID for a (socketPath, paneID) pair some OTHER surfaceID
//  already claims evicts that other surfaceID from the registry
//  entirely -- two surfaces must never simultaneously claim to bridge
//  the same herdr pane.
//
//  HerdrPaneRef is Equatable but deliberately NOT Hashable (see that
//  file's own header), and this file must not touch HerdrPaneRef.swift,
//  so none of these tests build a Set<HerdrPaneRef> or use HerdrPaneRef
//  as a Dictionary key -- the registry's own reverse-lookup storage is
//  an implementation detail these tests never assume a shape for.
//
//  Coverage:
//  - register(surfaceID:ref:) then isBridgeSurface(_:) true; an unknown
//    surfaceID reads false
//  - surfaceID(forPaneID:socketPath:) returns the registered surface;
//    the same paneID under a DIFFERENT socketPath returns nil (socket
//    path is part of the pane's identity -- mirrors HerdrPaneRef.swift's
//    own header on why two independent herdr sockets can reuse the same
//    pane numbering)
//  - paneRef(forSurfaceID:) returns the registered ref
//  - unregister(surfaceID:) removes both the forward and reverse
//    mapping
//  - a .calyxSurfaceDestroyed notification for a registered surface
//    prunes only that surface, leaving an unrelated registered surface
//    untouched
//  - re-registering the SAME surfaceID with a DIFFERENT ref replaces it
//    (no duplicate reverse-mapping entries: the OLD (socketPath,
//    paneID) pair no longer resolves to this surface)
//  - registering a DIFFERENT surfaceID for a (socketPath, paneID) pair
//    an existing surfaceID already claims evicts the existing surfaceID
//
//  BRIDGE OBSERVER (HerdrPaneBridgeObserver, set via setBridgeObserver):
//  a single weakly-held observer, notified of every ref whose bridge
//  state changed, once the triggering mutation has already completed.
//  Mirrors HerdrStructureEventObserver's own weak single-observer shape
//  (HerdrIntegrationCoordinator.swift) exactly.
//  - register(surfaceID:ref:) notifies the observer once, with the
//    newly registered ref
//  - re-registering the SAME surfaceID with the IDENTICAL ref (a fully
//    idempotent call that changes nothing) notifies the observer nothing
//    at all
//  - unregister(surfaceID:) of a registered surfaceID notifies the
//    observer once, with the removed ref; of a surfaceID never
//    registered, notifies nothing
//  - re-registering the SAME surfaceID with a DIFFERENT ref notifies the
//    observer twice: once for the old ref, once for the new one
//  - the single-controller eviction path (register(surfaceID:ref:) for a
//    (socketPath, paneID) pair another surfaceID already claims)
//    notifies the observer exactly once, for the newly registered ref --
//    never once per surfaceID the mutation touches
//  - the .calyxSurfaceDestroyed self-prune path notifies the observer
//    for the pruned ref, exactly like a direct unregister(surfaceID:)
//    call would
//  - the observer is held weakly: once the only strong reference to it
//    is dropped, a later register(surfaceID:ref:)/unregister(surfaceID:)
//    neither crashes nor notifies anything
//

import XCTest
@testable import Calyx

@MainActor
private final class RecordingBridgeObserver: HerdrPaneBridgeObserver {
    private(set) var receivedRefs: [HerdrPaneRef] = []

    func herdrPaneBridgeDidChange(ref: HerdrPaneRef) {
        receivedRefs.append(ref)
    }
}

@MainActor
final class HerdrPaneRegistryTests: XCTestCase {

    private var registry: HerdrPaneRegistry!

    override func setUp() {
        super.setUp()
        registry = HerdrPaneRegistry()
    }

    override func tearDown() {
        registry._stopObserving()
        registry = nil
        super.tearDown()
    }

    // MARK: - register / isBridgeSurface

    func test_register_thenIsBridgeSurface_true() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertTrue(registry.isBridgeSurface(surfaceID))
    }

    func test_isBridgeSurface_unknownSurface_false() {
        XCTAssertFalse(registry.isBridgeSurface(UUID()))
    }

    // MARK: - surfaceID(forPaneID:socketPath:)

    func test_surfaceIDForPaneID_returnsRegisteredSurface() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            surfaceID
        )
    }

    func test_surfaceIDForPaneID_sameIDDifferentSocketPath_returnsNil() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/tmp/a-different-herdr.sock"),
            "socketPath is part of a pane's identity -- the same paneID text under a different socket must not resolve"
        )
    }

    // MARK: - paneRef(forSurfaceID:)

    func test_paneRefForSurfaceID_returnsRegisteredRef() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertEqual(registry.paneRef(forSurfaceID: surfaceID), ref)
    }

    func test_paneRefForSurfaceID_unknownSurface_returnsNil() {
        XCTAssertNil(registry.paneRef(forSurfaceID: UUID()))
    }

    // MARK: - unregister

    func test_unregister_removesBothDirections() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        registry.unregister(surfaceID: surfaceID)

        XCTAssertFalse(registry.isBridgeSurface(surfaceID))
        XCTAssertNil(registry.paneRef(forSurfaceID: surfaceID))
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            "unregister must also clear the reverse (socketPath, paneID) -> surfaceID mapping"
        )
    }

    // MARK: - .calyxSurfaceDestroyed pruning

    func test_surfaceDestroyedNotification_prunesOnlyThatSurface_leavesUnrelatedSurfaceIntact() {
        let destroyedSurface = UUID()
        let destroyedRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let survivingSurface = UUID()
        let survivingRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        registry.register(surfaceID: destroyedSurface, ref: destroyedRef)
        registry.register(surfaceID: survivingSurface, ref: survivingRef)
        registry.startObserving()

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": destroyedSurface])

        XCTAssertFalse(registry.isBridgeSurface(destroyedSurface), "a destroyed surface must be pruned")
        XCTAssertNil(registry.paneRef(forSurfaceID: destroyedSurface))
        XCTAssertNil(registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"))

        XCTAssertTrue(
            registry.isBridgeSurface(survivingSurface),
            "an unrelated, still-live surface must survive another surface's destroy notification -- an " +
            "implementation that clears the whole registry on any destroy would wrongly pass a single-surface " +
            "version of this test"
        )
        XCTAssertEqual(registry.paneRef(forSurfaceID: survivingSurface), survivingRef)
    }

    // MARK: - Replace (same surfaceID, different ref)

    func test_register_sameSurfaceIDTwiceWithDifferentRef_replacesWithoutStaleReverseMapping() {
        let surfaceID = UUID()
        let firstRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let secondRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        registry.register(surfaceID: surfaceID, ref: firstRef)
        registry.register(surfaceID: surfaceID, ref: secondRef)

        XCTAssertEqual(
            registry.paneRef(forSurfaceID: surfaceID), secondRef,
            "a second registration for the same surfaceID must replace the ref, not add a duplicate"
        )
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            "the OLD (socketPath, paneID) reverse mapping must not linger once the surface has moved on"
        )
        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wC:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            surfaceID
        )
    }

    // MARK: - Single-controller invariant (eviction)

    func test_register_secondSurfaceClaimingSamePane_evictsFirstSurface() {
        let firstSurface = UUID()
        let secondSurface = UUID()
        let sharedRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        registry.register(surfaceID: firstSurface, ref: sharedRef)
        registry.register(surfaceID: secondSurface, ref: sharedRef)

        XCTAssertFalse(
            registry.isBridgeSurface(firstSurface),
            "1 pane, 1 controller: a second surface claiming the same (socketPath, paneID) must evict the " +
            "first, never let two surfaces bridge the same herdr pane simultaneously"
        )
        XCTAssertNil(registry.paneRef(forSurfaceID: firstSurface))

        XCTAssertTrue(registry.isBridgeSurface(secondSurface))
        XCTAssertEqual(registry.paneRef(forSurfaceID: secondSurface), sharedRef)
        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            secondSurface
        )
    }

    // MARK: - Bridge observer: register

    func test_register_firesBridgeObserverOnce_withRegisteredRef() {
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertEqual(
            observer.receivedRefs, [ref],
            "register must fire the bridge observer exactly once, with the newly registered ref"
        )
    }

    // MARK: - Bridge observer: idempotent re-register

    func test_register_sameSurfaceIDSameRef_firesBridgeObserverNothing() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertTrue(
            observer.receivedRefs.isEmpty,
            "re-registering the same surfaceID with the identical ref changes nothing in the registry and must " +
            "not fire the bridge observer at all"
        )
    }

    // MARK: - Bridge observer: unregister

    func test_unregister_ofRegisteredSurfaceID_firesBridgeObserverOnce_withRemovedRef() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        registry.unregister(surfaceID: surfaceID)

        XCTAssertEqual(
            observer.receivedRefs, [ref],
            "unregister must fire the bridge observer exactly once, with the removed ref"
        )
    }

    func test_unregister_ofNeverRegisteredSurfaceID_firesBridgeObserverNothing() {
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        registry.unregister(surfaceID: UUID())

        XCTAssertTrue(
            observer.receivedRefs.isEmpty,
            "unregister of a surfaceID that was never registered must not fire the bridge observer at all"
        )
    }

    // MARK: - Bridge observer: replace (same surfaceID, different ref)

    func test_register_sameSurfaceIDDifferentRef_firesBridgeObserverTwice_forOldRefThenNewRef() {
        let surfaceID = UUID()
        let firstRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let secondRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")
        registry.register(surfaceID: surfaceID, ref: firstRef)
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        registry.register(surfaceID: surfaceID, ref: secondRef)

        XCTAssertEqual(
            observer.receivedRefs, [firstRef, secondRef],
            "replacing the same surfaceID's ref must fire the bridge observer twice: once for the old ref " +
            "being displaced, once for the new ref taking its place"
        )
    }

    // MARK: - Bridge observer: single-controller eviction

    func test_register_secondSurfaceClaimingSamePane_firesBridgeObserverExactlyOnce_withNewRef() {
        let firstSurface = UUID()
        let secondSurface = UUID()
        let sharedRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: firstSurface, ref: sharedRef)
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        registry.register(surfaceID: secondSurface, ref: sharedRef)

        XCTAssertEqual(
            observer.receivedRefs, [sharedRef],
            "the single-controller eviction path must fire the bridge observer exactly once, for the newly " +
            "registered ref -- not once per surfaceID the mutation happens to touch"
        )
    }

    // MARK: - Bridge observer: .calyxSurfaceDestroyed self-prune

    func test_surfaceDestroyedNotification_firesBridgeObserver_withPrunedRef() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)
        registry.startObserving()
        let observer = RecordingBridgeObserver()
        registry.setBridgeObserver(observer)

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": surfaceID])

        XCTAssertEqual(
            observer.receivedRefs, [ref],
            "the .calyxSurfaceDestroyed self-prune path routes through unregister and must fire the bridge " +
            "observer for the pruned ref exactly like a direct unregister(surfaceID:) call would"
        )
    }

    // MARK: - Bridge observer: held weakly

    func test_setBridgeObserver_holdsObserverWeakly_registerAfterDeallocationDoesNotCrash_recordsNothing() {
        weak var weakObserver: RecordingBridgeObserver?
        do {
            let observer = RecordingBridgeObserver()
            weakObserver = observer
            registry.setBridgeObserver(observer)
            // `observer`'s only strong reference is this local -- goes
            // out of scope at the end of this `do` block.
        }

        XCTAssertNil(
            weakObserver,
            "setBridgeObserver must hold its argument weakly: the observer must deallocate once its only " +
            "strong reference (this test's own local) goes out of scope"
        )

        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref) // must not crash with a deallocated observer

        XCTAssertTrue(
            registry.isBridgeSurface(surfaceID),
            "registration itself must still succeed normally even after the bridge observer has deallocated"
        )
    }

    // MARK: - Socket path key canonicalization (calyx-mcp herdr-first pane resolution)
    //
    // `/calyx-mcp`'s herdr-first pane resolution (plan §4) looks a pane
    // up by (X-Calyx-Herdr-Socket-Path header value, X-Calyx-Herdr-Pane-ID
    // header value). The header value and the value herdr itself used at
    // register() time need not be byte-identical (a trailing slash, a
    // double slash, or a symlinked path component) even though they name
    // the same socket -- so both register and lookup must canonicalize
    // the socket path (standardized() + resolvingSymlinksInPath()) before
    // keying on it.

    func test_surfaceIDForPaneID_trailingSlashInLookupSocketPath_stillResolves() {
        let registry = HerdrPaneRegistry()
        let surfaceID = UUID()
        registry.register(
            surfaceID: surfaceID,
            ref: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        )

        let resolved = registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock/")
        XCTAssertEqual(
            resolved, surfaceID,
            "a lookup socket path differing only by a trailing slash must resolve to the same surface " +
            "registered under the canonical form"
        )
    }

    func test_surfaceIDForPaneID_doubleSlashInLookupSocketPath_stillResolves() {
        let registry = HerdrPaneRegistry()
        let surfaceID = UUID()
        registry.register(
            surfaceID: surfaceID,
            ref: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        )

        let resolved = registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev//.config/herdr/herdr.sock")
        XCTAssertEqual(
            resolved, surfaceID,
            "a lookup socket path differing only by a doubled path separator must resolve to the same " +
            "registered surface"
        )
    }

    func test_register_thenLookupWithCanonicallyEquivalentButDifferentlySpelledPath_singleControllerInvariantHolds() {
        // register() itself must canonicalize too: registering the SAME
        // pane twice, once under each spelling, must be treated as the
        // SAME (socketPath, paneID) key -- the second register replaces
        // the first rather than the single-controller eviction picking a
        // seemingly-different key.
        let registry = HerdrPaneRegistry()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()

        registry.register(
            surfaceID: firstSurfaceID,
            ref: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        )
        registry.register(
            surfaceID: secondSurfaceID,
            ref: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock/", paneID: "wB:p1")
        )

        XCTAssertFalse(
            registry.isBridgeSurface(firstSurfaceID),
            "registering the same pane under a canonically-equivalent but differently-spelled socket path " +
            "must evict the first surface (single-controller invariant), not create two independent entries"
        )
        XCTAssertTrue(registry.isBridgeSurface(secondSurfaceID))
        XCTAssertEqual(registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"), secondSurfaceID)
    }
}
