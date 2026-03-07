// GhosttyFFI.swift
// Calyx
//
// Thin Swift wrappers around ghostty C functions.
// All FFI calls are centralized here so API changes only affect this one file.

@preconcurrency import AppKit
import GhosttyKit

// MARK: - GhosttyFFI

/// Centralized FFI layer for all ghostty C function calls.
/// Each method is a thin wrapper with no business logic.
enum GhosttyFFI {

    // MARK: - Global

    /// Initialize the ghostty library. Must be called once before any other ghostty function.
    /// - Returns: `true` if initialization succeeded.
    @discardableResult
    static func initialize() -> Bool {
        ghostty_init(0, nil) == GHOSTTY_SUCCESS
    }

    /// Returns build and version information about the ghostty library.
    static func info() -> ghostty_info_s {
        ghostty_info()
    }

    /// Returns the translation for a given string key (i18n).
    static func translate(_ key: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
        ghostty_translate(key)
    }

    /// Free a ghostty-allocated string.
    static func freeString(_ string: ghostty_string_s) {
        ghostty_string_free(string)
    }

    // MARK: - Config

    /// Create a new, empty configuration object.
    static func configNew() -> ghostty_config_t? {
        ghostty_config_new()
    }

    /// Free a configuration object.
    static func configFree(_ config: ghostty_config_t) {
        ghostty_config_free(config)
    }

    /// Clone an existing configuration.
    static func configClone(_ config: ghostty_config_t) -> ghostty_config_t? {
        ghostty_config_clone(config)
    }

    /// Load default configuration files (e.g. ~/.config/ghostty/config).
    static func configLoadDefaultFiles(_ config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
    }

    /// Load CLI arguments into the configuration.
    static func configLoadCLIArgs(_ config: ghostty_config_t) {
        ghostty_config_load_cli_args(config)
    }

    /// Load recursively referenced configuration files.
    static func configLoadRecursiveFiles(_ config: ghostty_config_t) {
        ghostty_config_load_recursive_files(config)
    }

    /// Finalize the configuration, making default values available.
    static func configFinalize(_ config: ghostty_config_t) {
        ghostty_config_finalize(config)
    }

    /// Get a configuration value by key.
    /// - Parameters:
    ///   - config: The configuration object.
    ///   - value: Pointer to the output value.
    ///   - key: The configuration key string.
    ///   - keyLen: Length of the key string.
    /// - Returns: `true` if the key was found.
    static func configGet(_ config: ghostty_config_t, _ value: UnsafeMutableRawPointer, _ key: UnsafePointer<CChar>, _ keyLen: UInt) -> Bool {
        ghostty_config_get(config, value, key, keyLen)
    }

    /// Returns the number of configuration diagnostics (errors/warnings).
    static func configDiagnosticsCount(_ config: ghostty_config_t) -> UInt32 {
        ghostty_config_diagnostics_count(config)
    }

    /// Returns a specific diagnostic message by index.
    static func configGetDiagnostic(_ config: ghostty_config_t, index: UInt32) -> ghostty_diagnostic_s {
        ghostty_config_get_diagnostic(config, index)
    }

    /// Returns the trigger for a given action string.
    static func configTrigger(_ config: ghostty_config_t, action: UnsafePointer<CChar>, len: UInt) -> ghostty_input_trigger_s {
        ghostty_config_trigger(config, action, len)
    }

    /// Returns the file path to the configuration file.
    static func configOpenPath() -> ghostty_string_s {
        ghostty_config_open_path()
    }

    // MARK: - App

    /// Create a new ghostty app instance.
    static func appNew(_ runtimeConfig: UnsafePointer<ghostty_runtime_config_s>, config: ghostty_config_t) -> ghostty_app_t? {
        ghostty_app_new(runtimeConfig, config)
    }

    /// Free a ghostty app instance.
    static func appFree(_ app: ghostty_app_t) {
        ghostty_app_free(app)
    }

    /// Tick the app event loop. Should be called from the main thread.
    static func appTick(_ app: ghostty_app_t) {
        ghostty_app_tick(app)
    }

    /// Get the userdata pointer associated with the app.
    static func appUserdata(_ app: ghostty_app_t) -> UnsafeMutableRawPointer? {
        ghostty_app_userdata(app)
    }

    /// Set whether the application is focused.
    static func appSetFocus(_ app: ghostty_app_t, focused: Bool) {
        ghostty_app_set_focus(app, focused)
    }

    /// Set the color scheme for the entire app.
    static func appSetColorScheme(_ app: ghostty_app_t, scheme: ghostty_color_scheme_e) {
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// Send a key event at the app level (for global keybinds).
    @discardableResult
    static func appKey(_ app: ghostty_app_t, event: ghostty_input_key_s) -> Bool {
        ghostty_app_key(app, event)
    }

    /// Check if a key event would match an app-level binding.
    static func appKeyIsBinding(_ app: ghostty_app_t, event: ghostty_input_key_s) -> Bool {
        ghostty_app_key_is_binding(app, event)
    }

    /// Notify ghostty that the keyboard layout has changed.
    static func appKeyboardChanged(_ app: ghostty_app_t) {
        ghostty_app_keyboard_changed(app)
    }

    /// Open the configuration file.
    static func appOpenConfig(_ app: ghostty_app_t) {
        ghostty_app_open_config(app)
    }

    /// Check if the app needs confirmation before quitting.
    static func appNeedsConfirmQuit(_ app: ghostty_app_t) -> Bool {
        ghostty_app_needs_confirm_quit(app)
    }

    /// Check if the app has any global keybinds.
    static func appHasGlobalKeybinds(_ app: ghostty_app_t) -> Bool {
        ghostty_app_has_global_keybinds(app)
    }

    /// Update the app configuration.
    static func appUpdateConfig(_ app: ghostty_app_t, config: ghostty_config_t) {
        ghostty_app_update_config(app, config)
    }

    // MARK: - Surface Config

    /// Create a new default surface configuration.
    static func surfaceConfigNew() -> ghostty_surface_config_s {
        ghostty_surface_config_new()
    }

    // MARK: - Surface

    /// Create a new terminal surface.
    static func surfaceNew(_ app: ghostty_app_t, config: UnsafePointer<ghostty_surface_config_s>) -> ghostty_surface_t? {
        ghostty_surface_new(app, config)
    }

    /// Free a terminal surface.
    static func surfaceFree(_ surface: ghostty_surface_t) {
        ghostty_surface_free(surface)
    }

    /// Get the userdata associated with a surface.
    static func surfaceUserdata(_ surface: ghostty_surface_t) -> UnsafeMutableRawPointer? {
        ghostty_surface_userdata(surface)
    }

    /// Get the app that owns a surface.
    static func surfaceApp(_ surface: ghostty_surface_t) -> ghostty_app_t? {
        ghostty_surface_app(surface)
    }

    /// Get the inherited configuration for a surface (used when creating splits/tabs).
    static func surfaceInheritedConfig(_ surface: ghostty_surface_t) -> ghostty_surface_config_s {
        ghostty_surface_inherited_config(surface)
    }

    /// Update a surface's configuration.
    static func surfaceUpdateConfig(_ surface: ghostty_surface_t, config: ghostty_config_t) {
        ghostty_surface_update_config(surface, config)
    }

    /// Draw the surface (render a frame).
    static func surfaceDraw(_ surface: ghostty_surface_t) {
        ghostty_surface_draw(surface)
    }

    /// Refresh the surface (mark for redraw).
    static func surfaceRefresh(_ surface: ghostty_surface_t) {
        ghostty_surface_refresh(surface)
    }

    /// Set the surface size in pixels (framebuffer dimensions).
    static func surfaceSetSize(_ surface: ghostty_surface_t, width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    /// Get the current surface size information.
    static func surfaceSize(_ surface: ghostty_surface_t) -> ghostty_surface_size_s {
        ghostty_surface_size(surface)
    }

    /// Set the content scale factors (for Retina displays).
    static func surfaceSetContentScale(_ surface: ghostty_surface_t, xScale: Double, yScale: Double) {
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }

    /// Set whether the surface is focused.
    static func surfaceSetFocus(_ surface: ghostty_surface_t, focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    /// Set whether the surface is occluded (not visible).
    static func surfaceSetOcclusion(_ surface: ghostty_surface_t, occluded: Bool) {
        ghostty_surface_set_occlusion(surface, occluded)
    }

    /// Set the color scheme for a surface.
    static func surfaceSetColorScheme(_ surface: ghostty_surface_t, scheme: ghostty_color_scheme_e) {
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    /// Set the display ID (for vsync with CVDisplayLink).
    static func surfaceSetDisplayID(_ surface: ghostty_surface_t, displayID: UInt32) {
        ghostty_surface_set_display_id(surface, displayID)
    }

    /// Get the translation mods for a surface key event.
    static func surfaceKeyTranslationMods(_ surface: ghostty_surface_t, mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        ghostty_surface_key_translation_mods(surface, mods)
    }

    // MARK: - Surface Input

    /// Send a key event to the surface.
    @discardableResult
    static func surfaceKey(_ surface: ghostty_surface_t, event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    /// Check if a key event matches a surface-level binding.
    static func surfaceKeyIsBinding(_ surface: ghostty_surface_t, event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key_is_binding(surface, event)
    }

    /// Send composed text to the surface.
    static func surfaceText(_ surface: ghostty_surface_t, text: UnsafePointer<CChar>, len: UInt) {
        ghostty_surface_text(surface, text, len)
    }

    /// Send preedit (composing) text to the surface.
    static func surfacePreedit(_ surface: ghostty_surface_t, text: UnsafePointer<CChar>?, len: UInt) {
        ghostty_surface_preedit(surface, text, len)
    }

    /// Check if the mouse is captured by the terminal application.
    static func surfaceMouseCaptured(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_mouse_captured(surface)
    }

    /// Send a mouse button event.
    @discardableResult
    static func surfaceMouseButton(_ surface: ghostty_surface_t, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    /// Send a mouse position event.
    static func surfaceMousePos(_ surface: ghostty_surface_t, x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    /// Send a mouse scroll event.
    static func surfaceMouseScroll(_ surface: ghostty_surface_t, x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    /// Send a mouse pressure event (force touch).
    static func surfaceMousePressure(_ surface: ghostty_surface_t, stage: UInt32, pressure: Double) {
        ghostty_surface_mouse_pressure(surface, stage, pressure)
    }

    /// Get the IME candidate window position.
    static func surfaceIMEPoint(_ surface: ghostty_surface_t, x: inout Double, y: inout Double, width: inout Double, height: inout Double) {
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    }

    // MARK: - Surface Selection / Clipboard

    /// Check if the surface has an active selection.
    static func surfaceHasSelection(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_has_selection(surface)
    }

    /// Read the currently selected text.
    static func surfaceReadSelection(_ surface: ghostty_surface_t, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_read_selection(surface, &text)
    }

    /// Read text from a specific region.
    static func surfaceReadText(_ surface: ghostty_surface_t, selection: ghostty_selection_s, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_read_text(surface, selection, &text)
    }

    /// Free text returned by read_selection or read_text.
    static func surfaceFreeText(_ surface: ghostty_surface_t, text: inout ghostty_text_s) {
        ghostty_surface_free_text(surface, &text)
    }

    /// Complete an asynchronous clipboard request.
    static func surfaceCompleteClipboardRequest(_ surface: ghostty_surface_t, data: UnsafePointer<CChar>, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        ghostty_surface_complete_clipboard_request(surface, data, state, confirmed)
    }

    /// Request the surface to close.
    static func surfaceRequestClose(_ surface: ghostty_surface_t) {
        ghostty_surface_request_close(surface)
    }

    /// Check if the surface needs confirmation before closing.
    static func surfaceNeedsConfirmQuit(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    /// Check if the process running in this surface has exited.
    static func surfaceProcessExited(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_process_exited(surface)
    }

    // MARK: - Surface Splits

    /// Split the surface in the given direction.
    static func surfaceSplit(_ surface: ghostty_surface_t, direction: ghostty_action_split_direction_e) {
        ghostty_surface_split(surface, direction)
    }

    /// Move focus to a different split.
    static func surfaceSplitFocus(_ surface: ghostty_surface_t, direction: ghostty_action_goto_split_e) {
        ghostty_surface_split_focus(surface, direction)
    }

    /// Resize a split in the given direction.
    static func surfaceSplitResize(_ surface: ghostty_surface_t, direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        ghostty_surface_split_resize(surface, direction, amount)
    }

    /// Equalize all split sizes.
    static func surfaceSplitEqualize(_ surface: ghostty_surface_t) {
        ghostty_surface_split_equalize(surface)
    }

    // MARK: - Surface Actions

    /// Perform a keybinding action by string.
    @discardableResult
    static func surfaceBindingAction(_ surface: ghostty_surface_t, action: UnsafePointer<CChar>, len: UInt) -> Bool {
        ghostty_surface_binding_action(surface, action, len)
    }

    /// Get the command options for a surface.
    static func surfaceCommands(_ surface: ghostty_surface_t, commands: inout UnsafeMutablePointer<ghostty_command_s>?, count: inout Int) {
        ghostty_surface_commands(surface, &commands, &count)
    }

    // MARK: - Surface QuickLook (macOS)

    /// Get the font for QuickLook display.
    static func surfaceQuicklookFont(_ surface: ghostty_surface_t) -> UnsafeMutableRawPointer? {
        ghostty_surface_quicklook_font(surface)
    }

    /// Get the word under cursor for QuickLook.
    static func surfaceQuicklookWord(_ surface: ghostty_surface_t, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_quicklook_word(surface, &text)
    }

    // MARK: - Window Background

    /// Set window background blur.
    static func setWindowBackgroundBlur(_ app: ghostty_app_t, window: UnsafeMutableRawPointer) {
        ghostty_set_window_background_blur(app, window)
    }
}
