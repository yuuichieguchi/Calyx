// MissionMapView.swift
// Calyx
//
// Mission Map's root: every pane of the window as a card, banded by tab
// group, with IPC and file-conflict lines between them. All live state
// is read here in `body`, so @Observable tracking re-renders the map as
// agents report (the same way the sidebar's `AgentStatusView` stays
// current); the approval inbox alone arrives through the window
// controller's `.calyxApprovalInboxChanged` refresh.

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
    static let spacing: CGFloat = 16
    static let ipcEdgeLifetime: TimeInterval = 6

    private static let coordinateSpaceName = "calyx.missionMap.content"

    /// Committed per-card drag offsets. Memory only: a reopened map
    /// starts from the computed layout again.
    @State private var dragOffsets: [UUID: CGSize] = [:]
    @State private var activeDrag: ActiveDrag?
    @State private var selectedEdgeID: UUID?
    /// Bumped when the oldest visible IPC line expires, so the snapshot
    /// is rebuilt and the line leaves (nothing observable changes then).
    @State private var expiryTick = 0
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

    private func nextIPCExpiry(in snapshot: MissionMapSnapshot) -> Date? {
        snapshot.edges.compactMap { edge -> Date? in
            guard case .ipc(let event) = edge.kind else { return nil }
            return event.sentAt.addingTimeInterval(Self.ipcEdgeLifetime)
        }.min()
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
        let segments = snapshot.edges.compactMap { edge -> MissionMapEdgeSegment? in
            guard let from = movedFrames[edge.from], let to = movedFrames[edge.to] else { return nil }
            let (a, b) = MissionMapLayout.edgeAnchors(from: from, to: to)
            return MissionMapEdgeSegment(edge: edge, a: a, b: b)
        }
        let contentHeight = (frames.values.map(\.maxY).max() ?? 0) + Self.spacing

        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named(Self.coordinateSpaceName)) { point in
                    handleBackgroundTap(at: point, segments: segments)
                }

            MissionMapCanvasLayer(
                segments: segments,
                ipcEdgeLifetime: Self.ipcEdgeLifetime,
                selectedEdgeID: selectedEdgeID
            )

            ForEach(snapshot.groups) { group in
                if let origin = bandOrigins[group.id] {
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: MissionMapLayout.bandHeaderHeight, alignment: .leading)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                }
            }

            ForEach(snapshot.cards) { card in
                if let frame = movedFrames[card.id] {
                    cardView(card)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }

            if let selectedEdgeID, let segment = segments.first(where: { $0.id == selectedEdgeID }) {
                MissionMapEdgePopover(edge: segment.edge)
                    .position(segment.midpoint)
            }
        }
        // At least the viewport's height, so the background tap layer
        // covers empty space below the last band too.
        .frame(width: viewport.width, height: max(contentHeight, viewport.height), alignment: .topLeading)
        .coordinateSpace(.named(Self.coordinateSpaceName))
    }

    private func cardView(_ card: MissionMapCard) -> some View {
        MissionMapCardView(
            card: card,
            onFocus: {
                guard let target = card.focusTarget else { return }
                onFocusSurface?(target)
            },
            onAllow: onAllow,
            onOpenApproval: onOpenApproval,
            onDragChanged: { activeDrag = ActiveDrag(cardID: card.id, translation: $0) },
            onDragEnded: { translation in
                let committed = dragOffsets[card.id] ?? .zero
                dragOffsets[card.id] = CGSize(
                    width: committed.width + translation.width,
                    height: committed.height + translation.height
                )
                activeDrag = nil
            }
        )
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
            edges: segments.map { (id: $0.id, a: $0.a, b: $0.b) }
        )
        if let hit {
            selectedEdgeID = hit
        } else if selectedEdgeID != nil {
            selectedEdgeID = nil
        } else {
            onDismiss?()
        }
    }
}
