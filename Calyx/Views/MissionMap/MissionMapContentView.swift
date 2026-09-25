// MissionMapContentView.swift
// Calyx
//
// Mission Map's drawing, from given data only: band headers, the routed
// lines, the cards, and the selected line's popover. It reads no
// observable state, so the same view renders the live map (fed by
// `MissionMapView`) and a fixed snapshot (a render fixture). Interaction
// is reported through the optional callbacks.

import SwiftUI

/// How Mission Map's surfaces are drawn.
enum MissionMapRenderStyle: Sendable {
    /// Liquid Glass cards over whatever is behind the map (the live map).
    case glass
    /// The same layout on a solid dark background with solid cards, for
    /// static rendering (e.g. `ImageRenderer`), where glass has nothing
    /// to show through and renders nearly invisible.
    case flat

    /// #1C1C24
    static let flatBackground = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x24 / 255)
    /// #2A2A36
    static let flatCardFill = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x36 / 255)
    /// #55556A
    static let flatCardBorder = Color(red: 0x55 / 255, green: 0x55 / 255, blue: 0x6A / 255)
}

struct MissionMapContentView: View {
    let snapshot: MissionMapSnapshot
    /// Each card's on-screen frame (drag offsets already applied).
    let frames: [UUID: CGRect]
    /// Each edge's route from `MissionMapRouter`, keyed by edge id. An
    /// edge without a route is not drawn.
    let routes: [UUID: [CGPoint]]
    /// The instant the lines are drawn at when `animatesEdges` is false.
    let now: Date
    /// Where each band's name is drawn, keyed by group id.
    var bandOrigins: [UUID: CGPoint] = [:]
    var selectedEdgeID: UUID?
    /// Whether the lines animate on a timeline (the live map) or are
    /// drawn once at `now`.
    var animatesEdges = false
    var renderStyle: MissionMapRenderStyle = .glass
    var ipcEdgeLifetime: TimeInterval = MissionMapView.ipcEdgeLifetime
    var ipcEdgeFullOpacityDuration: TimeInterval = MissionMapView.ipcEdgeFullOpacityDuration
    /// A tap on empty space or a line, in this view's coordinates, with
    /// the lines as drawn.
    var onBackgroundTap: ((CGPoint, [MissionMapEdgeSegment]) -> Void)?
    /// A tap on the selected line's popover. The popover sits above the
    /// background tap layer, so without this the tap would be absorbed.
    var onPopoverTap: (() -> Void)?
    var onFocusSurface: ((UUID) -> Void)?
    var onAllow: ((UUID) -> Void)?
    var onOpenApproval: ((UUID) -> Void)?
    /// A card's live drag translation, and its final one.
    var onDragChanged: ((UUID, CGSize) -> Void)?
    var onDragEnded: ((UUID, CGSize) -> Void)?

    static let coordinateSpaceName = "calyx.missionMap.content"

    /// The selected line's popover size, measured, so it can sit beside
    /// the line instead of over it.
    @State private var popoverSize: CGSize = .zero

    /// What labels keep clear of: the cards and the band headers.
    private var labelObstacles: [CGRect] {
        snapshot.cards.compactMap { frames[$0.id] } + MissionMapLayout.bandHeaderObstacles(bandOrigins: bandOrigins)
    }

    /// The lines to draw: every edge that has a route.
    var segments: [MissionMapEdgeSegment] {
        snapshot.edges.compactMap { edge in
            guard let points = routes[edge.id] else { return nil }
            return MissionMapEdgeSegment(edge: edge, points: points)
        }
    }

    var body: some View {
        let segments = segments
        ZStack(alignment: .topLeading) {
            backgroundColor
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named(Self.coordinateSpaceName)) { point in
                    onBackgroundTap?(point, segments)
                }

            MissionMapCanvasLayer(
                segments: segments,
                ipcEdgeLifetime: ipcEdgeLifetime,
                ipcEdgeFullOpacityDuration: ipcEdgeFullOpacityDuration,
                selectedEdgeID: selectedEdgeID,
                obstacles: labelObstacles,
                frozenDate: animatesEdges ? nil : now
            )

            ForEach(snapshot.groups) { group in
                if let origin = bandOrigins[group.id] {
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(
                            width: MissionMapLayout.bandHeaderObstacleWidth,
                            height: MissionMapLayout.bandHeaderHeight,
                            alignment: .leading
                        )
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                }
            }

            ForEach(snapshot.cards) { card in
                if let frame = frames[card.id] {
                    cardView(card)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }

            if let selectedEdgeID, let segment = segments.first(where: { $0.id == selectedEdgeID }) {
                MissionMapEdgePopover(edge: segment.edge, onTap: onPopoverTap)
                    .onGeometryChange(for: CGSize.self, of: \.size) { popoverSize = $0 }
                    .position(segment.labelCenter(extent: popoverSize, obstacles: labelObstacles))
            }
        }
        .coordinateSpace(.named(Self.coordinateSpaceName))
        .modifier(FlatColorScheme(style: renderStyle))
    }

    private var backgroundColor: Color {
        switch renderStyle {
        case .glass: .clear
        case .flat: MissionMapRenderStyle.flatBackground
        }
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
            onDragChanged: { onDragChanged?(card.id, $0) },
            onDragEnded: { onDragEnded?(card.id, $0) },
            renderStyle: renderStyle
        )
    }
}

/// `.flat` always draws on a dark background, so its text uses the dark
/// appearance whatever the system's is; `.glass` follows the system.
private struct FlatColorScheme: ViewModifier {
    let style: MissionMapRenderStyle

    func body(content: Content) -> some View {
        switch style {
        case .glass: content
        case .flat: content.environment(\.colorScheme, .dark)
        }
    }
}
