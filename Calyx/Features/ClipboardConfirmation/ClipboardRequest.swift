import GhosttyKit

enum ClipboardRequest {
    case paste
    case osc52Read
    case osc52Write

    static func from(_ request: ghostty_clipboard_request_e) -> ClipboardRequest? {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            return .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            return .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            return .osc52Write
        default:
            return nil
        }
    }

    var descriptionText: String {
        switch self {
        case .paste:
            return "The terminal is requesting to paste the following content. This may be dangerous if the content contains commands that could be executed."
        case .osc52Read:
            return "An application in the terminal is requesting to read your clipboard contents."
        case .osc52Write:
            return "An application in the terminal is requesting to write the following content to your clipboard."
        }
    }

    var cancelButtonTitle: String {
        switch self {
        case .paste: return "Cancel"
        case .osc52Read, .osc52Write: return "Deny"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .paste: return "Paste"
        case .osc52Read, .osc52Write: return "Allow"
        }
    }
}
