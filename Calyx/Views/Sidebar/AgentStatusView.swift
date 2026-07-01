// AgentStatusView.swift
// Calyx
//
// Sidebar view that displays connected AI agent peers and their activity states.

import SwiftUI

struct AgentStatusView: View {
    @State private var entries: [AgentStatusEntry] = []
    @State private var isIPCRunning: Bool = false
    @State private var refreshTask: Task<Void, Never>?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !isIPCRunning {
                disabledPlaceholder
            } else if entries.isEmpty {
                emptyPlaceholder
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(entries) { entry in
                            AgentRowView(entry: entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
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

    // MARK: - Data Refresh

    private func refresh() {
        // Cancel any in-flight refresh so a slow prior snapshot cannot
        // overwrite a fresher one, and so a Task started right before
        // `.onDisappear` cannot write into `@State` after the view is gone.
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            // Read running state BEFORE awaiting so a stop() during the actor
            // hop does not desync `isIPCRunning` from `entries` (an old-server
            // stop() → new-server start() sequence otherwise briefly shows
            // "no agents" with running=true).
            let running = CalyxMCPServer.shared.isRunning
            let snapshot = await CalyxMCPServer.shared.agentSnapshot()
            if Task.isCancelled { return }
            self.isIPCRunning = running
            self.entries = snapshot
        }
    }
}

// MARK: - Agent Row View

private struct AgentRowView: View {
    let entry: AgentStatusEntry

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    /// Self entries render as blue unconditionally. The Calyx app peer's
    /// `lastSeen` is bumped every time an agent broadcasts or messages it,
    /// so in normal operation `state` stays `.active`; even if the app peer
    /// went idle/stale between broadcasts, the "this is me" affordance is
    /// more useful than surfacing the app's own activity level.
    private var dotColor: Color {
        if entry.isSelf { return .blue }
        switch entry.state {
        case .active: return .green
        case .idle:   return .yellow
        case .stale:  return Color(white: 0.5)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // State dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            // Name + role
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(entry.role)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Right side: inbox badge + relative time
            VStack(alignment: .trailing, spacing: 2) {
                if entry.inboxCount > 0 {
                    Text(entry.inboxCount > 99 ? "99+" : "\(entry.inboxCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.red))
                }
                Text(Self.relativeDateFormatter.localizedString(for: entry.lastSeen, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
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
    }
}
