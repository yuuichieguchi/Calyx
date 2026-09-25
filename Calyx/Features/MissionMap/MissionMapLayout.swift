// MissionMapLayout.swift
// Calyx
//
// Places Mission Map's cards: one horizontal band per tab group, cards
// flowing left to right in window order and wrapping to a new row when
// the band runs out of width. Pure geometry, so placement is
// deterministic and testable without a view.

import CoreGraphics
import Foundation

enum MissionMapLayout {

    /// Vertical space reserved above each band's first row for the
    /// group's name.
    static let bandHeaderHeight: CGFloat = 24
    /// Extra card height per subagent row.
    static let childRowHeight: CGFloat = 20
    /// The width of the obstacle each band's header text occupies, so
    /// routed lines do not run through the group's name.
    static let bandHeaderObstacleWidth: CGFloat = 200

    /// A card's height: `baseHeight` plus one `childRowHeight` per child.
    static func cardHeight(for card: MissionMapCard, baseHeight: CGFloat) -> CGFloat {
        baseHeight + CGFloat(card.children.count) * childRowHeight
    }

    /// The top-left of each band's header, keyed by group ID -- where the
    /// view draws the group's name. Same walk as `layout`.
    static func bandOrigins(
        cards: [MissionMapCard], groups: [MissionMapGroup], in size: CGSize, cardSize: CGSize, spacing: CGFloat
    ) -> [UUID: CGPoint] {
        place(cards: cards, groups: groups, in: size, cardSize: cardSize, spacing: spacing).bandOrigins
    }

    /// The rectangle each band's header occupies (`bandHeaderObstacleWidth`
    /// x `bandHeaderHeight` at its origin), for the edge router to avoid.
    /// Sorted top to bottom, then left to right, so the same origins
    /// always give the same list.
    static func bandHeaderObstacles(bandOrigins: [UUID: CGPoint]) -> [CGRect] {
        bandOrigins.values
            .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            .map { CGRect(x: $0.x, y: $0.y, width: bandHeaderObstacleWidth, height: bandHeaderHeight) }
    }

    /// Every card's frame, keyed by card ID. Bands follow `groups`'
    /// order (a card whose group is not listed gets a band after them, in
    /// first-appearance order); within a band, cards keep their input
    /// order. `spacing` separates cards, rows, bands, and the container
    /// edge. A card wider than the container still gets a row of its own.
    static func layout(
        cards: [MissionMapCard], groups: [MissionMapGroup], in size: CGSize, cardSize: CGSize, spacing: CGFloat
    ) -> [UUID: CGRect] {
        place(cards: cards, groups: groups, in: size, cardSize: cardSize, spacing: spacing).frames
    }

    private static func place(
        cards: [MissionMapCard], groups: [MissionMapGroup], in size: CGSize, cardSize: CGSize, spacing: CGFloat
    ) -> (frames: [UUID: CGRect], bandOrigins: [UUID: CGPoint]) {
        var bandOrder = groups.map(\.id)
        for card in cards where !bandOrder.contains(card.groupID) {
            bandOrder.append(card.groupID)
        }
        let cardsByGroup = Dictionary(grouping: cards, by: \.groupID)
        let maxX = max(size.width - spacing, spacing + cardSize.width)

        var frames: [UUID: CGRect] = [:]
        var bandOrigins: [UUID: CGPoint] = [:]
        var y = spacing
        for groupID in bandOrder {
            guard let bandCards = cardsByGroup[groupID], !bandCards.isEmpty else { continue }
            bandOrigins[groupID] = CGPoint(x: spacing, y: y)
            y += bandHeaderHeight

            var x = spacing
            var rowHeight: CGFloat = 0
            for card in bandCards {
                if x > spacing, x + cardSize.width > maxX {
                    x = spacing
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                let height = cardHeight(for: card, baseHeight: cardSize.height)
                frames[card.id] = CGRect(x: x, y: y, width: cardSize.width, height: height)
                x += cardSize.width + spacing
                rowHeight = max(rowHeight, height)
            }
            y += rowHeight + spacing
        }
        return (frames, bandOrigins)
    }

    /// Where a line between two cards starts and ends: the point on each
    /// frame's border along the line joining their centers, so the line
    /// meets each card's edge instead of disappearing under it.
    static func edgeAnchors(from: CGRect, to: CGRect) -> (CGPoint, CGPoint) {
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: to.midX, y: to.midY)
        return (
            borderPoint(of: from, toward: end),
            borderPoint(of: to, toward: start)
        )
    }

    /// The point where the ray from `rect`'s center toward `target`
    /// leaves `rect`. `rect`'s center when `target` is that center.
    private static func borderPoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}
