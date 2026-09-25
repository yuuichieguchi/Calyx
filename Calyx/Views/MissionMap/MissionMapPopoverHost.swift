// MissionMapPopoverHost.swift
// Calyx
//
// Draws the selected Mission Map line's popover in its own AppKit view,
// a sibling ABOVE the window's main `NSHostingView` in the window's
// content view, instead of inside the map's SwiftUI tree.
//
// Why not SwiftUI: the cards and the popover are all Liquid Glass
// (`.glassEffect`) inside the main hosting view's root
// `GlassEffectContainer`, and that container composites its glass
// without regard to `ZStack` order -- the popover drew BEHIND the cards,
// in the cards' `ZStack` and in a nested `GlassEffectContainer` alike
// (both verified in the running app). AppKit draws sibling subviews in
// `subviews` order, so a separate hosting view added above the main one
// draws its glass over everything the main one draws.
//
// Owned by `CalyxWindowController`: `MissionMapView` reports where the
// popover goes (`MissionMapPopoverPlacementInfo`, in the main hosting
// view's coordinates) and the controller shows, moves or hides it here.
// The view covers only the bubble, so clicks elsewhere still reach the
// map underneath.

import AppKit
import SwiftUI

@MainActor
final class MissionMapPopoverHost {
    private var hostingView: PopoverHostingView?

    /// The view the popover is drawn in, once shown at least once.
    var view: NSView? { hostingView }

    /// Whether the popover is currently in a view hierarchy.
    var isShown: Bool { hostingView?.superview != nil }

    /// Shows (or moves/updates) the popover at `placement.rect`, given in
    /// `mainHostingView`'s coordinates, as a subview of `container` (the
    /// window's content view, `mainHostingView`'s superview) directly
    /// above `mainHostingView`. `onTap` runs on a tap on the bubble.
    func show(
        _ placement: MissionMapPopoverPlacementInfo,
        in container: NSView,
        above mainHostingView: NSView,
        onTap: @escaping () -> Void
    ) {
        let content = MissionMapPopoverHostContent(
            edge: placement.edge, emphasized: placement.emphasized, onTap: onTap
        )
        let host: PopoverHostingView
        if let hostingView {
            hostingView.rootView = content
            host = hostingView
        } else {
            host = PopoverHostingView(rootView: content)
            // Sized by `frame` alone, to exactly the placed rect.
            host.sizingOptions = []
            hostingView = host
        }
        if host.superview !== container {
            container.addSubview(host, positioned: .above, relativeTo: mainHostingView)
        } else {
            restack(above: mainHostingView)
        }
        host.frame = container.convert(placement.rect, from: mainHostingView)
    }

    /// Moves the shown popover directly above `mainHostingView` in their
    /// shared superview, if it is not there already -- e.g. after the
    /// window controller recreated the main hosting view, which adds the
    /// new one on top.
    func restack(above mainHostingView: NSView) {
        guard let host = hostingView, let container = host.superview else { return }
        let subviews = container.subviews
        guard let mainIndex = subviews.firstIndex(of: mainHostingView),
              subviews.firstIndex(of: host) != mainIndex + 1 else { return }
        container.addSubview(host, positioned: .above, relativeTo: mainHostingView)
    }

    /// Removes the popover (deselect, map dismissed, window closing).
    func hide() {
        hostingView?.removeFromSuperview()
    }
}

/// Never takes first responder: the map's key catcher must keep it so
/// Escape still dismisses the map after a click on the popover.
private final class PopoverHostingView: NSHostingView<MissionMapPopoverHostContent> {
    override var acceptsFirstResponder: Bool { false }
}

/// The hosted root: `MissionMapEdgePopover` with the same text color
/// scheme and foreground the map's own chrome gives it
/// (`MissionMapChromeModifier`), which this separate hosting view does
/// not inherit.
struct MissionMapPopoverHostContent: View {
    let edge: MissionMapEdge
    let emphasized: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = MissionMapChromeModifier.defaultGlassOpacity
    @AppStorage("themeColorPreset") private var themePreset = MissionMapChromeModifier.defaultThemePreset
    @AppStorage("themeColorCustomHex") private var customHex = MissionMapChromeModifier.defaultCustomHex
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    var body: some View {
        // No text selection: selecting would try to move first responder
        // into this view, away from the map's key catcher.
        let popover = MissionMapEdgePopover(
            edge: edge, onTap: onTap, emphasized: emphasized, selectableText: false
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if reduceTransparency {
            popover
        } else {
            let tint = MissionMapChromeModifier.chromeTint(
                themePreset: themePreset, customHex: customHex,
                ghosttyBackground: ghosttyProvider.ghosttyBackground, glassOpacity: glassOpacity
            )
            popover
                .environment(\.colorScheme, MissionMapChromeModifier.chromeScheme(for: tint))
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}
