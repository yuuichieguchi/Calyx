import Cocoa

enum QuickTerminalScreen {
    case main
    case mouse
    case menuBar

    var screen: NSScreen? {
        switch self {
        case .main:
            return NSScreen.main
        case .mouse:
            let mouseLoc = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) })
        case .menuBar:
            return NSScreen.screens.first
        }
    }
}
