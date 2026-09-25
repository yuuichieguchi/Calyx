// MissionMapEdgePopover.swift
// Calyx
//
// The small bubble a clicked Mission Map line opens: the IPC message's
// text, or the conflicting file's full path.

import SwiftUI

struct MissionMapEdgePopover: View {
    let edge: MissionMapEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch edge.kind {
            case .ipc(let event):
                Text(event.isBroadcast ? "Broadcast" : "Message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(event.content)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
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
    }
}
