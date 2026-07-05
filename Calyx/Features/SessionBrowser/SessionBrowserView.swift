// SessionBrowserView.swift
// Calyx
//
// SwiftUI content view for `SessionBrowserWindowController`: lists
// every session `SessionBrowserModel.rows` reports, refreshed on a
// one-second poll (`.task`'s loop, cancelled automatically once the
// window closes and the view disappears). Row layout mirrors
// `AgentStatusView`'s row shape (state dot, name, secondary detail
// line, relative time via a `TimelineView`).

import SwiftUI

struct SessionBrowserView: View {
    @Bindable var model: SessionBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.remoteHostCandidates.isEmpty {
                remoteHostsSection
            }
            Group {
                if model.rows.isEmpty {
                    emptyState
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(model.rows) { row in
                                    SessionBrowserRowView(row: row, now: context.date, model: model)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Compact "New Remote Session..." picker (SessionBrowserModel
    /// .remoteHostCandidates): one row per candidate host, mirroring
    /// SessionBrowserRowView's own dot + name + trailing-actions shape.
    /// Hidden entirely when there are no candidates.
    private var remoteHostsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote Hosts")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(model.remoteHostCandidates, id: \.self) { host in
                RemoteHostRowView(host: host, model: model)
            }
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No sessions yet.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Persistent sessions you create will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row per `SessionBrowserModel.remoteHostCandidates` entry. Mirrors
/// `SessionBrowserRowView`'s dot + name + trailing-actions layout: a
/// neutral (no session state to represent yet) dot keeps the two
/// sections' columns aligned, "Attach" spawns a new session against the
/// host (`SessionBrowserModel.attachToRemoteHost(_:)`), "Install"
/// deploys the daemon to it first (`SessionBrowserModel.installRemote
/// (host:)`).
private struct RemoteHostRowView: View {
    let host: String
    let model: SessionBrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)

            Text(host)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Spacer()

            Button("Attach") { model.attachToRemoteHost(host) }
                .buttonStyle(.bordered)
            Button("Install") { Task { await model.installRemote(host: host) } }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SessionBrowserRowView: View {
    let row: SessionBrowserRow
    let now: Date
    let model: SessionBrowserModel

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    private var isRunning: Bool {
        row.info.state == .running
    }

    private var stateLabel: String {
        switch row.info.state {
        case .running: return "Running"
        case .exited(let code): return "Exited (\(code))"
        }
    }

    private var dotColor: Color {
        guard isRunning else { return .gray }
        return row.isOrphan ? .orange : .green
    }

    private var createdAt: Date {
        Date(timeIntervalSince1970: Double(row.info.createdAtMs) / 1000)
    }

    private var detailLine: String {
        var parts = [stateLabel, "\(row.info.attachedClients) client(s)"]
        parts.append(Self.relativeDateFormatter.localizedString(for: createdAt, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.info.name ?? row.info.id)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if row.isOrphan {
                        Text("Orphaned")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                if let cwd = row.info.cwd {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isRunning {
                Button("Attach") { model.attach(row) }
                    .buttonStyle(.bordered)
                Button("Kill") { Task { await model.kill(row) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
