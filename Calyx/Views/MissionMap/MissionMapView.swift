// MissionMapView.swift
// Calyx
//
// Mission Map's root: every pane of the window as a card, banded by tab
// group, with IPC and file-conflict lines between them. All live state
// is read here in `body`, so @Observable tracking re-renders the map as
// agents report (the same way the sidebar's `AgentStatusView` stays
// current); the approval inbox alone arrives through the window
// controller's `.calyxApprovalInboxChanged` refresh. This view turns that
// state into a snapshot, card frames and routed lines, owns the drag and
// selection state, and hands the drawing to `MissionMapContentView`.

import SwiftUI

struct MissionMapView: View {
    /// This window's panes, in window order.
    let panes: () -> [CockpitPaneInfo]
    let gitPoller: MissionMapGitPoller
    /// The selected line or card. Owned by the window controller, which
    /// also clears it from the popover's close button (drawn outside this
    /// view) and on Escape.
    let selection: MissionMapSelection
    /// Committed per-card drag offsets, keyed by card (leaf surface) id.
    /// Owned by the tabs (`Tab.missionMapCardOffsets`), so a reopened map
    /// -- or a restored layout -- keeps the cards where they were dragged.
    let cardOffsets: [UUID: CGSize]
    /// Reports a card's new committed offset (existing + drag
    /// translation) when a drag ends.
    let onCardOffsetChange: (UUID, CGSize) -> Void
    /// A card opened (double click or its open button): focus that pane
    /// and close the map.
    var onFocusSurface: ((UUID) -> Void)?
    /// A single click on a card: select it.
    var onSelectCard: ((UUID) -> Void)?
    /// Escape, from the map's key catcher.
    var onEscape: (() -> Void)?
    /// The cards and lines now on the map, each time that set changes
    /// (and once on appear), so the owner can prune a selection whose
    /// target left (`MissionMapSelection.prune(cards:edges:)`).
    var onSelectableIDsChange: ((MissionMapSelectableIDs) -> Void)?
    var onAllow: ((UUID) -> Void)?
    var onOpenApproval: ((UUID) -> Void)?
    var onKeyCatcherReady: ((NSView) -> Void)?
    /// Where the selected line's popover goes, in this view's `.global`
    /// coordinates (the window's main hosting view), each time that
    /// changes -- on selection, scroll, drag, resize and snapshot
    /// changes; `nil` when the selection is cleared. The
    /// popover is not drawn in this view: see
    /// `MissionMapContentView.popoverLayer(mode:)`.
    var onPopoverPlacementChange: ((MissionMapPopoverPlacementInfo?) -> Void)?
    /// UNIT TEST ONLY: a fabricated map shown instead of live data, so a
    /// test can select a line that is actually on the map (and survives
    /// `MissionMapSelection.prune(cards:edges:)`). Set through
    /// `CalyxWindowController.missionMapFixtureOverride`; takes precedence
    /// over the UI-test launch-argument fixture. `nil` in the app.
    var fixtureOverride: MissionMapFixture?

    static let cardSize = CGSize(width: 260, height: 150)
    /// Between cards, rows, bands and the map's edge: wide enough for
    /// two lines each way through every gap at the router's track
    /// spacing (40 - 2 x 6 margin = 28pt free, 4 tracks x 8pt fit).
    static let spacing: CGFloat = 40
    /// How long an IPC pulse line stays on the map after its message was
    /// sent -- long enough to still be there when the user notices the
    /// notification, alt-tabs to Calyx, and presses Cmd+Shift+M, not just
    /// for someone already staring at an open map.
    static let ipcEdgeLifetime: TimeInterval = 120
    /// The leading slice of `ipcEdgeLifetime` a line draws at full
    /// opacity before `MissionMapCanvasLayer` starts fading it out
    /// linearly across the remainder -- see that type's own `draw(_:in:at:)`.
    static let ipcEdgeFullOpacityDuration: TimeInterval = 10

    /// The drag in progress, if any; committed offsets live in `cardOffsets`.
    @State private var activeDrag: ActiveDrag?
    /// The selected line's popover placement in the scroll content's
    /// coordinates, as `MissionMapContentView` reports it.
    @State private var contentPopoverPlacement: MissionMapPopoverPlacementInfo?
    /// The scroll view's content offset and its frame in `.global`, to
    /// turn `contentPopoverPlacement` into `.global` coordinates.
    @State private var scrollOffset: CGPoint = .zero
    @State private var mapFrame: CGRect = .zero
    /// Bumped when the oldest visible IPC line expires, so the snapshot
    /// is rebuilt and the line leaves (nothing observable changes then).
    @State private var expiryTick = 0
    /// Skips re-routing when a re-render leaves the geometry unchanged.
    @State private var routeCache = MissionMapRouteCache()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// UI TEST ONLY: the fabricated map shown instead of live data when
    /// launched with `MissionMapFixture.uiTestLaunchArgument` (made once,
    /// so its ids -- and the selection -- stay stable across renders).
    /// `nil` in every other launch. `fixtureOverride` wins when set.
    @State private var uiTestFixture: MissionMapFixture? =
        MissionMapFixture.isUITestLaunch ? MissionMapFixture.make(now: Date()) : nil

    private struct ActiveDrag: Equatable {
        let cardID: UUID
        let translation: CGSize
    }

    var body: some View {
        let _ = expiryTick
        let snapshot = makeSnapshot(now: Date())
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content(snapshot: snapshot, viewport: proxy.size)
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
                scrollOffset = offset
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { mapFrame = $0 }
        }
        .overlay(alignment: .bottomTrailing) { MissionMapEscHint() }
        .modifier(MissionMapChromeModifier(reduceTransparency: reduceTransparency))
        .background {
            MissionMapKeyCatcherView(
                onEscape: { onEscape?() },
                onViewReady: { onKeyCatcherReady?($0) }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MissionMap.container)
        .onAppear {
            // UI TEST ONLY: open with the fixture's a1->a2 line selected,
            // so its popover shows without a click.
            if let uiTestFixture {
                selection.selectEdge(uiTestFixture.selectedEdgeID)
            }
        }
        // Not `initial`, and nothing on disappear: when the window
        // controller recreates its main hosting view, the old map
        // disappearing and the new one starting unmeasured must not hide
        // a popover that is still selected -- the new map's first measured
        // placement moves it. Closing the map hides the popover in the
        // controller (`dismissMissionMap`).
        .onChange(of: popoverPlacement) { _, placement in
            onPopoverPlacementChange?(placement)
        }
        .onChange(of: MissionMapSelectableIDs(
            cards: Set(snapshot.cards.map(\.id)), edges: Set(snapshot.edges.map(\.id))
        ), initial: true) { _, ids in
            onSelectableIDsChange?(ids)
        }
        .task(id: nextIPCExpiry(in: snapshot)) {
            guard let expiry = nextIPCExpiry(in: snapshot) else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            } catch {
                // Only cancellation interrupts the sleep: the snapshot
                // changed and a new task took over.
                return
            }
            expiryTick &+= 1
        }
    }

    /// `contentPopoverPlacement` in `.global` coordinates.
    private var popoverPlacement: MissionMapPopoverPlacementInfo? {
        contentPopoverPlacement.map { placement in
            MissionMapPopoverPlacementInfo(
                edge: placement.edge,
                rect: MissionMapPopoverPlacement.windowRect(
                    contentRect: placement.rect, scrollOffset: scrollOffset, mapFrame: mapFrame
                ),
                emphasized: placement.emphasized
            )
        }
    }

    // MARK: - Snapshot

    private func makeSnapshot(now: Date) -> MissionMapSnapshot {
        if let fixture = fixtureOverride ?? uiTestFixture {
            return fixture.snapshot
        }
        let registry = AgentRegistry.shared
        let paneList = panes()
        var children: [UUID: [SubagentEntry]] = [:]
        for pane in paneList {
            let paneChildren = registry.subagentRegistry.children(of: pane.surfaceID)
            if !paneChildren.isEmpty {
                children[pane.surfaceID] = paneChildren
            }
        }
        return MissionMapSnapshotBuilder.build(input: MissionMapInput(
            panes: paneList,
            entries: registry.entries,
            children: children,
            pendingApprovals: ApprovalInboxStore.shared.pending,
            ipcEvents: IPCMessageEventFeed.shared.events,
            peerToSurface: registry.peerToSurfaceMap,
            appPeerID: CalyxMCPServer.shared.appPeerID,
            editedFiles: AgentEditedFileLog.shared.records,
            git: gitPoller.badges,
            now: now,
            conflictWindow: MissionMapConflictDetector.recentWindow,
            ipcEdgeLifetime: Self.ipcEdgeLifetime
        ))
    }

    /// See `MissionMapSnapshot.nextIPCExpiry(in:lifetime:)`: the tick
    /// fires when the oldest live message expires, so the rebuild drops
    /// it from its line.
    private func nextIPCExpiry(in snapshot: MissionMapSnapshot) -> Date? {
        MissionMapSnapshot.nextIPCExpiry(in: snapshot.edges, lifetime: Self.ipcEdgeLifetime)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(snapshot: MissionMapSnapshot, viewport: CGSize) -> some View {
        let area = viewport
        let frames = MissionMapLayout.layout(
            cards: snapshot.cards, groups: snapshot.groups, in: area,
            cardSize: Self.cardSize, spacing: Self.spacing
        )
        let movedFrames = Dictionary(uniqueKeysWithValues: frames.map { id, frame in
            let offset = offset(for: id)
            return (id, frame.offsetBy(dx: offset.width, dy: offset.height))
        })
        let bandOrigins = MissionMapLayout.bandOrigins(
            cards: snapshot.cards, groups: snapshot.groups, in: area,
            cardSize: Self.cardSize, spacing: Self.spacing
        )
        let contentHeight = (frames.values.map(\.maxY).max() ?? 0) + Self.spacing
        let routes = routes(snapshot: snapshot, frames: movedFrames, bandOrigins: bandOrigins, contentSize: CGSize(
            width: viewport.width, height: contentHeight
        ))

        MissionMapContentView(
            snapshot: snapshot,
            frames: movedFrames,
            routes: routes,
            now: Date(),
            bandOrigins: bandOrigins,
            selectedEdgeID: selection.edgeID,
            selectedCardID: selection.cardID,
            animatesEdges: true,
            onBackgroundTap: { point, segments in handleBackgroundTap(at: point, segments: segments) },
            onPopoverPlacementChange: { contentPopoverPlacement = $0 },
            onSelectCard: onSelectCard,
            onFocusSurface: onFocusSurface,
            onAllow: onAllow,
            onOpenApproval: onOpenApproval,
            onDragChanged: { cardID, translation in
                activeDrag = ActiveDrag(cardID: cardID, translation: translation)
            },
            onDragEnded: { cardID, translation in
                let committed = cardOffsets[cardID] ?? .zero
                onCardOffsetChange(cardID, CGSize(
                    width: committed.width + translation.width,
                    height: committed.height + translation.height
                ))
                activeDrag = nil
            }
        )
        // At least the viewport's height, so the background tap layer
        // covers empty space below the last band too.
        .frame(width: viewport.width, height: max(contentHeight, viewport.height), alignment: .topLeading)
    }

    /// Every edge routed around every card (as currently placed, drags
    /// included) and every band header. The routes stay inside the
    /// content rect -- `spacing` around the laid-out cards -- grown to
    /// keep that margin around any card dragged beyond it, so a dragged
    /// card's lines can still reach it.
    private func routes(
        snapshot: MissionMapSnapshot, frames: [UUID: CGRect], bandOrigins: [UUID: CGPoint], contentSize: CGSize
    ) -> [UUID: [CGPoint]] {
        let cardFrames = snapshot.cards.compactMap { frames[$0.id] }
        let obstacles = cardFrames + MissionMapLayout.bandHeaderObstacles(bandOrigins: bandOrigins)
        let bounds = cardFrames.reduce(CGRect(origin: .zero, size: contentSize)) { rect, frame in
            rect.union(frame.insetBy(dx: -Self.spacing, dy: -Self.spacing))
        }
        let requests = snapshot.edges.compactMap { edge -> MissionMapRouteRequest? in
            guard let from = frames[edge.from], let to = frames[edge.to] else { return nil }
            return MissionMapRouteRequest(id: edge.id, from: from, to: to)
        }
        return routeCache.routes(requests, obstacles: obstacles, bounds: bounds)
    }

    /// The committed offset of `cardID` plus any drag in progress.
    private func offset(for cardID: UUID) -> CGSize {
        let committed = cardOffsets[cardID] ?? .zero
        guard let activeDrag, activeDrag.cardID == cardID else { return committed }
        return CGSize(
            width: committed.width + activeDrag.translation.width,
            height: committed.height + activeDrag.translation.height
        )
    }

    /// A tap on a line selects it (showing its popover); a tap on empty
    /// space clears a selection (line or card). It never closes the map:
    /// Escape does (`MissionMapEscHint`).
    private func handleBackgroundTap(at point: CGPoint, segments: [MissionMapEdgeSegment]) {
        let hit = MissionMapEdgeHitTester.nearest(
            point: point,
            polylines: segments.map { (id: $0.id, points: $0.points) }
        )
        if let hit {
            selection.selectEdge(hit)
        } else {
            selection.clear()
        }
    }
}
