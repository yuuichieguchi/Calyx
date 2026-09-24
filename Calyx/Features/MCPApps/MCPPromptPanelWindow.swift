//
//  MCPPromptPanelWindow.swift
//  Calyx
//
//  The floating panel that shows an upstream MCP server's elicitation or
//  sign-in request, modeled on `ApprovalPanelWindow`: a borderless,
//  non-activating panel that can take key for its text fields and never
//  becomes main. When the calling pane is known the panel is a child
//  window of that pane's window, placed at its top center; otherwise it
//  floats app-wide at the top center of the main screen. Nothing here
//  runs a modal loop.
//

import AppKit
import SwiftUI

final class MCPPromptPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static let width: CGFloat = 420

    private let hostingView: NSView

    init<Content: View>(rootView: Content) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        self.hostingView = hostingView
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        setAccessibilitySubrole(.floatingWindow)
        contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Shows the panel at the top center of `parent` when given, centered
    /// on the screen otherwise.
    func show(over parent: NSWindow?) {
        setContentSize(NSSize(width: Self.width, height: hostingView.fittingSize.height))
        if let parent {
            let area = parent.frame
            setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.maxY - frame.height - 48))
            parent.addChildWindow(self, ordered: .above)
        } else {
            center()
        }
        orderFrontRegardless()
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// Cmd+W does not dismiss a pending request; its buttons do.
    override func calyxPerformClose(_ sender: Any?) {}
}

/// The card look shared by the MCP prompt panels.
struct MCPPromptCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(width: MCPPromptPanelWindow.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
