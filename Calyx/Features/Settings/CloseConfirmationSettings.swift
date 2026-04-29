import Foundation

enum CloseConfirmationSettings {
    static let key = "confirmBeforeClosingTabsAndWindows"
    static let defaultValue = true

    static var isEnabled: Bool {
        get {
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                return false
            }
            return UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}
