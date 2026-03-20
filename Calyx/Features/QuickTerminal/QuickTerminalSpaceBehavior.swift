import Cocoa

enum QuickTerminalSpaceBehavior {
    case remain
    case move

    var collectionBehavior: NSWindow.CollectionBehavior {
        let commonBehavior: [NSWindow.CollectionBehavior] = [
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        switch self {
        case .move:
            return NSWindow.CollectionBehavior([.canJoinAllSpaces] + commonBehavior)
        case .remain:
            return NSWindow.CollectionBehavior([.moveToActiveSpace] + commonBehavior)
        }
    }
}
