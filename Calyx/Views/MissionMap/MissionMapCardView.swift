// MissionMapCardView.swift
// Calyx
//
// One pane on Mission Map: agent CLI, pane title, cwd, state, current
// tool, subagent rows, unread count, Git badge, and the inline approval
// buttons. A tap focuses the pane; a drag moves the card.

import SwiftUI

struct MissionMapCardView: View {
    let card: MissionMapCard
    var onFocus: (() -> Void)?
    var onAllow: ((UUID) -> Void)?
    var onOpenApproval: ((UUID) -> Void)?
    /// Live drag translation, in global coordinates.
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?
    var renderStyle: MissionMapRenderStyle = .glass

    static let cornerRadius: CGFloat = 14
    /// Opacity of the content of a pane no agent has reported from.
    private static let dimmedOpacity = 0.55

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(card.paneTitle)
                .font(.subheadline)
                .lineLimit(1)
            Text(card.cwdLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let git = card.git {
                gitLine(git)
            }
            if let toolLine = card.toolLine {
                Text(toolLine)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(card.children) { child in
                childRow(child)
            }
            Spacer(minLength: 0)
            if let approval = card.approval {
                approvalRow(approval)
            }
        }
        .opacity(card.state == nil ? Self.dimmedOpacity : 1)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(MissionMapCardSurface(style: renderStyle, cornerRadius: Self.cornerRadius))
        .overlay {
            if card.approval != nil {
                MissionMapApprovalPulse(cornerRadius: Self.cornerRadius)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture { onFocus?() }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDragChanged?($0.translation) }
                .onEnded { onDragEnded?($0.translation) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MissionMap.card(card.id))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onFocus?() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let state = card.state {
                Circle()
                    .fill(AgentRowDisplay.dotColor(for: state))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(AgentRowDisplay.stateLabel(for: state))
            } else {
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(card.kindLabel ?? "Terminal")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if card.unreadCount > 0 {
                UnreadCountBadge(count: card.unreadCount)
            }
        }
    }

    private func gitLine(_ git: MissionMapGitBadge) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(git.branch ?? git.shortHash ?? "No commits")
                .lineLimit(1)
            if git.changedFileCount > 0 {
                Text("\u{00B1}\(git.changedFileCount)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func childRow(_ child: MissionMapChildCard) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AgentRowDisplay.dotColor(for: child.state))
                .frame(width: 6, height: 6)
            Text(child.agentType ?? "Subagent")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(child.toolLine ?? AgentRowDisplay.stateLabel(for: child.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 8)
        .frame(height: MissionMapLayout.childRowHeight - 4, alignment: .leading)
    }

    private func approvalRow(_ approval: MissionMapApproval) -> some View {
        HStack(spacing: 6) {
            Text("Waiting for approval")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer(minLength: 4)
            if case .allowable(let id) = approval {
                Button("Allow") { onAllow?(id) }
                    .controlSize(.small)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier(AccessibilityID.MissionMap.allowButton(card.id))
            }
            Button("Open") { onOpenApproval?(approval.requestID) }
                .controlSize(.small)
                .buttonStyle(.glass)
                .accessibilityIdentifier(AccessibilityID.MissionMap.openButton(card.id))
        }
    }
}

/// The pulsing border of a card whose pane is waiting on an approval.
/// Static under Reduce Motion.
private struct MissionMapApprovalPulse: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per full pulse.
    private static let period: TimeInterval = 1.4

    var body: some View {
        Group {
            if reduceMotion {
                border(intensity: 0.8)
            } else {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    border(intensity: 0.45 + 0.45 * (0.5 + 0.5 * sin(phase * 2 * .pi)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func border(intensity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.orange.opacity(intensity), lineWidth: 2)
    }
}

/// A card's surface: Liquid Glass on the live map, or a solid rounded
/// rect for `.flat` (static rendering, where glass has nothing behind it
/// to refract and renders nearly invisible).
private struct MissionMapCardSurface: ViewModifier {
    let style: MissionMapRenderStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        case .flat:
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(shape.fill(MissionMapRenderStyle.flatCardFill))
                .overlay(shape.strokeBorder(MissionMapRenderStyle.flatCardBorder, lineWidth: 1))
        }
    }
}
