import Cocoa

enum QuickTerminalPosition: String {
    case top
    case bottom
    case left
    case right
    case center

    func setLoaded(_ window: NSWindow, size: QuickTerminalSize) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(.init(
            origin: window.frame.origin,
            size: size.calculate(position: self, screenDimensions: screen.visibleFrame.size)
        ), display: false)
    }

    func setInitial(in window: NSWindow, on screen: NSScreen, terminalSize: QuickTerminalSize, closedFrame: NSRect? = nil) {
        window.alphaValue = 0
        window.setFrame(.init(
            origin: initialOrigin(for: window, on: screen),
            size: closedFrame?.size ?? configuredFrameSize(on: screen, terminalSize: terminalSize)
        ), display: false)
    }

    func setFinal(in window: NSWindow, on screen: NSScreen, terminalSize: QuickTerminalSize, closedFrame: NSRect? = nil) {
        window.alphaValue = 1
        window.setFrame(.init(
            origin: finalOrigin(for: window, on: screen),
            size: closedFrame?.size ?? configuredFrameSize(on: screen, terminalSize: terminalSize)
        ), display: true)
    }

    func configuredFrameSize(on screen: NSScreen, terminalSize: QuickTerminalSize) -> NSSize {
        let dimensions = terminalSize.calculate(position: self, screenDimensions: screen.visibleFrame.size)
        return NSSize(width: dimensions.width, height: dimensions.height)
    }

    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch self {
        case .top:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: screen.visibleFrame.maxY)
        case .bottom:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: -window.frame.height)
        case .left:
            return .init(
                x: screen.visibleFrame.minX - window.frame.width,
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
        case .right:
            return .init(
                x: screen.visibleFrame.maxX,
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
        case .center:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: screen.visibleFrame.height - window.frame.height)
        }
    }

    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch self {
        case .top:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: screen.visibleFrame.maxY - window.frame.height)
        case .bottom:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: screen.visibleFrame.minY)
        case .left:
            return .init(
                x: screen.visibleFrame.minX,
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
        case .right:
            return .init(
                x: screen.visibleFrame.maxX - window.frame.width,
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
        case .center:
            return .init(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
        }
    }

    func conflictsWithDock(on screen: NSScreen) -> Bool {
        guard screen.hasDock else { return false }
        guard let orientation = Dock.orientation else { return false }
        return switch orientation {
        case .top: self == .top || self == .left || self == .right
        case .bottom: self == .bottom || self == .left || self == .right
        case .left: self == .top || self == .bottom
        case .right: self == .top || self == .bottom
        }
    }
}

extension NSScreen {
    var hasDock: Bool {
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if dockAutohide { return false }
        }
        let diff = frame.height - visibleFrame.height - (frame.height - visibleFrame.maxY)
        return diff > 10
    }
}
