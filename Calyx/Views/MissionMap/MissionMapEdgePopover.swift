// MissionMapEdgePopover.swift
// Calyx
//
// The small bubble a clicked Mission Map line opens: the IPC line's
// messages (newest first, each with how long ago it was sent, once there
// is more than one), or the conflicting file's full path.

import SwiftUI

struct MissionMapEdgePopover: View {
    let edge: MissionMapEdge
    /// A tap anywhere on the bubble. Mission Map clears the selection
    /// with it, so the bubble dismisses instead of swallowing the tap.
    var onTap: (() -> Void)?
    /// `nil` keeps the relative times current on a one-second timeline
    /// (the live map); a date reads them once, as of that instant (static
    /// rendering) -- the same convention as `MissionMapCanvasLayer`.
    var frozenDate: Date?

    /// Text lines per message row in a multi-message list, so one long
    /// message does not grow the bubble without bound. (The row count
    /// itself is capped at `MissionMapSnapshot.maxShownIPCMessages`.)
    private static let listedMessageLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch edge.kind {
            case .ipc(let messages):
                if messages.count == 1, let event = messages.first {
                    Text(event.isBroadcast ? "Broadcast" : "Message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(event.content)
                        .font(.callout)
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    Text("\(messages.count) messages")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let frozenDate {
                        messageList(messages, now: frozenDate)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            messageList(messages, now: timeline.date)
                        }
                    }
                }
            case .conflict(let file, let fullPath):
                Text("Both panes edited \(file)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(fullPath)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { onTap?() }
    }

    /// The newest `MissionMapSnapshot.maxShownIPCMessages` of `messages`
    /// (newest first), each as a relative sent time over its content,
    /// then "+N more" for the rest.
    private func messageList(_ messages: [IPCMessageEvent], now: Date) -> some View {
        let shown = messages.prefix(MissionMapSnapshot.maxShownIPCMessages)
        let hiddenCount = messages.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { message in
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        (message.isBroadcast ? "Broadcast, " : "")
                            + AgentRowDisplay.lastEventLabel(lastEventAt: message.sentAt, now: now)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text(message.content)
                        .font(.callout)
                        .lineLimit(Self.listedMessageLineLimit)
                        .textSelection(.enabled)
                }
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
