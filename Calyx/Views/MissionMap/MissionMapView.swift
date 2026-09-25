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
    var onFocusSurface: ((UUID) -> Void)?
    var onDismiss: (() -> Void)?
    var onAllow: ((UUID) -> Void)?
    var onOpenApproval: ((UUID) -> Void)?
    var onKeyCatcherReady: ((NSView) -> Void)?

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

    /// Committed per-card drag offsets. Memory only: a reopened map
    /// starts from the computed layout again.
    @State private var dragOffsets: [UUID: CGSize] = [:]
    @State private var activeDrag: ActiveDrag?
    @State private var selectedEdgeID: UUID?
    /// Bumped when the oldest visible IPC line expires, so the snapshot
    /// is rebuilt and the line leaves (nothing observable changes then).
    @State private var expiryTick = 0
    /// Skips re-routing when a re-render leaves the geometry unchanged.
    @State private var routeCache = MissionMapRouteCache()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        }
        .modifier(MissionMapChromeModifier(reduceTransparency: reduceTransparency))
        .background {
            MissionMapKeyCatcherView(
                onEscape: { onDismiss?() },
                onViewReady: { onKeyCatcherReady?($0) }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MissionMap.container)
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

    // MARK: - Snapshot

    private func makeSnapshot(now: Date) -> MissionMapSnapshot {
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
            selectedEdgeID: selectedEdgeID,
            animatesEdges: true,
            onBackgroundTap: { point, segments in handleBackgroundTap(at: point, segments: segments) },
            onPopoverTap: { clearEdgeSelection() },
            onFocusSurface: onFocusSurface,
            onAllow: onAllow,
            onOpenApproval: onOpenApproval,
            onDragChanged: { cardID, translation in
                activeDrag = ActiveDrag(cardID: cardID, translation: translation)
            },
            onDragEnded: { cardID, translation in
                let committed = dragOffsets[cardID] ?? .zero
                dragOffsets[cardID] = CGSize(
                    width: committed.width + translation.width,
                    height: committed.height + translation.height
                )
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
        let committed = dragOffsets[cardID] ?? .zero
        guard let activeDrag, activeDrag.cardID == cardID else { return committed }
        return CGSize(
            width: committed.width + activeDrag.translation.width,
            height: committed.height + activeDrag.translation.height
        )
    }

    /// A tap on a line selects it (showing its popover); a tap on empty
    /// space first clears a selection, then closes the map.
    private func handleBackgroundTap(at point: CGPoint, segments: [MissionMapEdgeSegment]) {
        let hit = MissionMapEdgeHitTester.nearest(
            point: point,
            polylines: segments.map { (id: $0.id, points: $0.points) }
        )
        if let hit {
            selectedEdgeID = hit
        } else if selectedEdgeID != nil {
            clearEdgeSelection()
        } else {
            onDismiss?()
        }
    }

    /// Closes the selected line's popover: a tap on empty space while a
    /// line is selected, or a tap on the popover itself.
    private func clearEdgeSelection() {
        selectedEdgeID = nil
    }
}
