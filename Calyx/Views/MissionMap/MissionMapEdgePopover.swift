// MissionMapEdgePopover.swift
// Calyx
//
// The small bubble a clicked Mission Map line opens: the IPC line's
// messages (newest first, each with how long ago it was sent, once there
// is more than one), or the conflicting file's full path.

import AppKit
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
    /// Whether the bubble had to be placed over a card or band header
    /// (`MissionMapPopoverPlacement.score > 0`). Plain glass would let
    /// the covered text show through it, so an emphasized bubble's glass
    /// is strongly tinted with the theme's chrome color instead.
    var emphasized = false
    var renderStyle: MissionMapRenderStyle = .glass
    /// Whether the message text can be selected. Off where selecting
    /// would pull first responder away from the map's key catcher
    /// (`MissionMapPopoverHost`).
    var selectableText = true

    @AppStorage("terminalGlassOpacity") private var glassOpacity = MissionMapChromeModifier.defaultGlassOpacity
    @AppStorage("themeColorPreset") private var themePreset = MissionMapChromeModifier.defaultThemePreset
    @AppStorage("themeColorCustomHex") private var customHex = MissionMapChromeModifier.defaultCustomHex
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private static let cornerRadius: CGFloat = 10
    /// The emphasized glass's tint opacity: high enough that text under
    /// the bubble no longer reads through it, while it stays glass.
    private static let emphasizedTintOpacity = 0.92

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
                        .modifier(PopoverTextSelection(enabled: selectableText))
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
                    .modifier(PopoverTextSelection(enabled: selectableText))
            }
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PopoverSurface(style: renderStyle, glass: glass, cornerRadius: Self.cornerRadius))
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MissionMap.popover)
    }

    private var glass: Glass {
        guard emphasized else { return .regular }
        let tint = MissionMapChromeModifier.chromeTint(
            themePreset: themePreset, customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground, glassOpacity: glassOpacity
        )
        return .regular.tint(Color(nsColor: tint).opacity(Self.emphasizedTintOpacity))
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
                        .modifier(PopoverTextSelection(enabled: selectableText))
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

/// The bubble's surface: `glass` on the live map, or the cards' solid
/// rounded rect for `.flat` (static rendering, where glass renders
/// nearly invisible).
private struct PopoverSurface: ViewModifier {
    let style: MissionMapRenderStyle
    let glass: Glass
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        case .flat:
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(shape.fill(MissionMapRenderStyle.flatCardFill))
                .overlay(shape.strokeBorder(MissionMapRenderStyle.flatCardBorder, lineWidth: 1))
        }
    }
}

/// `.textSelection(.enabled)` or `.disabled`; the two are distinct types.
private struct PopoverTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
