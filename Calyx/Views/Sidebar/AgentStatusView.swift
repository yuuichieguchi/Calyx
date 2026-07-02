// AgentStatusView.swift
// Calyx
//
// Sidebar view that displays AI agent panes and their lifecycle state,
// sourced live from `AgentRegistry.shared`.

import SwiftUI

struct AgentStatusView: View {
    var body: some View {
        Group {
            // Observes AgentRegistry.isServerRunning rather than
            // CalyxMCPServer.isRunning: CalyxMCPServer is a plain
            // @MainActor class, not @Observable, so a view reading its
            // isRunning directly would never get a re-render signal when
            // the server starts/stops.
            if !AgentRegistry.shared.isServerRunning {
                disabledPlaceholder
            } else {
                let entries = AgentRegistry.shared.sortedEntries
                if entries.isEmpty {
                    emptyPlaceholder
                } else {
                    // TimelineView re-renders every second so each row's
                    // relative "time ago" label stays live; it also stops
                    // firing automatically while the sidebar isn't visible.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(entries) { entry in
                                    AgentRowView(entry: entry, now: context.date)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Placeholders

    private var disabledPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("AI Agent IPC is disabled")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Command Palette → Enable AI Agent IPC")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No agents connected yet.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent Row View

private struct AgentRowView: View {
    let entry: AgentEntry
    /// The "current" instant used to render `lastEventAt`'s relative
    /// label, supplied by the enclosing `TimelineView` so it stays live
    /// without this row managing its own timer.
    let now: Date

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    private var dotColor: Color {
        switch entry.state {
        case .blocked: return .red
        case .working: return .yellow
        case .done:    return .blue
        case .idle:    return .green
        }
    }

    /// The row's primary label: the pane's working directory basename, or
    /// "Claude Code" when no `cwd` has been reported yet. Reuses
    /// `AgentRegistry.basename` rather than re-deriving it, so the
    /// basename logic exists in exactly one place.
    private var displayName: String {
        let basename = AgentRegistry.basename(entry.cwd)
        return basename.isEmpty ? "Claude Code" : basename
    }

    var body: some View {
        HStack(spacing: 8) {
            // State dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            // Name + agent kind
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(AgentEntry.displayName(forKind: entry.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(Self.relativeDateFormatter.localizedString(for: entry.lastEventAt, relativeTo: now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(reduceTransparency ? 0.08 : 0.05))
            }
        }
        .onAssumeInsideHover($isHovering)
        .opacity(controlActiveState == .key ? 1.0 : 0.5)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentRow(id: entry.id))
        .onTapGesture {
            NotificationCenter.default.post(
                name: .calyxFocusSurface,
                object: nil,
                userInfo: ["surfaceID": entry.surfaceID]
            )
        }
    }
}
