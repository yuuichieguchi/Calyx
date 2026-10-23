import AppKit
import GhosttyKit

enum GhosttyColorScheme {
    static func scheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

@MainActor
protocol GhosttyColorSchemeReceiving: AnyObject {
    func setColorScheme(_ scheme: ghostty_color_scheme_e)
}

enum GhosttyColorSchemeBroadcaster {
    @MainActor
    static func broadcast(
        _ scheme: ghostty_color_scheme_e,
        setAppScheme: (ghostty_color_scheme_e) -> Void,
        receivers: [any GhosttyColorSchemeReceiving]
    ) {
        setAppScheme(scheme)
        for receiver in receivers {
            receiver.setColorScheme(scheme)
        }
    }
}

enum GhosttyReloadConfigRoute: Equatable {
    case reapplyApp
    case reloadAppFromDisk
    case reapplySurface
    case reloadSurfaceFromDisk

    static func route(targetTag: ghostty_target_tag_e, soft: Bool) -> Self {
        switch (targetTag == GHOSTTY_TARGET_SURFACE, soft) {
        case (false, true): .reapplyApp
        case (false, false): .reloadAppFromDisk
        case (true, true): .reapplySurface
        case (true, false): .reloadSurfaceFromDisk
        }
    }
}
