// GhosttyAction.swift
// Calyx
//
// Routes action callbacks from libghostty to the app.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GhosttyAction")

// MARK: - GhosttyActionRouter

@MainActor
enum GhosttyActionRouter {

    /// Handle an action callback from libghostty.
    /// - Parameters:
    ///   - app: The ghostty app handle.
    ///   - target: The target for the action (app or surface).
    ///   - action: The action to perform.
    /// - Returns: `true` if the action was handled.
    static func handleAction(
        app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // Verify we have a known target type.
        switch target.tag {
        case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
            break
        default:
            logger.warning("Unknown action target: \(target.tag.rawValue)")
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return handleSetTitle(app, target: target, value: action.action.set_title)

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            return handleSetTabTitle(app, target: target, value: action.action.set_tab_title)

        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            return handleCopyTitleToClipboard(app, target: target)

        case GHOSTTY_ACTION_PWD:
            return handlePwd(app, target: target, value: action.action.pwd)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return handleDesktopNotification(app, target: target, value: action.action.desktop_notification)

        case GHOSTTY_ACTION_NEW_SPLIT:
            return handleNewSplit(app, target: target, direction: action.action.new_split)

        case GHOSTTY_ACTION_NEW_TAB:
            return handleNewTab(app, target: target)

        case GHOSTTY_ACTION_NEW_WINDOW:
            return handleNewWindow(app, target: target)

        case GHOSTTY_ACTION_CLOSE_TAB:
            return handleCloseTab(app, target: target, mode: action.action.close_tab_mode)

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return handleCloseWindow(app, target: target)

        case GHOSTTY_ACTION_RENDER:
            return handleRender(app, target: target)

        case GHOSTTY_ACTION_CELL_SIZE:
            return handleCellSize(app, target: target, value: action.action.cell_size)

        case GHOSTTY_ACTION_SCROLLBAR:
            return handleScrollbar(app, target: target, value: action.action.scrollbar)

        case GHOSTTY_ACTION_INITIAL_SIZE:
            return handleInitialSize(app, target: target, value: action.action.initial_size)

        case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
            return handleResetWindowSize(app, target: target)

        case GHOSTTY_ACTION_SIZE_LIMIT:
            return handleSizeLimit(app, target: target, value: action.action.size_limit)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return handleMouseShape(app, target: target, shape: action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return handleMouseVisibility(app, target: target, visibility: action.action.mouse_visibility)

        case GHOSTTY_ACTION_QUIT:
            return handleQuit(app)

        case GHOSTTY_ACTION_COLOR_CHANGE:
            return handleColorChange(app, target: target, change: action.action.color_change)

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return handleConfigChange(app, target: target, value: action.action.config_change)

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return handleReloadConfig(app, target: target, value: action.action.reload_config)

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            return handleToggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
            return handleToggleMaximize(app, target: target)

        case GHOSTTY_ACTION_OPEN_CONFIG:
            return handleOpenConfig(app)

        case GHOSTTY_ACTION_OPEN_URL:
            return handleOpenURL(action.action.open_url)

        case GHOSTTY_ACTION_RING_BELL:
            return handleRingBell(app, target: target)

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return handleShowChildExited(app, target: target, value: action.action.child_exited)

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return handleRendererHealth(app, target: target, health: action.action.renderer_health)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            return handleMouseOverLink(app, target: target, value: action.action.mouse_over_link)

        case GHOSTTY_ACTION_GOTO_SPLIT:
            return handleGotoSplit(app, target: target, direction: action.action.goto_split)

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return handleResizeSplit(app, target: target, resize: action.action.resize_split)

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            return handleEqualizeSplits(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return handleToggleSplitZoom(app, target: target)

        case GHOSTTY_ACTION_START_SEARCH:
            return handleStartSearch(app, target: target, value: action.action.start_search)

        case GHOSTTY_ACTION_END_SEARCH:
            return handleEndSearch(app, target: target)

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            return handleSearchTotal(app, target: target, value: action.action.search_total)

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            return handleSearchSelected(app, target: target, value: action.action.search_selected)

        case GHOSTTY_ACTION_GOTO_TAB:
            return handleGotoTab(app, target: target, tab: action.action.goto_tab)

        case GHOSTTY_ACTION_MOVE_TAB:
            return handleMoveTab(app, target: target, value: action.action.move_tab)

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            logger.debug("Key sequence action (stub)")
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            return handleProgressReport(app, target: target, value: action.action.progress_report)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            return handleCommandFinished(app, target: target, value: action.action.command_finished)

        case GHOSTTY_ACTION_SECURE_INPUT:
            return handleSecureInput(app, target: target, mode: action.action.secure_input)

        case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
            return handleToggleQuickTerminal(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            return handleToggleCommandPalette(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
            return handleToggleTabOverview(target: target)

        case GHOSTTY_ACTION_GOTO_WINDOW:
            return handleGotoWindow(app, target: target, direction: action.action.goto_window)

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            return handleCloseAllWindows(app)

        case GHOSTTY_ACTION_PRESENT_TERMINAL:
            return handlePresentTerminal(app, target: target)

        case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            return handleCheckForUpdates(app)

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return handlePromptTitle(app, target: target, value: action.action.prompt_title)

        case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
             GHOSTTY_ACTION_TOGGLE_VISIBILITY,
             GHOSTTY_ACTION_QUIT_TIMER,
             GHOSTTY_ACTION_FLOAT_WINDOW,
             GHOSTTY_ACTION_INSPECTOR,
             GHOSTTY_ACTION_RENDER_INSPECTOR,
             GHOSTTY_ACTION_UNDO,
             GHOSTTY_ACTION_REDO:
            logger.info("Known but unimplemented action: \(action.tag.rawValue)")
            return false

        // MARK: - Intentional No-Ops
        //
        // Unlike the "Known but unimplemented" group above, each of these
        // two is a deliberate decision, not a placeholder for later work.
        // Each still returns `true`: a `false` here tells libghostty the
        // keybind that triggered the action was NOT consumed, so it falls
        // through and the raw key sequence gets sent to the shell instead
        // (see `ghostty_runtime_action_cb`'s doc comment in ghostty.h) --
        // exactly the wrong outcome for a keybind Calyx has consciously
        // decided has nothing to do here.

        case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR:
            // The GTK Inspector is a GTK-only debugging tool with no
            // AppKit equivalent to route it to.
            return true

        case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
            // On-screen-keyboard toggling only applies to GTK's touch
            // input and iOS; a physical-keyboard-first macOS terminal has
            // no on-screen keyboard concept to toggle.
            return true

        default:
            logger.warning("Unknown action: \(action.tag.rawValue)")
            return false
        }
    }

    // MARK: - Action Handlers

    private static func handleSetTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_set_title_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let titlePtr = value.title else { return false }
        let title = String(cString: titlePtr)

        NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: surfaceView,
            userInfo: ["title": title]
        )
        return true
    }

    /// OSC 9;4 progress report, forwarded as `.ghosttyProgressReport` for
    /// `CalyxWindowController` to feed into `AgentRegistry.
    /// handleProgressReport` (Herdr layer 2). `SET`/`INDETERMINATE` — a
    /// progress indicator is actively showing — map to `active: true`;
    /// `REMOVE`/`ERROR`/`PAUSE` all map to `active: false`, mirroring
    /// `handleProgressReport`'s two-state (`isActive`) contract.
    private static func handleProgressReport(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_progress_report_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        let isActive: Bool
        switch value.state {
        case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            isActive = true
        default:
            isActive = false
        }

        NotificationCenter.default.post(
            name: .ghosttyProgressReport,
            object: surfaceView,
            userInfo: ["active": isActive]
        )
        return true
    }

    /// `GHOSTTY_ACTION_COMMAND_FINISHED` (`apprt.action.CommandFinished`,
    /// from ghostty's own shell-integration OSC 133 C/D pairing),
    /// forwarded as `.ghosttyCommandFinished` for `AppDelegate`
    /// to feed into `AgentRegistry.handleGhosttyCommandFinished` -- a
    /// pane-level fallback for the shells Calyx's own `/command-event`
    /// shell integration does not cover (bash, elvish, nushell). A
    /// command whose OSC 133;D carried no exit code still arrives here
    /// as `0`, indistinguishable from a real success: ghostty's own
    /// `termio/stream_handler.zig` reads the option as
    /// `readOption(.exit_code) orelse 0` before building the action, so
    /// the `?u8` it carries is never null on the terminal path. The C
    /// struct nonetheless reserves `-1` for "no exit code reported", and
    /// `commandFinishedExitCode` below honours that contract even though
    /// this path cannot currently produce it. That ambiguity is why this
    /// stays a fallback rather than a replacement, and why
    /// `CommandLogStore` still relies on Calyx's own hook for the command
    /// log rather than this signal. An
    /// empty Enter at the prompt emits nothing: the action only fires
    /// once a command's OSC 133;C is paired with its matching 133;D,
    /// which an empty line never produces.
    private static func handleCommandFinished(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_command_finished_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyCommandFinished,
            object: surfaceView,
            userInfo: ["exit_code": commandFinishedExitCode(value.exit_code) as Any]
        )
        return true
    }

    /// Maps `ghostty_action_command_finished_s.exit_code`'s raw payload
    /// to `AgentRegistry.handleGhosttyCommandFinished`'s `exitCode:
    /// Int32?` parameter: ghostty's own `-1` sentinel ("no exit code was
    /// reported", ghostty.h) becomes `nil`; every other value -- stop-
    /// signal codes included -- passes through unchanged, since excluding
    /// those is `AgentRegistry.handleGhosttyCommandFinished`'s own job,
    /// not this mapper's. Not `private`: `@testable import Calyx` reaches
    /// this from `GhosttyActionCommandFinishedTests` to pin the mapping
    /// independently of `handleCommandFinished`'s own FFI-dependent
    /// target resolution.
    static func commandFinishedExitCode(_ rawExitCode: Int16) -> Int32? {
        rawExitCode == -1 ? nil : Int32(rawExitCode)
    }

    private static func handlePwd(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_pwd_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let pwdPtr = value.pwd else { return false }
        let pwd = String(cString: pwdPtr)

        NotificationCenter.default.post(
            name: .ghosttySetPwd,
            object: surfaceView,
            userInfo: ["pwd": pwd]
        )
        return true
    }

    private static func handleDesktopNotification(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_desktop_notification_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        let title: String
        if let ptr = value.title {
            title = String(validatingCString: ptr) ?? ""
        } else {
            title = ""
        }
        let body: String
        if let ptr = value.body {
            body = String(validatingCString: ptr) ?? ""
        } else {
            body = ""
        }

        NotificationCenter.default.post(
            name: .ghosttyDesktopNotification,
            object: surfaceView,
            userInfo: ["title": title, "body": body]
        )
        return true
    }

    private static func handleNewSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_split_direction_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        var userInfo: [String: Any] = ["direction": direction]
        if let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewSplit,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleNewTab(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        var userInfo: [String: Any] = [:]
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewTab,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleNewWindow(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        var userInfo: [String: Any] = [:]
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewWindow,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleCloseTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode: ghostty_action_close_tab_mode_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyCloseTab,
            object: surfaceView,
            userInfo: ["mode": mode]
        )
        return true
    }

    private static func handleCloseWindow(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        NotificationCenter.default.post(
            name: .ghosttyCloseWindow,
            object: surfaceView
        )
        return true
    }

    private static func handleRender(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        surfaceView.needsDisplay = true
        return true
    }

    private static func handleCellSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_cell_size_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        // Update both the cached cell size on the view (always succeeds) and
        // the surface controller (may be nil during ghostty_surface_new).
        let size = NSSize(width: CGFloat(value.width), height: CGFloat(value.height))
        surfaceView.cachedCellSize = size
        surfaceView.surfaceController?.cellSize = size

        NotificationCenter.default.post(
            name: .ghosttyCellSizeChange,
            object: surfaceView,
            userInfo: ["width": value.width, "height": value.height]
        )
        return true
    }

    private static func handleScrollbar(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_scrollbar_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        let state = GhosttySurfaceController.ScrollbarState(
            total: value.total,
            offset: value.offset,
            len: value.len
        )
        surfaceView.surfaceController?.scrollbar = state
        surfaceView.scrollbarUpdateHandler?(state)
        return true
    }

    private static func handleInitialSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_initial_size_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        // Store on the view (mirrors handleCellSize's cachedCellSize
        // shape) so CalyxWindowController.init can recover this for a
        // brand-new window's first surface, whose INITIAL_SIZE fires
        // synchronously from inside ghostty_surface_new -- before
        // registerNotificationObservers() has registered this action's
        // observer. See SurfaceView.initialSize's own doc comment.
        surfaceView.initialSize = NSSize(width: CGFloat(value.width), height: CGFloat(value.height))

        NotificationCenter.default.post(
            name: .ghosttyInitialSize,
            object: surfaceView,
            userInfo: ["width": value.width, "height": value.height]
        )
        return true
    }

    /// Deliberately has no `CalyxWindowController` observer for
    /// `.ghosttySizeLimit` — NOT a missing-observer bug (unlike the six
    /// notifications the missing-observer investigation exists to fix).
    /// Ghostty's own macOS app documents this action as "known but
    /// unimplemented" too (`Ghostty.App.swift:659-664`). Calyx additionally
    /// layers tabs, splits, and a sidebar on top of any one surface, so a
    /// single SURFACE's requested min/max size has no coherent meaning at
    /// the WINDOW level. `CalyxWindow.minSize = NSSize(width: 400, height:
    /// 300)` (`CalyxWindow.swift`) is this app's real, window-level
    /// minimum-size constraint.
    private static func handleSizeLimit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_size_limit_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttySizeLimit,
            object: surfaceView,
            userInfo: [
                "min_width": value.min_width,
                "min_height": value.min_height,
                "max_width": value.max_width,
                "max_height": value.max_height,
            ]
        )
        return true
    }

    private static func handleMouseShape(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        shape: ghostty_action_mouse_shape_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        surfaceView.updateCursorShape(shape)
        return true
    }

    private static func handleMouseVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        visibility: ghostty_action_mouse_visibility_e
    ) -> Bool {
        switch visibility {
        case GHOSTTY_MOUSE_HIDDEN:
            NSCursor.setHiddenUntilMouseMoves(true)
        default:
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        return true
    }

    private static func handleMouseOverLink(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_mouse_over_link_s
    ) -> Bool {
        // Phase 1: stub
        logger.debug("Mouse over link (stub)")
        return true
    }

    private static func handleQuit(_ app: ghostty_app_t) -> Bool {
        NSApplication.shared.terminate(nil)
        return true
    }

    /// Deliberately has no `CalyxWindowController` observer for
    /// `.ghosttyColorChange` — NOT a missing-observer bug (unlike the six
    /// notifications the missing-observer investigation exists to fix).
    /// OSC 4/10/11/12's actual foreground/background/palette color change
    /// is already applied by libghostty itself before this action even
    /// fires (`ghostty/src/termio/stream_handler.zig:1225-1255`);
    /// `COLOR_CHANGE` is only apprt's cue to keep ITS OWN chrome in sync —
    /// in every other ghostty frontend that means recoloring the window's
    /// title bar/decorations to match. Calyx's chrome color is instead
    /// owned entirely by the Glass UI layer (`ThemeColorPreset` /
    /// `GhosttyThemeProvider`, plus `GhosttyConfigManager.managedKeys`'
    /// `foreground` override), which reads config directly rather than
    /// tracking this per-surface action — and `GhosttyThemeProvider` is a
    /// single app-wide singleton, while `COLOR_CHANGE` fires per SURFACE,
    /// a mismatch that would make consuming it here semantically wrong
    /// even setting the ownership question aside.
    private static func handleColorChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        change: ghostty_action_color_change_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyColorChange,
            object: surfaceView,
            userInfo: ["change": change]
        )
        return true
    }

    private static func handleConfigChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_config_change_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else {
            // App-level config change.
            NotificationCenter.default.post(
                name: .ghosttyConfigChange,
                object: nil,
                userInfo: ["config": value.config as Any]
            )
            return true
        }

        NotificationCenter.default.post(
            name: .ghosttyConfigChange,
            object: surfaceView,
            userInfo: ["config": value.config as Any]
        )
        return true
    }

    private static func handleReloadConfig(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_reload_config_s
    ) -> Bool {
        GhosttyAppController.shared.reloadConfig(soft: value.soft)
        return true
    }

    private static func handleToggleFullscreen(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode: ghostty_action_fullscreen_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyToggleFullscreen,
            object: surfaceView,
            userInfo: ["mode": mode]
        )
        return true
    }

    private static func handleOpenConfig(_ app: ghostty_app_t) -> Bool {
        SettingsWindowController.shared.showSettings()
        return true
    }

    private static func handleOpenURL(_ value: ghostty_action_open_url_s) -> Bool {
        guard let urlCStr = value.url else { return false }
        let data = Data(bytes: urlCStr, count: Int(value.len))
        guard let urlString = String(data: data, encoding: .utf8) else { return false }

        let url: URL
        if let candidate = URL(string: urlString), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: urlString)
        }

        switch value.kind {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
            if let textEditor = NSWorkspace.shared.defaultTextEditor {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: textEditor,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return true
            }
        default:
            break
        }

        NSWorkspace.shared.open(url)
        return true
    }

    /// `RING_BELL` is always surface-targeted — ghostty's own `ring_bell`
    /// handling (`ghostty/src/Surface.zig`) always calls `performAction(
    /// .{ .surface = self }, .ring_bell, {})`, never an app-targeted
    /// broadcast — so `surfaceView(from: target)` is always non-nil here
    /// in practice. No app-level fallback is implemented: an
    /// `NSSound.beep()` here would both be unreachable dead code and,
    /// even if reachable, would map to `BellFeatures.system`, which is
    /// OFF by default (`BellFeatures.ghosttyDefault`) — the opposite of
    /// what "always beep regardless of the user's bell-features" would
    /// imply. See `AppDelegate.processRingBell` for the real
    /// bell-features-driven dispatch.
    private static func handleRingBell(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyRingBell,
            object: surfaceView
        )
        return true
    }

    private static func handleShowChildExited(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_surface_message_childexited_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyShowChildExited,
            object: surfaceView,
            userInfo: ["exit_code": value.exit_code, "runtime_ms": value.timetime_ms]
        )
        return true
    }

    private static func handleRendererHealth(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        health: ghostty_action_renderer_health_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyRendererHealth,
            object: surfaceView,
            userInfo: ["health": health]
        )
        return true
    }

    private static func handleGotoSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_goto_split_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyGotoSplit,
            object: surfaceView,
            userInfo: ["direction": direction]
        )
        return true
    }

    private static func handleResizeSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        resize: ghostty_action_resize_split_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyResizeSplit,
            object: surfaceView,
            userInfo: ["resize": resize]
        )
        return true
    }

    private static func handleEqualizeSplits(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        let surfaceView = surfaceView(from: target)

        NotificationCenter.default.post(
            name: .ghosttyEqualizeSplits,
            object: surfaceView
        )
        return true
    }

    /// `GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM`. No payload — same no-userInfo
    /// shape as `handleEqualizeSplits` immediately above. Unlike that
    /// handler, though, the surface is REQUIRED (`guard let`, not `let`):
    /// there is no "zoom the whole app" concept the way equalize can
    /// (harmlessly) no-op for an app-targeted action — zooming needs to
    /// know WHICH leaf to toggle, and `CalyxWindowController
    /// .processToggleSplitZoom(surfaceView:)` takes a non-optional
    /// `SurfaceView`. Mirrors `handleGotoSplit`'s/`handleResizeSplit`'s
    /// own `guard let surfaceView` shape instead.
    private static func handleToggleSplitZoom(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyToggleSplitZoom,
            object: surfaceView
        )
        return true
    }

    // MARK: - Search Handlers

    private static func handleStartSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_start_search_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        let needle: String
        if let ptr = value.needle {
            needle = String(validatingCString: ptr) ?? ""
        } else {
            needle = ""
        }
        NotificationCenter.default.post(
            name: .ghosttyStartSearch,
            object: surfaceView,
            userInfo: ["needle": needle]
        )
        return true
    }

    private static func handleEndSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        NotificationCenter.default.post(
            name: .ghosttyEndSearch,
            object: surfaceView
        )
        return true
    }

    private static func handleSearchTotal(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_search_total_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        NotificationCenter.default.post(
            name: .ghosttySearchTotal,
            object: surfaceView,
            userInfo: ["total": Int(value.total)]
        )
        return true
    }

    private static func handleSearchSelected(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_search_selected_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        NotificationCenter.default.post(
            name: .ghosttySearchSelected,
            object: surfaceView,
            userInfo: ["selected": Int(value.selected)]
        )
        return true
    }

    // MARK: - Tab Navigation

    private static func handleGotoTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        tab: ghostty_action_goto_tab_e
    ) -> Bool {
        let surfaceView = surfaceView(from: target)
        NotificationCenter.default.post(
            name: .ghosttyGotoTab,
            object: surfaceView,
            userInfo: ["tab": tab.rawValue]
        )
        return true
    }

    // MARK: - Secure Input

    private static func handleSecureInput(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode: ghostty_action_secure_input_e
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            let input = SecureInput.shared
            switch mode {
            case GHOSTTY_SECURE_INPUT_ON:
                input.global = true
            case GHOSTTY_SECURE_INPUT_OFF:
                input.global = false
            case GHOSTTY_SECURE_INPUT_TOGGLE:
                input.global.toggle()
            default:
                return false
            }
            UserDefaults.standard.set(input.global, forKey: "SecureInput")
            return true

        case GHOSTTY_TARGET_SURFACE:
            guard let surfaceView = surfaceView(from: target) else { return false }
            switch mode {
            case GHOSTTY_SECURE_INPUT_ON:
                surfaceView.passwordInput = true
            case GHOSTTY_SECURE_INPUT_OFF:
                surfaceView.passwordInput = false
            case GHOSTTY_SECURE_INPUT_TOGGLE:
                surfaceView.passwordInput.toggle()
            default:
                return false
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Quick Terminal

    private static func handleToggleQuickTerminal(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        appDelegate.toggleQuickTerminal()
        return true
    }

    // MARK: - App-Scoped Window Management
    //
    // GHOSTTY_ACTION_GOTO_WINDOW / CLOSE_ALL_WINDOWS / PRESENT_TERMINAL /
    // CHECK_FOR_UPDATES. Like `handleToggleQuickTerminal` above (and
    // `handleQuit`/`handleOpenConfig` further up), these four go straight
    // to `AppDelegate` or an app-wide singleton instead of posting a
    // `CalyxWindowController`-owned `.ghostty*` notification: none of
    // them is meaningfully scoped to any one window's surface tree.

    /// `GHOSTTY_ACTION_GOTO_WINDOW`. `ghostty_action_goto_window_e` has
    /// only the two cases below (`ghostty.h:561-564` — no index-targeted
    /// variant), so the C enum is translated to a Swift step of `±1`
    /// right here, before ever crossing into `AppDelegate`:
    /// `focusAdjacentWindow`/`adjacentWindowIndex` stay free of any
    /// `GhosttyKit` type.
    private static func handleGotoWindow(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_goto_window_e
    ) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        let step: Int
        switch direction {
        case GHOSTTY_GOTO_WINDOW_NEXT:
            step = 1
        case GHOSTTY_GOTO_WINDOW_PREVIOUS:
            step = -1
        default:
            return false
        }
        return appDelegate.focusAdjacentWindow(step: step)
    }

    /// `GHOSTTY_ACTION_CLOSE_ALL_WINDOWS`. See `AppDelegate
    /// .closeAllWindows`'s own doc comment for the close contract (no
    /// confirmation any more — see that method's doc comment for why).
    private static func handleCloseAllWindows(_ app: ghostty_app_t) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        appDelegate.closeAllWindows()
        return true
    }

    /// `GHOSTTY_ACTION_PRESENT_TERMINAL`. Reuses `.calyxFocusSurface`
    /// rather than introducing a new notification name —
    /// `CalyxWindowController.handleFocusSurfaceNotification` already
    /// resolves a surfaceID to its owning tab/window, switches to that
    /// tab, and raises the window. `NSApp.activate()` lives HERE, not in
    /// that notification's receiver: the receiver also fires for the
    /// Agents sidebar row-click and Session Browser call sites, which
    /// must not gain an app-activation side effect they never had.
    /// `surfaceController` is `nil` mid-`ghostty_surface_new`, in which
    /// case there is no surfaceID to focus and this reports unhandled.
    private static func handlePresentTerminal(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let surfaceID = surfaceView.surfaceController?.id else { return false }
        NSApp.activate()
        NotificationCenter.default.post(name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID])
        return true
    }

    /// `GHOSTTY_ACTION_CHECK_FOR_UPDATES`. App-level singleton, no target
    /// — the same shape as `handleOpenConfig`'s `SettingsWindowController
    /// .shared` call above.
    private static func handleCheckForUpdates(_ app: ghostty_app_t) -> Bool {
        UpdateController.shared.checkForUpdates()
        return true
    }

    // MARK: - Second Missing-Observer Investigation
    //
    // `GHOSTTY_ACTION_SET_TAB_TITLE` / `COPY_TITLE_TO_CLIPBOARD` /
    // `TOGGLE_COMMAND_PALETTE` / `MOVE_TAB` / `TOGGLE_MAXIMIZE` /
    // `RESET_WINDOW_SIZE`. Every handler below is a thin adapter, exactly
    // like `handleCloseTab`/`handleToggleFullscreen` above: extract the
    // payload (if any), post the matching `.ghostty*` notification with
    // the `SurfaceView` as `object`, return `true`. No ownership/decision
    // logic lives here — `CalyxWindowController`'s `findTab(for:)`-based
    // observers own that (see CalyxWindowController.swift's own "MARK: -
    // Keybind Actions (second missing-observer investigation)").
    // `surfaceView(from:)` dereferences `target.target.surface` via
    // `GhosttyAppController.surfaceView(from:)` (`Unmanaged<SurfaceView>
    // .fromOpaque(...).takeUnretainedValue()`), which traps for a fake
    // pointer — there is no safe way to unit test this file's own half of
    // these six wire-ups; see each Swift-side `CalyxWindowController*Tests`
    // suite instead.

    /// `GHOSTTY_ACTION_SET_TAB_TITLE`. Reuses `ghostty_action_set_title_s`
    /// (ghostty.h: `set_title` and `set_tab_title` share one payload
    /// shape, just a different union tag) — mirrors `handleSetTitle`'s own
    /// structure exactly, except `String(validatingCString:) ?? ""`
    /// instead of `String(cString:)`: `set_tab_title` arrives via OSC, so
    /// the byte sequence is not guaranteed valid UTF-8, and `String
    /// (cString:)` traps on invalid input.
    private static func handleSetTabTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_set_title_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let titlePtr = value.title else { return false }
        let title = String(validatingCString: titlePtr) ?? ""

        NotificationCenter.default.post(
            name: .ghosttySetTabTitle,
            object: surfaceView,
            userInfo: ["title": title]
        )
        return true
    }

    /// `GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD`. No payload (not a member
    /// of `ghostty_action_u`) — mirrors `handleEqualizeSplits`'s/
    /// `handleRingBell`'s no-payload shape.
    private static func handleCopyTitleToClipboard(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyCopyTitleToClipboard,
            object: surfaceView
        )
        return true
    }

    /// `GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE`. No payload.
    private static func handleToggleCommandPalette(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyToggleCommandPalette,
            object: surfaceView
        )
        return true
    }

    /// `GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW`: GTK's tab grid
    /// (AdwTabOverview) has no AppKit counterpart, so Calyx routes the
    /// keybind to its own all-panes overview, Mission Map. Posts with the
    /// triggering `SurfaceView`, or `nil` for a non-surface target (the
    /// key window's controller then acts). Always returns `true`: a
    /// `false` would tell libghostty the keybind was not consumed and
    /// send the raw keys to the shell.
    private static func handleToggleTabOverview(target: ghostty_target_s) -> Bool {
        NotificationCenter.default.post(
            name: .ghosttyToggleTabOverview,
            object: surfaceView(from: target)
        )
        return true
    }

    /// `GHOSTTY_ACTION_MOVE_TAB`. `ghostty_action_move_tab_s.amount` is
    /// `ssize_t` -> Swift `Int`.
    private static func handleMoveTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_move_tab_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyMoveTab,
            object: surfaceView,
            userInfo: ["amount": Int(value.amount)]
        )
        return true
    }

    /// `GHOSTTY_ACTION_TOGGLE_MAXIMIZE`. No payload.
    private static func handleToggleMaximize(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyToggleMaximize,
            object: surfaceView
        )
        return true
    }

    /// `GHOSTTY_ACTION_RESET_WINDOW_SIZE`. No payload.
    private static func handleResetWindowSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyResetWindowSize,
            object: surfaceView
        )
        return true
    }

    // MARK: - Prompt Title (GitHub issue #42)

    /// `GHOSTTY_ACTION_PROMPT_TITLE` (`prompt_tab_title`/
    /// `prompt_surface_title` keybinds). Unlike `handleSetTabTitle`'s
    /// `ghostty_action_set_title_s` (a struct with a `const char* title`
    /// pointer), `ghostty_action_prompt_title_e` (ghostty.h) is a plain
    /// two-case C enum with no pointer payload to extract or validate.
    /// Converted to `TitlePromptScope`'s `String` raw value
    /// (`"surface"`/`"tab"`) before posting, rather than forwarded as the
    /// raw C enum through `userInfo` (contrast `handleCloseTab`'s
    /// `["mode": mode]`): `CalyxWindowController.handlePromptTitleNotification`
    /// reconstructs `TitlePromptScope` via `TitlePromptScope(rawValue:)`,
    /// so the C type never needs to cross the notification boundary —
    /// consumers stay decoupled from `GhosttyKit`, matching this router's
    /// role as the one place libghostty's C payloads get translated into
    /// Swift-native notifications.
    private static func handlePromptTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_prompt_title_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        let scope = (value == GHOSTTY_PROMPT_TITLE_SURFACE) ? "surface" : "tab"

        NotificationCenter.default.post(
            name: .ghosttyPromptTitle,
            object: surfaceView,
            userInfo: ["scope": scope]
        )
        return true
    }

    // MARK: - Helpers

    /// Extract the SurfaceView from an action target, if applicable.
    private static func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return nil }
            return GhosttyAppController.surfaceView(from: surface)
        default:
            return nil
        }
    }
}

// MARK: - NSWorkspace Extension

import UniformTypeIdentifiers

extension NSWorkspace {
    /// Returns the URL of the default text editor application.
    var defaultTextEditor: URL? {
        guard let contentType = UTType.plainText.identifier as CFString? else { return nil }
        return LSCopyDefaultApplicationURLForContentType(
            contentType,
            .all,
            nil
        )?.takeRetainedValue() as? URL
    }
}
