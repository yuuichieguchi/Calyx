// GhosttySurface.swift
// Calyx
//
// Wraps ghostty_surface_t lifecycle. One instance per terminal pane.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GhosttySurface")

// MARK: - GhosttySurfaceController

@MainActor
final class GhosttySurfaceController: Identifiable {

    /// Unique identifier for this surface.
    let id = UUID()

    /// The underlying ghostty surface handle.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t? = nil

    /// Weak reference back to the hosting view.
    weak var surfaceView: SurfaceView?

    /// The current cell size (updated via CELL_SIZE action).
    var cellSize: NSSize = .zero

    /// The current surface size information.
    var surfaceSize: ghostty_surface_size_s? = nil

    /// Whether the surface needs confirmation before closing.
    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceNeedsConfirmQuit(surface)
    }

    /// Whether the process in this surface has exited.
    var processExited: Bool {
        guard let surface else { return true }
        return GhosttyFFI.surfaceProcessExited(surface)
    }

    // MARK: - Initialization

    /// Create a new surface controller.
    /// - Parameters:
    ///   - app: The ghostty app handle.
    ///   - baseConfig: The surface configuration struct.
    ///   - view: The NSView that will host this surface.
    init?(app: ghostty_app_t, baseConfig: ghostty_surface_config_s, view: SurfaceView) {
        self.surfaceView = view

        // Create the surface configuration, setting up the platform fields.
        var config = baseConfig
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        )
        config.userdata = Unmanaged.passUnretained(view).toOpaque()

        // Set scale factor from the window or default to 2.0 for Retina.
        config.scale_factor = Double(view.window?.backingScaleFactor ?? 2.0)

        // Create the surface.
        guard let newSurface = GhosttyFFI.surfaceNew(app, config: &config) else {
            logger.error("ghostty_surface_new failed")
            return nil
        }
        self.surface = newSurface

        // Set the display ID if we have a window on a screen.
        if let screen = view.window?.screen {
            GhosttyFFI.surfaceSetDisplayID(newSurface, displayID: screen.displayID ?? 0)
        }

        // Set initial content scale.
        let scale = Double(view.window?.backingScaleFactor ?? 2.0)
        GhosttyFFI.surfaceSetContentScale(newSurface, xScale: scale, yScale: scale)

        // Set initial size from the view's frame (in backing pixels).
        let backingFrame = view.convertToBacking(view.frame)
        GhosttyFFI.surfaceSetSize(
            newSurface,
            width: UInt32(backingFrame.width),
            height: UInt32(backingFrame.height)
        )

        logger.info("Surface created: \(self.id)")
    }

    deinit {
        // Surface must be freed on the main actor. Since deinit may run off main,
        // capture the surface value and dispatch.
        if let surface {
            Task.detached { @MainActor in
                GhosttyFFI.surfaceFree(surface)
            }
        }
    }

    // MARK: - Size & Scale

    /// Update the surface size in framebuffer pixels.
    func updateSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetSize(surface, width: width, height: height)

        // Update cached size metrics.
        self.surfaceSize = GhosttyFFI.surfaceSize(surface)
    }

    /// Update the content scale factors.
    func setContentScale(_ scale: Double) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetContentScale(surface, xScale: scale, yScale: scale)
    }

    /// Set the content scale with independent x/y factors.
    func setContentScale(x xScale: Double, y yScale: Double) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetContentScale(surface, xScale: xScale, yScale: yScale)
    }

    // MARK: - Focus & Visibility

    /// Set whether the surface is focused.
    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetFocus(surface, focused: focused)
    }

    /// Set whether the surface is occluded.
    func setOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetOcclusion(surface, occluded: occluded)
    }

    /// Set the display ID (used for vsync with CVDisplayLink).
    func setDisplayID(_ displayID: UInt32) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetDisplayID(surface, displayID: displayID)
    }

    /// Set the color scheme for this surface.
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetColorScheme(surface, scheme: scheme)
    }

    // MARK: - Close

    /// Request the surface to close.
    func requestClose() {
        guard let surface else { return }
        GhosttyFFI.surfaceRequestClose(surface)
    }

    // MARK: - Input

    /// Send a key event to the surface.
    @discardableResult
    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceKey(surface, event: event)
    }

    /// Check if a key event matches a surface binding.
    func keyIsBinding(_ event: ghostty_input_key_s) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceKeyIsBinding(surface, event: event)
    }

    /// Get the key translation mods for input handling.
    func keyTranslationMods(_ mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        guard let surface else { return mods }
        return GhosttyFFI.surfaceKeyTranslationMods(surface, mods: mods)
    }

    /// Send composed text to the surface.
    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        guard len > 0 else { return }
        text.withCString { ptr in
            GhosttyFFI.surfaceText(surface, text: ptr, len: UInt(len - 1))
        }
    }

    /// Send preedit text to the surface.
    func sendPreedit(_ text: String?) {
        guard let surface else { return }
        if let text, !text.isEmpty {
            let len = text.utf8CString.count
            text.withCString { ptr in
                GhosttyFFI.surfacePreedit(surface, text: ptr, len: UInt(len - 1))
            }
        } else {
            GhosttyFFI.surfacePreedit(surface, text: nil, len: 0)
        }
    }

    /// Send a mouse button event.
    @discardableResult
    func sendMouseButton(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceMouseButton(surface, state: state, button: button, mods: mods)
    }

    /// Send a mouse position event.
    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceMousePos(surface, x: x, y: y, mods: mods)
    }

    /// Send a mouse scroll event.
    func sendMouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let surface else { return }
        GhosttyFFI.surfaceMouseScroll(surface, x: x, y: y, mods: mods)
    }

    /// Send a mouse pressure event.
    func sendMousePressure(stage: UInt32, pressure: Double) {
        guard let surface else { return }
        GhosttyFFI.surfaceMousePressure(surface, stage: stage, pressure: pressure)
    }

    /// Check if the mouse is captured by the terminal.
    var mouseCaptured: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceMouseCaptured(surface)
    }

    // MARK: - Selection / Clipboard

    /// Check if the surface has a selection.
    var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceHasSelection(surface)
    }

    // MARK: - Splits

    /// Split the surface in the given direction.
    func split(_ direction: ghostty_action_split_direction_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplit(surface, direction: direction)
    }

    /// Move focus to a different split.
    func splitFocus(_ direction: ghostty_action_goto_split_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitFocus(surface, direction: direction)
    }

    /// Resize a split.
    func splitResize(_ direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitResize(surface, direction: direction, amount: amount)
    }

    /// Equalize all splits.
    func splitEqualize() {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitEqualize(surface)
    }

    // MARK: - Actions

    /// Perform a keybinding action by string.
    @discardableResult
    func performAction(_ action: String) -> Bool {
        guard let surface else { return false }
        let len = action.utf8CString.count
        guard len > 0 else { return false }
        return action.withCString { ptr in
            GhosttyFFI.surfaceBindingAction(surface, action: ptr, len: UInt(len - 1))
        }
    }

    // MARK: - IME

    /// Get the IME candidate window position.
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let surface else { return (0, 0, 0, 0) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        GhosttyFFI.surfaceIMEPoint(surface, x: &x, y: &y, width: &width, height: &height)
        return (x, y, width, height)
    }

    // MARK: - Config Update

    /// Update this surface's configuration.
    func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        GhosttyFFI.surfaceUpdateConfig(surface, config: config)
    }

    /// Get the inherited surface configuration (for creating splits/tabs).
    func inheritedConfig() -> ghostty_surface_config_s? {
        guard let surface else { return nil }
        return GhosttyFFI.surfaceInheritedConfig(surface)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: UInt32? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return id.uint32Value
    }
}
