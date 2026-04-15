// SurfaceView.swift
// Calyx
//
// NSView subclass that hosts the Metal-rendered terminal surface.
// Implements full keyboard, mouse, and IME input handling.

@preconcurrency import AppKit
import GhosttyKit
@preconcurrency import QuartzCore
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SurfaceView")


// MARK: - SurfaceFocusHost

/// Delegate that receives notifications when a `SurfaceView` becomes the
/// active (focused) pane. Implemented by `SplitContainerView` so it can
/// propagate per-pane dimming state without reading any config or broadcasting
/// notifications.
@MainActor
protocol SurfaceFocusHost: AnyObject {
    func surfaceDidBecomeActive(_ surfaceView: SurfaceView)
}


// MARK: - SurfaceView

@MainActor
class SurfaceView: NSView {

    /// Weak back-reference to the container that should be told when this
    /// surface gains focus. Held weakly so the container owns the lifetime.
    weak var focusHost: (any SurfaceFocusHost)?

    /// The surface controller managing the ghostty surface for this view.
    var surfaceController: GhosttySurfaceController?

    /// The current title of the surface as set by the terminal.
    private(set) var title: String = ""

    /// The current working directory.
    private(set) var pwd: String?

    /// Whether the view is focused.
    private(set) var focused: Bool = false

    /// The previous pressure stage for force touch handling.
    private var prevPressureStage: Int = 0

    /// Marked text for IME input.
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()

    /// Called when ghostty sends a scrollbar update for this surface.
    var scrollbarUpdateHandler: ((GhosttySurfaceController.ScrollbarState) -> Void)?

    /// Cached cell size from the last CELL_SIZE action.
    /// Stored directly on the view so it survives the timing gap where
    /// surfaceController is nil during ghostty_surface_new.
    var cachedCellSize: NSSize = .zero

    /// Whether the surface is on a password input. Detected by ghostty's secure input action.
    var passwordInput: Bool = false {
        didSet {
            let input = SecureInput.shared
            let id = ObjectIdentifier(self)
            if passwordInput {
                input.setScoped(id, focused: focused)
                _hasSecureInput = true
            } else {
                input.removeScoped(id)
                _hasSecureInput = false
            }
        }
    }

    /// Nonisolated mirror of passwordInput for deinit cleanup.
    nonisolated(unsafe) private var _hasSecureInput = false

    /// Accumulator for text generated during a keyDown event.
    /// Non-nil when we are inside a keyDown handler.
    private var keyTextAccumulator: [String]? = nil

    // MARK: - Smooth Scrolling

    /// Accumulated pixel offset for smooth scrolling (mirrors ghostty's pending_scroll_y).
    private var smoothScrollAccumulator: CGFloat = 0

    /// Current visual pixel offset applied via CALayer transform.
    private(set) var smoothScrollPixelOffset: CGFloat = 0

    /// Debounce timer to reset offset after scrolling quiesces.
    private var smoothScrollResetTimer: Timer?

    /// Track mouseCaptured transitions for reset.
    private var lastMouseCapturedState: Bool = false

    /// Track scrollback availability for reset.
    private var lastHadScrollback: Bool = false

    /// Virtual momentum state for discrete (mouse wheel) smooth scrolling.
    /// Estimates scroll velocity from notch timing and generates synthetic pixel events.
    private var scrollVelocity: CGFloat = 0  // pixels per second (fb-pixel space)
    private var lastNotchTime: CFTimeInterval = 0
    private var virtualMomentumTimer: Timer?
    private static let momentumFrameInterval: CFTimeInterval = 1.0 / 120.0
    private static let momentumFriction: CGFloat = 0.94  // deceleration per frame
    private static let momentumStopThreshold: CGFloat = 10.0  // px/sec to stop
    private static let defaultRowDuration: CFTimeInterval = 0.15  // 150ms per row for single notch

    /// Observer for smooth scroll setting changes from Settings UI.
    private var smoothScrollSettingObserver: NSObjectProtocol?

    /// Timestamp of the last performKeyEquivalent event for command-key handling.
    private var lastPerformKeyEvent: TimeInterval?

    /// Whether a refresh is needed after the first real (non-zero) size is set.
    private var needsInitialRefresh = true

    // MARK: - NSView Overrides

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        MainActor.assumeIsolated {
            smoothScrollResetTimer?.invalidate()
            virtualMomentumTimer?.invalidate()
            if let obs = smoothScrollSettingObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
        trackingAreas.forEach { removeTrackingArea($0) }
        if _hasSecureInput {
            SecureInput.shared.removeScoped(ObjectIdentifier(self))
        }
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true

        // Replace the default layer with a configured CAMetalLayer for GPU rendering.
        let metalLayer = GhosttyMetalLayer()
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer = metalLayer

        // Observe smooth scroll setting changes to immediately reset active offsets.
        smoothScrollSettingObserver = NotificationCenter.default.addObserver(
            forName: .smoothScrollSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetSmoothScrollOffset()
            }
        }
    }

    /// Initialize the ghostty surface for this view.
    /// Should be called after the view has been added to a window.
    func initializeSurface(app: ghostty_app_t, baseConfig: ghostty_surface_config_s? = nil) {
        let config = baseConfig ?? GhosttyFFI.surfaceConfigNew()
        guard let controller = GhosttySurfaceController(app: app, baseConfig: config, view: self) else {
            logger.error("Failed to create surface controller")
            return
        }
        self.surfaceController = controller
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }

        // Update Metal layer content scale.
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()

        // Update ghostty content scale.
        surfaceController?.setContentScale(scale)

        // Set the display ID for vsync.
        if let screen = window.screen {
            surfaceController?.setDisplayID(screen.displayID ?? 0)
        }

        // Update tracking areas.
        updateTrackingAreas()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        guard let window else { return }

        // Update metal layer content scale to match window.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surfaceController else { return }

        // Detect X/Y scale factor and update surface.
        // Skip when frame is zero to avoid NaN scale (0/0).
        let fbFrame = convertToBacking(frame)
        guard frame.width > 0, frame.height > 0 else { return }
        let xScale = fbFrame.width / frame.width
        let yScale = fbFrame.height / frame.height
        surfaceController.setContentScale(x: xScale, y: yScale)

        // When scale changes, framebuffer size changes too.
        surfaceController.updateSize(
            width: UInt32(fbFrame.width),
            height: UInt32(fbFrame.height)
        )

        // Reset smooth scroll offset on scale change (pixel-to-point ratio invalidated).
        resetSmoothScrollOffset()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Skip zero-size updates to prevent Metal layer bad state.
        guard newSize.width > 0, newSize.height > 0 else { return }

        // Update the metal layer drawable size.
        let scaledSize = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = scaledSize
        }

        // Update ghostty surface size.
        surfaceController?.updateSize(
            width: UInt32(scaledSize.width),
            height: UInt32(scaledSize.height)
        )

        // Reset smooth scroll offset on resize (pixel math invalidated).
        resetSmoothScrollOffset()

        // Force re-render on the first real size after surface creation.
        if needsInitialRefresh, window != nil {
            needsInitialRefresh = false
            surfaceController?.refresh()
        }
    }

    override func updateTrackingAreas() {
        // Remove existing tracking areas.
        trackingAreas.forEach { removeTrackingArea($0) }

        // Add new tracking area covering the entire frame.
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    /// Reset the focus tracking state without notifying the controller.
    /// Used by SurfaceRegistry.pauseAll() to keep SurfaceView.focused in sync
    /// when the controller's focus is set directly.
    func resetFocusState() {
        focused = false
    }

    private func focusDidChange(_ newFocused: Bool) {
        guard focused != newFocused else { return }
        focused = newFocused
        surfaceController?.setFocus(newFocused)
        if passwordInput {
            SecureInput.shared.setScoped(ObjectIdentifier(self), focused: newFocused)
        }
        if newFocused {
            focusHost?.surfaceDidBecomeActive(self)
        }
    }

    // MARK: - Cursor Shape

    /// Update the cursor shape based on a ghostty mouse shape action.
    func updateCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            NSCursor.arrow.set()
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            NSCursor.openHand.set()
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            NSCursor.closedHand.set()
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            NSCursor.resizeUpDown.set()
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            NSCursor.resizeUpDown.set()
        default:
            break
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surfaceController else {
            interpretKeyEvents([event])
            return
        }

        guard surfaceController.surface != nil else {
            interpretKeyEvents([event])
            return
        }

        // Selection-edit: Delete/Backspace removes selected text.
        if !event.isARepeat,
           !hasMarkedText(),
           (event.keyCode == 0x33 || event.keyCode == 0x75),
           let surface = surfaceController.surface,
           GhosttyFFI.surfaceHasSelection(surface) {
            let reader = GhosttySurfaceSelectionReader(surface: surface)
            let dispatcher = GhosttyKeyDispatcher(surfaceController: surfaceController)
            if SelectionEditHandler.handleSelectionEdit(
                reader: reader, clipboard: nil, dispatcher: dispatcher,
                copyToClipboard: false
            ) { return }
        }

        // Translate mods for option-as-alt handling.
        let translationModsGhostty = EventTranslator.modifierFlags(
            from: surfaceController.keyTranslationMods(
                EventTranslator.translateModifiers(event.modifierFlags)
            )
        )

        // Construct the translation event with adjusted modifiers.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Set up text accumulator for IME.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        // Reset performKeyEquivalent tracking.
        self.lastPerformKeyEvent = nil

        // Interpret the key events through the input system (IME, dead keys, etc.).
        interpretKeyEvents([translationEvent])

        // Sync preedit state.
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            // We have composed text from the IME.
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // Normal key event.
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: EventTranslator.ghosttyCharacters(from: translationEvent),
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // Don't process modifier changes during IME composing.
        if hasMarkedText() { return }

        let mods = EventTranslator.translateModifiers(event.modifierFlags)

        // Determine if this is a press or release based on modifier state.
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Check for correct-side press.
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard focused else { return false }

        // Selection-edit: Cmd+X cuts selected text (takes precedence over bindings).
        if event.charactersIgnoringModifiers == "x",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           !event.isARepeat,
           let surfaceController, let surface = surfaceController.surface,
           GhosttyFFI.surfaceHasSelection(surface) {
            let reader = GhosttySurfaceSelectionReader(surface: surface)
            let clipboard = SystemClipboardWriter()
            let dispatcher = GhosttyKeyDispatcher(surfaceController: surfaceController)
            if SelectionEditHandler.handleSelectionEdit(
                reader: reader, clipboard: clipboard, dispatcher: dispatcher,
                copyToClipboard: true
            ) { return true }
        }

        // If the event matches a surface-level keybind, send it to keyDown.
        if let surfaceController, surfaceController.surface != nil {
            var ghosttyEvent = EventTranslator.translateKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                return surfaceController.keyIsBinding(ghosttyEvent)
            }
            if match {
                keyDown(with: event)
                return true
            }
        }

        // Handle special keys.
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-Return through.
            guard event.modifierFlags.contains(.control) else { return false }
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            keyDown(with: finalEvent!)
            return true

        case "/":
            // Treat C-/ as C-_ to avoid the NSBeep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "_",
                charactersIgnoringModifiers: "_",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            keyDown(with: finalEvent!)
            return true

        default:
            // Handle synthetic events with zero timestamp.
            if event.timestamp == 0 { return false }

            // Handle command/control key routing.
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }

            // Re-dispatch if this is a second pass through performKeyEquivalent.
            if let lastPerformKeyEvent, lastPerformKeyEvent == event.timestamp {
                self.lastPerformKeyEvent = nil
                let equivalent = event.characters ?? ""
                let finalEvent = NSEvent.keyEvent(
                    with: .keyDown,
                    location: event.locationInWindow,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: equivalent,
                    charactersIgnoringModifiers: equivalent,
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                )
                keyDown(with: finalEvent!)
                return true
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }
    }

    /// Internal helper to send a key event to the surface controller.
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surfaceController, surfaceController.surface != nil else { return false }

        var keyEvent = EventTranslator.translateKeyEvent(
            event,
            action: action,
            translationMods: translationEvent?.modifierFlags
        )
        keyEvent.composing = composing

        // For text, only encode UTF-8 if we don't have a single control character.
        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return surfaceController.sendKey(keyEvent)
            }
        } else {
            return surfaceController.sendKey(keyEvent)
        }
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
        surfaceController?.sendMousePressure(stage: 0, pressure: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        if surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: mods
        ) == true {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        if surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: mods
        ) == true {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_MIDDLE,
            mods: mods
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_MIDDLE,
            mods: mods
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let pos = convert(event.locationInWindow, from: nil)
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        // Add smoothScrollPixelOffset to compensate for visual shift: the rendered content
        // is in ghostty's coordinate space (content-space), so we ADD the offset to map
        // from screen-space click position to the logical content position.
        surfaceController?.sendMousePos(x: pos.x, y: frame.height - pos.y + smoothScrollPixelOffset, mods: mods)
    }

    override func mouseExited(with event: NSEvent) {
        // If mouse is being dragged, don't emit exit (we get drag events outside viewport).
        if NSEvent.pressedMouseButtons != 0 { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        surfaceController?.sendMousePos(x: -1, y: -1, mods: mods)
    }

    override func mouseMoved(with event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        // See mouseEntered for offset rationale.
        surfaceController?.sendMousePos(x: pos.x, y: frame.height - pos.y + smoothScrollPixelOffset, mods: mods)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    struct ScrollDelta: Equatable {
        var x: Double
        var y: Double
    }

    /// Adjust scroll deltas for the ghostty core.
    /// Precision scrolling (trackpad/Magic Mouse) gets a 2x multiplier
    /// to match Ghostty's responsive feel. All other deltas pass through raw.
    /// The ghostty core handles pixel-to-row conversion and remainder accumulation.
    static func adjustScrollDeltas(
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool
    ) -> ScrollDelta {
        var x = deltaX
        var y = deltaY
        if hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        return ScrollDelta(x: x, y: y)
    }

    // MARK: - Smooth Scroll Helpers

    struct SmoothScrollState: Equatable {
        var accumulator: CGFloat
        var pixelOffset: CGFloat
    }

    /// Mirror ghostty's scroll accumulation (Surface.zig:3423-3435) to compute sub-row pixel offset.
    static func computeSmoothScrollOffset(
        currentAccumulator: CGFloat,
        rawDeltaY: CGFloat,
        precisionMultiplier: CGFloat,
        cellHeight: CGFloat
    ) -> SmoothScrollState {
        guard cellHeight > 0 else {
            return SmoothScrollState(accumulator: 0, pixelOffset: 0)
        }
        let effectiveDelta = rawDeltaY * precisionMultiplier
        var newAccumulator = currentAccumulator + effectiveDelta
        if abs(newAccumulator) >= cellHeight {
            let rows = (newAccumulator / cellHeight).rounded(.towardZero)
            newAccumulator -= rows * cellHeight
        }
        return SmoothScrollState(accumulator: newAccumulator, pixelOffset: newAccumulator)
    }

    /// Clamp smooth scroll accumulator at scrollback boundaries.
    static func clampSmoothScrollAtBoundary(
        accumulator: CGFloat,
        isAtTop: Bool,
        isAtBottom: Bool
    ) -> CGFloat {
        if isAtTop && accumulator > 0 { return 0 }
        if isAtBottom && accumulator < 0 { return 0 }
        return accumulator
    }

    /// Ease-out interpolation for discrete scroll animation.
    static func discreteScrollEaseOut(progress: CGFloat) -> CGFloat {
        let t = max(0, min(1, progress))
        return 1 - (1 - t) * (1 - t)
    }

    override func scrollWheel(with event: NSEvent) {
        // When smooth scrolling is active for discrete events, we intercept and
        // drip-feed pixels to ghostty instead of sending the original tick event.
        if !event.hasPreciseScrollingDeltas && isSmoothScrollActive() {
            startVirtualMomentumScroll(ticks: event.scrollingDeltaY)
            return
        }

        let delta = Self.adjustScrollDeltas(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        )

        let mods = EventTranslator.translateScrollMods(event)
        surfaceController?.sendMouseScroll(x: delta.x, y: delta.y, mods: mods)

        // Smooth scrolling for trackpad (precision)
        guard isSmoothScrollActive() else {
            if smoothScrollPixelOffset != 0 { resetSmoothScrollOffset() }
            return
        }

        updateSmoothScrollOffset(rawDeltaY: event.scrollingDeltaY)

        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            scheduleResetTimer()
        } else {
            smoothScrollResetTimer?.invalidate()
            smoothScrollResetTimer = nil
        }
    }

    // MARK: - Smooth Scroll Instance Methods

    /// Whether smooth scrolling should be active.
    private func isSmoothScrollActive() -> Bool {
        // Check user setting (default true)
        guard UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool ?? true else { return false }
        guard let surfaceController else { return false }
        // Disabled when mouse is captured (mouse reporting / most alternate screen apps)
        if surfaceController.mouseCaptured { return false }
        // Disabled when no scrollback (alternate screen without mouse reporting)
        if let scrollbar = surfaceController.scrollbar,
           scrollbar.total <= scrollbar.len { return false }
        // Disabled before first scrollbar callback
        guard surfaceController.scrollbar != nil else { return false }
        return true
    }

    /// Cell height in points (cachedCellSize is in framebuffer pixels).
    private func cellHeightInPoints() -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2.0
        guard scale > 0 else { return 0 }
        return cachedCellSize.height / scale
    }

    /// Update smooth scroll offset for precision (trackpad) scrolling.
    /// The accumulator operates in the same unit space as ghostty (rawDelta * 2.0),
    /// with cachedCellSize.height (fb pixels) as the row threshold.
    /// The visual pixelOffset is then converted to points for the CALayer transform.
    private func updateSmoothScrollOffset(rawDeltaY: CGFloat) {
        // Use fb-pixel cell height so the accumulator wraps at the same row boundary as ghostty.
        let cellH = cachedCellSize.height
        let state = Self.computeSmoothScrollOffset(
            currentAccumulator: smoothScrollAccumulator,
            rawDeltaY: rawDeltaY,
            precisionMultiplier: 2.0,
            cellHeight: cellH
        )
        smoothScrollAccumulator = state.accumulator

        // Clamp at scrollback boundaries
        if let scrollbar = surfaceController?.scrollbar,
           scrollbar.total >= scrollbar.len {
            let isAtTop = scrollbar.offset == 0
            let isAtBottom = scrollbar.offset >= scrollbar.total - scrollbar.len
            smoothScrollAccumulator = Self.clampSmoothScrollAtBoundary(
                accumulator: smoothScrollAccumulator,
                isAtTop: isAtTop,
                isAtBottom: isAtBottom
            )
        }

        // Convert accumulator (fb-pixel space) to points for the visual transform.
        let scale = window?.backingScaleFactor ?? 2.0
        smoothScrollPixelOffset = smoothScrollAccumulator / scale
        applySmoothScrollTransform()
    }

    /// Reset smooth scroll offset to zero.
    func resetSmoothScrollOffset() {
        guard smoothScrollPixelOffset != 0 || smoothScrollAccumulator != 0 else { return }
        smoothScrollAccumulator = 0
        smoothScrollPixelOffset = 0
        smoothScrollResetTimer?.invalidate()
        smoothScrollResetTimer = nil
        stopVirtualMomentum()
        applySmoothScrollTransform()
    }

    /// Apply the current smooth scroll offset as a CALayer transform.
    private func applySmoothScrollTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if smoothScrollPixelOffset == 0 {
            layer?.transform = CATransform3DIdentity
        } else {
            layer?.transform = CATransform3DMakeTranslation(0, -smoothScrollPixelOffset, 0)
        }
        CATransaction.commit()
    }

    /// Schedule a debounce timer to reset offset after scrolling quiesces.
    private func scheduleResetTimer() {
        smoothScrollResetTimer?.invalidate()
        smoothScrollResetTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetSmoothScrollOffset()
            }
        }
    }

    /// Start or update virtual momentum scrolling from a discrete mouse wheel notch.
    /// Estimates velocity from the interval between notch events.
    private func startVirtualMomentumScroll(ticks: CGFloat) {
        let cellH = cachedCellSize.height
        guard cellH > 0 else { return }

        let now = CACurrentMediaTime()
        let timeSinceLastNotch = now - lastNotchTime
        let direction: CGFloat = ticks >= 0 ? 1 : -1

        if lastNotchTime > 0 && timeSinceLastNotch < 0.5 && timeSinceLastNotch > 0.001 {
            // Continuous scrolling: velocity from notch interval
            let notchVelocity = cellH / CGFloat(timeSinceLastNotch) * direction
            // Blend with current velocity for smoothness
            scrollVelocity = scrollVelocity * 0.3 + notchVelocity * 0.7
        } else {
            // Fresh start or long pause: use default speed
            scrollVelocity = cellH / CGFloat(Self.defaultRowDuration) * direction
        }

        lastNotchTime = now

        guard virtualMomentumTimer == nil else { return }
        virtualMomentumTimer = Timer.scheduledTimer(
            withTimeInterval: Self.momentumFrameInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickVirtualMomentum()
            }
        }
    }

    /// Generate one frame's worth of synthetic pixels based on current velocity.
    private func tickVirtualMomentum() {
        let pixelsThisFrame = scrollVelocity * CGFloat(Self.momentumFrameInterval)

        // Send to ghostty as precision scroll (same path as trackpad)
        let precisionMods = ghostty_input_scroll_mods_t(1)
        surfaceController?.sendMouseScroll(x: 0, y: Double(pixelsThisFrame), mods: precisionMods)

        // Feed through accumulator (rawDelta = amount / 2.0 to match adjustScrollDeltas 2x)
        updateSmoothScrollOffset(rawDeltaY: pixelsThisFrame / 2.0)

        // Decelerate
        scrollVelocity *= Self.momentumFriction

        // Stop when velocity is negligible
        if abs(scrollVelocity) < Self.momentumStopThreshold {
            stopVirtualMomentum()
            scheduleResetTimer()
        }
    }

    /// Stop virtual momentum scrolling.
    private func stopVirtualMomentum() {
        virtualMomentumTimer?.invalidate()
        virtualMomentumTimer = nil
        scrollVelocity = 0
    }

    /// Check scrollbar state transitions and reset smooth scroll if needed.
    func checkScrollbarStateTransitions() {
        guard let surfaceController else { return }

        let currentCaptured = surfaceController.mouseCaptured
        if currentCaptured && !lastMouseCapturedState {
            resetSmoothScrollOffset()
        }
        lastMouseCapturedState = currentCaptured

        let currentHasScrollback: Bool
        if let scrollbar = surfaceController.scrollbar {
            currentHasScrollback = scrollbar.total > scrollbar.len
        } else {
            currentHasScrollback = false
        }
        if !currentHasScrollback && lastHadScrollback {
            resetSmoothScrollOffset()
        }
        lastHadScrollback = currentHasScrollback
    }

    override func pressureChange(with event: NSEvent) {
        surfaceController?.sendMousePressure(stage: UInt32(event.stage), pressure: Double(event.pressure))

        // Force click detection: only trigger on initial transition to stage 2.
        guard prevPressureStage < 2 else { return }
        prevPressureStage = event.stage
        guard event.stage == 2 else { return }

        guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
        quickLook(with: event)
    }
}

// MARK: - NSTextInputClient

extension SurfaceView: @preconcurrency NSTextInputClient {

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surfaceController, let surface = surfaceController.surface else {
            return NSRange()
        }
        var text = ghostty_text_s()
        guard GhosttyFFI.surfaceReadSelection(surface, text: &text) else { return NSRange() }
        defer {
            var mutableText = text
            GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
        }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            logger.warning("Unknown marked text type: \(type(of: string))")
        }

        // If we're not in a keyDown event, update preedit immediately.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surfaceController, let surface = surfaceController.surface else { return nil }
        guard range.length > 0 else { return nil }

        var text = ghostty_text_s()
        guard GhosttyFFI.surfaceReadSelection(surface, text: &text) else { return nil }
        defer {
            var mutableText = text
            GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
        }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surfaceController else {
            return NSRect(origin: frame.origin, size: .zero)
        }

        let imePos = surfaceController.imePoint()
        let cellSize = surfaceController.cellSize

        // Ghostty coordinates are top-left origin; convert to bottom-left for AppKit.
        // SUBTRACT smoothScrollPixelOffset here (opposite sign from sendMousePos) because
        // this converts FROM content-space TO screen-space for IME candidate placement.
        let viewRect = NSRect(
            x: imePos.x,
            y: frame.height - imePos.y - smoothScrollPixelOffset,
            width: max(imePos.width, cellSize.width),
            height: max(imePos.height, cellSize.height)
        )

        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        guard let surfaceController else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // insertText means preedit is over.
        unmarkText()

        // If in a keyDown event, accumulate text.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Otherwise, send text directly.
        surfaceController.sendText(chars)
    }

    /// Prevents NSBeep for unhandled commands and handles command-key redispatch.
    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        // Silently consume to prevent NSBeep.
    }

    /// Sync the preedit state from markedText to the ghostty surface.
    fileprivate func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surfaceController else { return }

        if markedText.length > 0 {
            surfaceController.sendPreedit(markedText.string)
        } else if clearIfNeeded {
            surfaceController.sendPreedit(nil)
        }
    }
}

// MARK: - Menu Actions

extension SurfaceView {

    @IBAction func copy(_ sender: Any?) {
        surfaceController?.performAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        surfaceController?.performAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        surfaceController?.performAction("paste_from_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        surfaceController?.performAction("select_all")
    }

    @IBAction func splitRight(_ sender: Any) {
        surfaceController?.split(GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @IBAction func splitLeft(_ sender: Any) {
        surfaceController?.split(GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @IBAction func splitDown(_ sender: Any) {
        surfaceController?.split(GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @IBAction func splitUp(_ sender: Any) {
        surfaceController?.split(GHOSTTY_SPLIT_DIRECTION_UP)
    }

    @IBAction func performFindAction(_ sender: Any?) {
        surfaceController?.performAction("start_search")
    }
}

