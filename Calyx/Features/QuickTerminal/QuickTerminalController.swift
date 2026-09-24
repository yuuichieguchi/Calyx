import AppKit
import SwiftUI
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "QuickTerminalController"
)

@MainActor
class QuickTerminalController: NSObject, NSWindowDelegate {
    private(set) var visible: Bool = false
    private var previousApp: NSRunningApplication?
    private var quickWindow: QuickTerminalWindow?
    private var tab: Tab?
    private var splitContainerView: SplitContainerView?

    private var position: QuickTerminalPosition = .top
    private var animationDuration: Double = 0.2
    private var autoHide: Bool = true
    private var spaceBehavior: QuickTerminalSpaceBehavior = .move
    private var terminalSize: QuickTerminalSize = QuickTerminalSize()
    private var quickTerminalScreen: QuickTerminalScreen = .main
    nonisolated(unsafe) private var hiddenDock: HiddenDock?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigChange(_:)),
            name: .ghosttyConfigChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCloseSurfaceNotification(_:)),
            name: .ghosttyCloseSurface, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hiddenDock = nil
    }

    // MARK: - Public API

    /// Whether `surfaceID` is the Quick Terminal's pane.
    func ownsSurface(_ surfaceID: UUID) -> Bool {
        tab?.registry.allIDs.contains(surfaceID) == true
    }

    /// The Quick Terminal's split container, when it shows `surfaceID`.
    func splitContainer(owningSurface surfaceID: UUID) -> SplitContainerView? {
        ownsSurface(surfaceID) ? splitContainerView : nil
    }

    /// The Quick Terminal's window, when it shows `surfaceID`.
    func window(owningSurface surfaceID: UUID) -> NSWindow? {
        ownsSurface(surfaceID) ? quickWindow : nil
    }

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    #if DEBUG
    /// Test seam: overrides `visible` directly, mirroring
    /// `CalyxWindowController._setHasAppliedInitialSizeForTesting`'s
    /// override-seam shape — lets a test represent "the quick terminal
    /// is currently shown" without driving the real `animateIn()` (a
    /// real window/screen/animation, unsafe in this test host; see
    /// `ensureWindow()`/`animateIn()`'s own bodies). DO NOT use from
    /// production code.
    func _setVisibleForTesting(_ value: Bool) {
        visible = value
    }

    /// Test seam: mirrors `CalyxWindowController
    /// ._processCloseWindowHookForTesting`'s exact "hook right before
    /// the actually-unsafe-to-drive-in-tests real work" shape, for
    /// `requestHide()`'s eventual `animateOut()` call (real window
    /// animation, unsafe here — see `animateOut()`'s own body). `nil`
    /// (the default) leaves production behavior unchanged. DO NOT use
    /// from production code.
    var _requestHideHookForTesting: (() -> Void)?

    /// Test seam: directly installs `tab`, mirroring `_setVisibleForTesting`'s
    /// exact "override seam for a private stored property" shape — lets a
    /// test represent "the quick terminal currently owns a live surface"
    /// without driving the real `ensureSurface()` (a real ghostty app/
    /// surface, unsafe in this test host; see `SurfaceRegistry
    /// ._testInsert(view:id:)`'s own doc comment for the established
    /// fixture-only alternative `QuickTerminalControllerSurfaceClosedTests`
    /// uses instead). DO NOT use from production code.
    func _setTabForTesting(_ tab: Tab?) {
        self.tab = tab
    }

    /// Test seam: reads back `tab` (`private` in production), so a test
    /// can assert teardown actually cleared it without needing a
    /// production-facing accessor. DO NOT use from production code.
    var _tabForTesting: Tab? {
        tab
    }
    #endif

    /// GitHub issue #45 follow-on: `QuickTerminalWindow.calyxPerformClose(_:)`'s
    /// intended receiver — Cmd+W on the quick terminal must HIDE it
    /// (mirroring `autoHide`'s existing `animateOut()` on key resign),
    /// never destroy/close the window for real: `handleSurfaceClosed()`
    /// is the only path that tears down `tab`/`splitContainerView`, and
    /// this window's persistent-session surface (if any) must survive a
    /// Cmd+W exactly like it survives an autoHide.
    func requestHide() {
        guard visible else { return }
        #if DEBUG
        if let hook = _requestHideHookForTesting {
            hook()
            return
        }
        #endif
        animateOut()
    }

    // MARK: - Window Setup

    private func ensureWindow() -> QuickTerminalWindow {
        if let existing = quickWindow { return existing }

        let window = QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.collectionBehavior = spaceBehavior.collectionBehavior
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        quickWindow = window
        return window
    }

    private func ensureSurface() {
        guard tab == nil else { return }
        guard let app = GhosttyAppController.shared.app else {
            logger.error("Cannot create quick terminal surface: no ghostty app")
            return
        }

        let newTab = Tab()
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(quickWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        guard let surfaceID = newTab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create quick terminal surface")
            return
        }
        newTab.splitTree = SplitTree(leafID: surfaceID)
        self.tab = newTab

        let containerView = SplitContainerView(registry: newTab.registry)
        containerView.updateLayout(tree: newTab.splitTree)
        self.splitContainerView = containerView

        let hostView = QuickTerminalContentView(splitContainerView: containerView)
        let hostingView = NSHostingView(rootView: hostView)
        quickWindow?.contentView = hostingView
    }

    // MARK: - Animation

    private func animateIn() {
        let window = ensureWindow()

        guard !visible else { return }
        visible = true

        if !NSApp.isActive {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = frontApp
            }
        }

        ensureSurface()

        guard let screen = quickTerminalScreen.screen else {
            logger.warning("No screen available for quick terminal")
            visible = false
            return
        }

        position.setInitial(in: window, on: screen, terminalSize: terminalSize)

        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)

        if position.conflictsWithDock(on: screen) {
            if hiddenDock == nil { hiddenDock = HiddenDock() }
            hiddenDock?.hide()
        } else {
            hiddenDock = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen, terminalSize: terminalSize)
        }, completionHandler: {
            guard self.visible else {
                self.hiddenDock = nil
                return
            }
            window.level = .floating

            if let tab = self.tab,
               let surfaceID = tab.registry.allIDs.first,
               let surfaceView = tab.registry.view(for: surfaceID) {
                window.makeFirstResponder(surfaceView)
            }

            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        })
    }

    private func animateOut() {
        guard let window = quickWindow else { return }
        guard visible else { return }
        visible = false

        hiddenDock = nil

        guard let screen = window.screen ?? NSScreen.main else {
            window.orderOut(self)
            return
        }

        if let previousApp = self.previousApp {
            self.previousApp = nil
            if !previousApp.isTerminated {
                _ = previousApp.activate(options: [])
            }
        }

        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen, terminalSize: terminalSize)
        }, completionHandler: {
            window.orderOut(self)
        })
    }

    // MARK: - Config

    @objc private func handleConfigChange(_ notification: Notification) {
        quickWindow?.collectionBehavior = spaceBehavior.collectionBehavior
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard visible else { return }
            guard quickWindow?.attachedSheet == nil else { return }
            if NSApp.isActive {
                self.previousApp = nil
            }
            hiddenDock?.restore()
            if autoHide {
                animateOut()
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if visible {
                animateOut()
            }
        }
    }

    // MARK: - Surface Lifecycle

    /// Routes a ghostty-driven surface close to `processCloseSurface`,
    /// mirroring `CalyxWindowController.handleCloseSurfaceNotification`'s
    /// guard-and-route shape, minus its `deferOrRun` deferral
    /// (deliberately not replicated — see `handleSurfaceClosed()`'s doc
    /// comment). Registered against `.ghosttyCloseSurface` from `init`.
    /// Deliberately does NOT also observe `.ghosttyShowChildExited`
    /// — that notification only drives persistent-session reconnect,
    /// which is N/A here (see `handleSurfaceClosed()`'s doc comment).
    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        processCloseSurface(surfaceView: surfaceView)
    }

    /// Not `private` (mirrors `CalyxWindowController.processChildExited`'s
    /// own "Not `private`" doc comment): `QuickTerminalControllerSurfaceClosedTests`
    /// calls this directly instead of posting a real `.ghosttyCloseSurface`
    /// notification.
    ///
    /// Ownership guard: `SurfaceRegistry.id(for:)` is an identity scan
    /// over THIS controller's own registry only, so a close notification
    /// for another window's surface can never match and this stays a
    /// safe no-op for it. Also a safe no-op once `tab` is already `nil`
    /// — see `handleSurfaceClosed()`'s doc comment for why that matters
    /// for re-entrancy.
    func processCloseSurface(surfaceView: SurfaceView) {
        guard let tab = self.tab, tab.registry.id(for: surfaceView) != nil else { return }
        handleSurfaceClosed()
    }

    /// Tears down the quick terminal's own tab/surfaces and hides the
    /// window. This is the only path that does so — without it,
    /// `ensureSurface()`'s `guard tab == nil` holds a dead `tab` forever
    /// once its shell exits, and re-opening the quick terminal spawns no
    /// new shell.
    ///
    /// Ordering below is LOAD-BEARING — do not reorder:
    ///
    /// 1. `tab`/`splitContainerView` are captured into locals and
    ///    cleared to `nil` BEFORE the `destroySurface` loop runs, because
    ///    `destroySurface` → `GhosttySurfaceController.requestClose()`
    ///    can, for a real surface, synchronously re-post
    ///    `.ghosttyCloseSurface`: libghostty's `Surface.close` (in
    ///    `ghostty/src/apprt/embedded.zig`) invokes the close callback
    ///    inline, and that callback (`ghosttyCloseSurfaceCallback` in
    ///    `GhosttyApp.swift`) posts the notification synchronously, not
    ///    asynchronously. With `self.tab` already `nil` by the time
    ///    that re-entrant post reaches
    ///    `processCloseSurface` (via `handleCloseSurfaceNotification`),
    ///    its ownership guard fails and the re-entrant call is a clean
    ///    no-op instead of recursing back into this method.
    /// 2. The hide (`requestHide()`) runs LAST, and must NOT be deferred
    ///    into `animateOut()`'s completion handler: `animateOut()` has
    ///    two early returns (no `quickWindow` yet, already `!visible`)
    ///    that never reach the completion block, so teardown living
    ///    there would silently be skipped — reproducing the very bug
    ///    this fixes. Running it last here, unconditionally, also avoids
    ///    a window where `tab` is already `nil` but the window is still
    ///    visible, during which a `toggle()` could re-show a dead tab.
    /// 3. Calls `requestHide()` rather than an inline
    ///    `if visible { animateOut() }`: identical `guard visible` +
    ///    `animateOut()`, but this reuses the same
    ///    `_requestHideHookForTesting` seam Cmd+W's `requestHide()` call
    ///    already goes through.
    ///
    /// Does NOT detach/kill a persistent session: `ensureSurface()` uses
    /// the 2-arg `createSurface(app:config:)` overload, which never sets
    /// `config.command`, so a quick-terminal surface is never a
    /// persistent session in the first place (see
    /// `SessionSpawnOrigin.quickTerminal`'s doc comment in
    /// `SessionSpawnPlanner.swift` for this exclusion). Also does NOT
    /// replicate `CalyxWindowController`'s `deferOrRun`/`isConfirmingQuit`
    /// wrapper: that guards against session-snapshot races, and the
    /// quick terminal is never part of any snapshot
    /// (`QuickTerminalWindow.isRestorable` is `false`).
    ///
    /// Loops over every ID in `closingTab.registry.allIDs` below rather
    /// than only the one surface `processCloseSurface` resolved and
    /// verified ownership for -- safe today only because the quick
    /// terminal is single-surface by construction: `ensureSurface()`'s
    /// `guard tab == nil else { return }` permits at most one
    /// `createSurface` call per tab, and the resulting
    /// `SplitTree(leafID:)` is always a single leaf. Nothing in
    /// this class ever grows that tree: `.ghosttyNewSplit` (Cmd+D) is
    /// observed only by `CalyxWindowController`, whose
    /// `handleNewSplitNotification` guard chain resolves splits solely
    /// against its own `activeTab`, which can never be this class's
    /// standalone `tab` -- so Cmd+D silently no-ops here instead of
    /// adding a pane. If the quick terminal ever gains split support,
    /// this loop MUST be replaced with per-leaf teardown of just the
    /// closed surface, matching `CalyxWindowController
    /// .closeSurfaceAndCleanUp`'s `tab.splitTree.remove(surfaceID)` +
    /// single-`destroySurface` remove-one-leaf semantics -- destroying
    /// every sibling here would kill live panes instead.
    func handleSurfaceClosed() {
        guard let closingTab = tab else { return }
        let surfaceIDs = closingTab.registry.allIDs

        tab = nil
        splitContainerView = nil

        for surfaceID in surfaceIDs {
            closingTab.registry.destroySurface(surfaceID)
        }

        quickWindow?.contentView = nil
        requestHide()
    }

    // MARK: - Hidden Dock Helper

    private class HiddenDock {
        let previousAutoHide: Bool
        private var hidden: Bool = false

        init() {
            previousAutoHide = Dock.autoHideEnabled
        }

        deinit {
            restore()
        }

        func hide() {
            guard !hidden else { return }
            Dock.autoHideEnabled = true
            hidden = true
        }

        func restore() {
            guard hidden else { return }
            Dock.autoHideEnabled = previousAutoHide
            hidden = false
        }
    }
}
