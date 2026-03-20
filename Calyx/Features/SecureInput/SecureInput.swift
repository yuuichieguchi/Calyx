import Carbon
import Cocoa
import OSLog

class SecureInput: ObservableObject, @unchecked Sendable {
    static let shared = SecureInput()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
        category: String(describing: SecureInput.self)
    )

    // True to enable secure input globally (user toggle via menu)
    var global: Bool = false {
        didSet {
            apply()
        }
    }

    // Per-surface scoped tracking: ObjectIdentifier -> isFocused
    private var scoped: [ObjectIdentifier: Bool] = [:]

    // True when EnableSecureEventInput() has been called
    @Published private(set) var enabled: Bool = false

    // True if we WANT secure input enabled
    private var desired: Bool {
        global || scoped.contains(where: { $0.value })
    }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onDidResignActive(notification:)),
                          name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(onDidBecomeActive(notification:)),
                          name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        scoped.removeAll()
        global = false
        apply()
    }

    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        apply()
    }

    private func apply() {
        guard NSApp.isActive else { return }
        guard enabled != desired else { return }

        let err: OSStatus
        if enabled {
            err = DisableSecureEventInput()
        } else {
            err = EnableSecureEventInput()
        }
        if err == noErr {
            enabled = desired
            Self.logger.debug("secure input state=\(self.enabled)")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }

    @objc private func onDidBecomeActive(notification: NSNotification) {
        guard !enabled && desired else { return }
        let err = EnableSecureEventInput()
        if err == noErr {
            enabled = true
            Self.logger.debug("secure input enabled on activation")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }

    @objc private func onDidResignActive(notification: NSNotification) {
        guard enabled else { return }
        let err = DisableSecureEventInput()
        if err == noErr {
            enabled = false
            Self.logger.debug("secure input disabled on deactivation")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }
}
