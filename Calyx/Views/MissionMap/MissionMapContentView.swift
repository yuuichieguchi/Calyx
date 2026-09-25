// MissionMapContentView.swift
// Calyx
//
// Mission Map's drawing, from given data only: band headers, the routed
// lines, the cards, and -- for static rendering only -- the selected
// line's popover (the live map draws the popover outside its SwiftUI
// tree, in `MissionMapPopoverHost`; this view only reports where it
// goes). It reads no
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
    /// Whether this view draws the selected line's popover over itself:
    /// static rendering (the `.flat` fixture). The live map leaves it off
    /// and draws the popover in `MissionMapPopoverHost` instead, placed
    /// from `onPopoverPlacementChange`.
    var popoverOverlayEnabled = false
    var renderStyle: MissionMapRenderStyle = .glass
    var ipcEdgeLifetime: TimeInterval = MissionMapView.ipcEdgeLifetime
    var ipcEdgeFullOpacityDuration: TimeInterval = MissionMapView.ipcEdgeFullOpacityDuration
    /// A tap on empty space or a line, in this view's coordinates, with
    /// the lines as drawn.
    var onBackgroundTap: ((CGPoint, [MissionMapEdgeSegment]) -> Void)?
    /// A tap on the selected line's popover, when this view draws it
    /// (`popoverOverlayEnabled`).
    var onPopoverTap: (() -> Void)?
    /// Where the selected line's popover goes, in this view's
    /// coordinates, each time that changes; `nil` while no line is
    /// selected (or its popover is not measured yet). Only reported while
    /// `popoverOverlayEnabled` is off.
    var onPopoverPlacementChange: ((MissionMapPopoverPlacementInfo?) -> Void)?
    var onFocusSurface: ((UUID) -> Void)?
    var onAllow: ((UUID) -> Void)?
    var onOpenApproval: ((UUID) -> Void)?
    /// A card's live drag translation, and its final one.
    var onDragChanged: ((UUID, CGSize) -> Void)?
    var onDragEnded: ((UUID, CGSize) -> Void)?

    static let coordinateSpaceName = "calyx.missionMap.content"

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

        }
        .coordinateSpace(.named(Self.coordinateSpaceName))
        .overlay(alignment: .topLeading) {
            if popoverOverlayEnabled {
                popoverLayer(mode: .draw(onTap: onPopoverTap))
            } else if let onPopoverPlacementChange {
                popoverLayer(mode: .report(onPopoverPlacementChange))
            }
        }
        .modifier(FlatColorScheme(style: renderStyle))
    }

    /// The selected line's popover layer, laid over this view at
    /// `.topLeading` with the same size.
    ///
    /// Never part of the cards' `ZStack` in `body`, and on the live map
    /// never drawn in this SwiftUI tree at all: the cards and the popover
    /// are all `.glassEffect` shapes inside the window's root
    /// `GlassEffectContainer`, whose glass compositing does not follow
    /// `ZStack` order -- the popover drew behind the cards, and a nested
    /// `GlassEffectContainer` did not change that (verified in the
    /// running app). So the live map only measures and places the
    /// popover here (`.report`), and `MissionMapPopoverHost` draws it in
    /// its own AppKit view above the window's main hosting view.
    private func popoverLayer(mode: MissionMapPopoverLayer.Mode) -> some View {
        let segment = selectedEdgeID.flatMap { id in segments.first(where: { $0.id == id }) }
        return MissionMapPopoverLayer(
            segment: segment,
            obstacles: labelObstacles,
            frozenDate: animatesEdges ? nil : now,
            renderStyle: renderStyle,
            mode: mode
        )
        // A new identity per selected line, so its measured size starts
        // over and the first placement reported for a newly selected line
        // waits for that line's own popover to be measured.
        .id(selectedEdgeID)
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

/// The selected line's popover, placed by `MissionMapPopoverPlacement`
/// around the line's anchor inside this layer's own bounds, keeping
/// clear of `obstacles` where there is room and emphasized where there
/// is not. Its own view (not a computed part of `MissionMapContentView`)
/// so the measured size is `@State` of the view actually on screen.
private struct MissionMapPopoverLayer: View {
    enum Mode {
        /// Draw the popover here (static rendering).
        case draw(onTap: (() -> Void)?)
        /// Measure the popover without drawing it, and report where it
        /// goes (the live map, which draws it in `MissionMapPopoverHost`).
        case report((MissionMapPopoverPlacementInfo?) -> Void)
    }

    let segment: MissionMapEdgeSegment?
    let obstacles: [CGRect]
    let frozenDate: Date?
    let renderStyle: MissionMapRenderStyle
    let mode: Mode

    /// The popover's size, measured, so it can be placed beside the line
    /// instead of over it.
    @State private var popoverSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let placement = placement(in: CGRect(origin: .zero, size: proxy.size))
            switch mode {
            case .draw(let onTap):
                if let segment, let placement {
                    popover(segment, onTap: onTap, emphasized: placement.emphasized)
                        .position(x: placement.rect.midX, y: placement.rect.midY)
                }
            case .report(let report):
                ZStack(alignment: .topLeading) {
                    if let segment {
                        // Measured only; `MissionMapPopoverHost` draws the
                        // one on screen.
                        popover(segment, onTap: nil, emphasized: false)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)
                // Not reported until measured: a zero-size placement is
                // not where the popover goes.
                .onChange(of: popoverSize == .zero ? nil : placement, initial: true) { _, new in report(new) }
            }
        }
    }

    /// `nil` without a selected line.
    private func placement(in bounds: CGRect) -> MissionMapPopoverPlacementInfo? {
        guard let segment else { return nil }
        let rect = MissionMapPopoverPlacement.place(
            extent: popoverSize, anchor: segment.popoverAnchor, obstacles: obstacles, bounds: bounds
        )
        return MissionMapPopoverPlacementInfo(
            edge: segment.edge,
            rect: rect,
            emphasized: MissionMapPopoverPlacement.score(rect, obstacles: obstacles) > 0
        )
    }

    private func popover(_ segment: MissionMapEdgeSegment, onTap: (() -> Void)?, emphasized: Bool) -> some View {
        MissionMapEdgePopover(
            edge: segment.edge,
            onTap: onTap,
            frozenDate: frozenDate,
            emphasized: emphasized,
            renderStyle: renderStyle
        )
        .onGeometryChange(for: CGSize.self, of: \.size) { popoverSize = $0 }
    }
}
