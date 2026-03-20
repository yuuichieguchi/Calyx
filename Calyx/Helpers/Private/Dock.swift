import Cocoa

@_silgen_name("CoreDockGetOrientationAndPinning")
func CoreDockGetOrientationAndPinning(
    _ outOrientation: UnsafeMutablePointer<Int32>,
    _ outPinning: UnsafeMutablePointer<Int32>)

@_silgen_name("CoreDockGetAutoHideEnabled")
func CoreDockGetAutoHideEnabled() -> Bool

@_silgen_name("CoreDockSetAutoHideEnabled")
func CoreDockSetAutoHideEnabled(_ flag: Bool)

enum DockOrientation: Int {
    case top = 1
    case bottom = 2
    case left = 3
    case right = 4
}

class Dock {
    static var orientation: DockOrientation? {
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        CoreDockGetOrientationAndPinning(&orientation, &pinning)
        return .init(rawValue: Int(orientation))
    }

    static var autoHideEnabled: Bool {
        get { CoreDockGetAutoHideEnabled() }
        set { CoreDockSetAutoHideEnabled(newValue) }
    }
}
