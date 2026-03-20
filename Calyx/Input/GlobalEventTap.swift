// GlobalEventTap.swift
// Calyx
//
// Manages a CGEvent tap to monitor global key events for global keybindings
// (e.g., quick terminal toggle). Requires Accessibility permissions.

import AppKit
import CoreGraphics
import Carbon
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GlobalEventTap")

/// Singleton that installs a session-level CGEvent tap to intercept global key events
/// and forward them to ghostty for global keybind matching.
class GlobalEventTap: @unchecked Sendable {
    nonisolated(unsafe) static let shared = GlobalEventTap()

    /// The CGEvent tap mach port. Non-nil when the tap is active.
    /// Accessible from the C callback for re-enabling on timeout.
    fileprivate var eventTap: CFMachPort?

    /// Cached ghostty app handle for use from the CGEvent callback thread.
    nonisolated(unsafe) fileprivate var ghosttyApp: ghostty_app_t?

    /// Timer used to retry enabling when Accessibility permissions are not yet granted.
    private var enableTimer: Timer?

    private init() {}

    deinit {
        disable()
    }

    /// Enable the global event tap. Safe to call if already enabled.
    /// If enabling fails due to missing Accessibility permissions, prompts the user
    /// and starts a retry timer until permissions are granted.
    /// - Parameter app: The ghostty app handle to use for key event processing.
    func enable(app: ghostty_app_t) {
        self.ghosttyApp = app

        if eventTap != nil {
            // Already enabled.
            logger.debug("Global event tap already enabled, skipping")
            return
        }

        // Cancel any pending retry timer.
        if let enableTimer {
            enableTimer.invalidate()
        }

        // Prompt for Accessibility permissions if not already granted.
        // CGEvent.tapCreate silently returns nil without prompting, so we must
        // explicitly trigger the system dialog via AXIsProcessTrustedWithOptions.
        // Use the string literal to avoid Swift 6 concurrency issues with the
        // global kAXTrustedCheckOptionPrompt variable.
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        )
        logger.info("Accessibility permission status: trusted=\(trusted)")

        // Try to enable immediately.
        if tryEnable() {
            return
        }

        // Failed (likely missing Accessibility permissions). Retry every 2 seconds.
        logger.info("Global event tap creation failed, retrying periodically until Accessibility permission is granted")
        enableTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            _ = self?.tryEnable()
        }
    }

    /// Disable the global event tap. Safe to call if already disabled.
    func disable() {
        if let enableTimer {
            enableTimer.invalidate()
            self.enableTimer = nil
        }

        if let eventTap {
            logger.debug("Invalidating global event tap mach port")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    /// Attempt to create and install the CGEvent tap.
    /// - Returns: `true` if the tap was successfully created.
    private func tryEnable() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logger.debug("CGEvent tap creation skipped: Accessibility not yet trusted")
            return false
        }

        let eventMask = [
            CGEventType.keyDown
        ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: globalKeyEventHandler(proxy:type:cgEvent:userInfo:),
            userInfo: nil
        ) else {
            logger.warning("CGEvent tap creation failed despite Accessibility being trusted")
            return false
        }

        self.eventTap = tap

        // Cancel retry timer since we succeeded.
        if let enableTimer {
            enableTimer.invalidate()
            self.enableTimer = nil
        }

        // Attach the tap to the main run loop so it processes events.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            CFMachPortCreateRunLoopSource(nil, tap, 0),
            .commonModes
        )

        logger.info("Global event tap successfully installed for global keybindings")
        return true
    }
}

// MARK: - CGEvent Tap Callback

/// C-compatible callback invoked for each intercepted global key event.
private func globalKeyEventHandler(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let result = Unmanaged.passUnretained(cgEvent)

    // If the tap gets disabled by the system (e.g., too slow), re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = GlobalEventTap.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return result
    }

    // Only handle keyDown events.
    guard type == .keyDown else { return result }

    // Get the ghostty app handle from the cached reference.
    guard let app = GlobalEventTap.shared.ghosttyApp else { return result }

    // Convert CGEvent to NSEvent.
    guard let event = NSEvent(cgEvent: cgEvent) else { return result }

    // Translate to ghostty key event and check if it matches a global binding.
    let keyEvent = EventTranslator.translateKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
    if GhosttyFFI.appKey(app, event: keyEvent) {
        logger.info("Global key event handled: keyCode=\(event.keyCode)")
        return nil  // Consume the event.
    }

    return result
}
