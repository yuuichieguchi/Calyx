import AppKit
import SwiftUI
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxWindowController"
)

/// Reconnect-flashing-bug fix: narrow `#if DEBUG` override hook for
/// `CalyxWindowController.reconnectEstablishGraceMilliseconds`,
/// mirroring `SessionDaemonClientBoundTimeoutOverrides`'s identical
/// shape/reasoning exactly. `nil` (the default) means "use the
/// production value" (2000ms); a test sets a tiny, distinguishable
/// value so it can assert the grace-period wait's plumbing without
/// waiting out the real one. `nonisolated(unsafe)` is sound because the
/// only production reader is that computed property, and every test
/// that sets it resets it back to `nil` in its own `tearDown()`.
#if DEBUG
enum CalyxWindowControllerReconnectGraceOverrides {
    nonisolated(unsafe) static var reconnectEstablishGraceMilliseconds: UInt64?
}
#endif

/// What `performReconnect`'s grace `Task` learns from
/// `reconnectGraceProbe(sessionID:)` before calling `markEstablished`. Time
/// alone (the grace-period wait) plus surface identity alone is not
/// positive evidence the replacement is actually connected -- an attach
/// process that dies SLOWER than the grace window keeps resetting the
/// attempt count every cycle without ever advancing it, so `.giveUp` never
/// fires. `.established` requires the daemon to report the session
/// `Running` with at least one attached client; anything else, including a
/// probe failure, is `.notEstablished`.
enum ReconnectGraceProbeResult: Sendable, Equatable {
    case established
    case notEstablished
}

/// `GHOSTTY_ACTION_PROMPT_TITLE`'s `ghostty_action_prompt_title_e` payload
/// (`GHOSTTY_PROMPT_TITLE_SURFACE` / `_TAB`, ghostty.h) mapped onto a
/// Swift-native enum rather than passed through as the raw C type (contrast
/// `processCloseTab(tab:group:mode: ghostty_action_close_tab_mode_e)`,
/// which DOES take its C enum directly): v1 has no per-pane title UI
/// (`SurfacePropertyStore.title(for:)` is Cockpit's read-only `pane_list`
/// projection, not an editor), so `processPromptTitle` collapses both
/// cases onto the same tab-level rename — see that method's own doc
/// comment. Kept as a distinct type (not reused for anything else) so the
/// day a pane-level title editor exists, only `processPromptTitle`'s own
/// switch needs a new case, not every call site.
enum TitlePromptScope: String, Sendable {
    case surface
    case tab
}

/// GitHub issue #45 (see `NSWindow+CalyxClose.swift`'s header comment
/// for the full Cmd+W-routing root-cause writeup): the result of
/// `CalyxWindowController.closeFocusedTarget(tabID:content:focusedLeafID:)`,
/// the pure decision of which of a window's focused pane, tab, or the
/// window itself Cmd+W (`CalyxWindow.calyxPerformClose(_:)`) should
/// close:
///   - a `.terminal` tab with a non-nil `focusedLeafID` closes just
///     that pane (`.surface`) — matches ghostty's own default
///     `close_surface` semantics for a single Cmd+W press.
///   - a `.terminal` tab with NO focused leaf, or any non-terminal tab
///     (`.browser`/`.diff`, neither of which has a ghostty-surface
///     concept of "the focused pane"), closes the whole tab (`.tab`).
///   - no active tab at all (`tabID == nil` — a window with zero tabs)
///     closes the window itself (`.window`).
enum CloseFocusedTarget: Equatable {
    case surface(tabID: UUID, surfaceID: UUID)
    case tab(UUID)
    case window
}

/// Which groups the group context menu closes, relative to the
/// right-clicked group, in `windowSession.groups` order.
enum GroupCloseMode {
    case this
    case others
    case below
}

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowSession: WindowSession
    private var splitContainerView: SplitContainerView?

    /// The window's split container. One container shows whichever tab is
    /// active; MCP App docks park and reattach as leaves leave and return.
    var splitContainer: SplitContainerView? { splitContainerView }
    private var hostingView: NSHostingView<MainContentView>?
    private var wasOccluded = false
    /// Not `private`: `SessionCommandPaletteTests` reads
    /// `allCommands` directly (via `@testable import Calyx`) to assert
    /// `session.attach`/`session.detach`/`session.kill` are registered
    /// with the right `isAvailable` gate, matching the existing
    /// direct-query test style (`route(request:)`, `_testInsert`) this
    /// codebase favors over driving real UI. No other production code
    /// outside this file reads it.
    let commandRegistry = CommandRegistry()
    /// Chrome-style in-app recovery bar's per-window view-model
    /// (RecoveryBarModel.swift). Seeded from AppDelegate's CURRENT
    /// `hasPreservedSessionSnapshot` at construction time -- mirrors
    /// `session.recoverPreviousSession`'s own
    /// `(NSApp.delegate as? AppDelegate)?.hasPreservedSessionSnapshot`
    /// read above, so no window-controller construction call site in
    /// AppDelegate.swift needs to thread a seeded model through. Any
    /// later change (the async flag resolving, or a recovery attempt)
    /// is broadcast into this instance via
    /// `updateHasPreservedSessionSnapshot(_:)` -- see AppDelegate's
    /// `broadcastHasPreservedSessionSnapshotToRecoveryBars()`.
    let recoveryBarModel = RecoveryBarModel(
        hasPreservedSessionSnapshot: (NSApp.delegate as? AppDelegate)?.hasPreservedSessionSnapshot ?? false,
        onRestore: { (NSApp.delegate as? AppDelegate)?.recoverPreservedSession() }
    )
    private var closingTabIDs: Set<UUID> = []
    #if DEBUG
    /// Test seam: read-only observability
    /// into `closingTabIDs`, so tests can confirm a close path inserted
    /// a tab's id into it at the right point in its sequence, mirrors
    /// `SurfaceRegistry._testInsert`'s naming/gating convention. DO NOT
    /// use from production code.
    var _closingTabIDsForTesting: Set<UUID> { closingTabIDs }
    /// Test seam: number of `activateCurrentTab()` runs since this
    /// controller was created. DO NOT use from production code.
    var _activateCurrentTabCountForTesting = 0
    #endif
    private var focusRequestID: UInt64 = 0
    private var isRestoring = false
    /// Set once `applyInitialSize(_:)` has actually resized `window` (its
    /// guards passed and `window?.setContentSize(size)` ran), and never
    /// reset in production — see that method's own doc comment for why.
    /// Seeded from `restoring` in `init`, NOT hardcoded `false`: a
    /// restored/reattached window's size is already established by its
    /// persisted frame (or, for `AppDelegate.attachWindow`'s reattach-to-
    /// a-running-session case, by the same "not ghostty's job to size
    /// this window" reasoning) by the time `activateRestoredSession()`
    /// runs — so it must never ALSO apply ghostty's own initial size,
    /// including a LATER re-fire (font-size keybind, config hot-reload)
    /// after `isRestoring` has already flipped back to `false`. Without
    /// this seeding, only the guard's `!isRestoring` half would protect a
    /// restoring window, and only until the synchronous, one-shot
    /// `INITIAL_SIZE` action fired during its surface creation had come
    /// and gone -- exactly the class of gap `hasAppliedInitialSize` was
    /// introduced to close for a FRESH window, left open for a restored
    /// one otherwise. Every production caller of `restoring: true`
    /// (`AppDelegate.makeRestoringWindowController`, used by both
    /// `attachWindow` and `restoreWindow`) always eventually calls
    /// `activateRestoredSession()`, so this seeding is exercised on every
    /// real restore/reattach path, not just a hypothetical one.
    /// `_setHasAppliedInitialSizeForTesting(_:)` (`#if DEBUG` below) lets
    /// a test fixture that uses `restoring: true` purely to skip
    /// `setupTerminalSurface` (no live ghostty surface in this test host)
    /// while still wanting to represent a genuinely NEW, non-restored
    /// window override this seeded value.
    private var hasAppliedInitialSize = false
    var trackedFullScreen: Bool = false
    var preFullScreenFrame: NSRect? = nil
    /// Despite the
    /// name, this means only "THIS window's teardown is proceeding and
    /// must preserve tracking state (SessionSurfaceMap/tab.sessionRefs)
    /// into the snapshot instead of killing/detaching it", not "the app
    /// is quitting". `closeLastWindow` sets it even for a non-
    /// terminating close (a quick terminal keeps the app alive), so a
    /// caller that needs to know whether the whole APP is terminating
    /// must consult `isAppActuallyTerminating` instead (or in addition),
    /// never this flag alone. Every reader must agree with this
    /// meaning; see each reader's own doc comment.
    var isClosingForShutdown: Bool = false
    /// Injection point for `processCopyTitleToClipboard(tab:)`
    /// (`.ghosttyCopyTitleToClipboard` / `GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD`
    /// receiver) -- mirrors
    /// `SelectionEditHandler`'s own `ClipboardWriting` seam
    /// (`GhosttyBridge/SelectionEditHandler.swift`) rather than a new
    /// protocol, so `CalyxWindowControllerCopyTitleToClipboardTests` can
    /// reuse `SelectionEditHandlerTests.FakeClipboardWriter` instead of a
    /// second fake with an identical shape. Production default is a real
    /// `SystemClipboardWriter`, so nothing besides that test target ever
    /// needs to touch this property.
    var clipboardWriter: ClipboardWriting = SystemClipboardWriter()
    private var browserControllers: [UUID: BrowserTabController] = [:]
    private var diffStates: [UUID: DiffLoadState] = [:]
    private var diffTasks = KeyedTaskRegistry<UUID>()
    /// Repository discovery for the Changes sidebar. One at a time: a new
    /// discovery cancels the one in flight.
    private var discoveryTask: Task<Void, Never>?
    /// Identifies each discovery run. A new run cancels `discoveryTask`
    /// before creating its replacement, so the cancelled task still
    /// resumes and reaches its own exit points, racing the new task's.
    /// Each run captures the counter's value at start; only the exit whose
    /// captured value still matches this counter is the current run and
    /// may clear `windowSession.isGitRefreshing`.
    private var refreshGeneration = 0
    /// The scope of the discovery run in flight. A run that supersedes it
    /// inherits the scope, so a background event cannot narrow a refresh
    /// the user asked for into one that fetches nothing.
    private var pendingDiscoveryScope: GitSectionRefreshScope?
    /// Per-section status/log fetches, one at a time per section and in
    /// parallel across sections, so one large repository never delays the
    /// others and no two fetches write one section's commit list at once.
    private lazy var gitSectionRefreshes = GitSectionRefreshScheduler {
        [weak self] repoID, scope in
        await self?.performRepoRefresh(repoID: repoID, scope: scope)
    }
    /// One file-system monitor per displayed section. Alive only while the
    /// Changes sidebar is visible.
    private let gitChangesMonitorPool = GitChangesMonitorPool()
    /// Keeps the pool's requests in the order they were made, and gives the
    /// discovery that asked for a sync something to wait on before it reads
    /// the repositories those monitors watch.
    private var gitMonitorSyncTask: Task<Void, Never>?
    /// Set once the window is closing, which makes the Changes sidebar
    /// count as hidden: monitors stay retired and refreshes stop being
    /// requested however late an event arrives.
    private var isGitChangesTornDown = false
    /// How the displayed sections accounted for the panes' directories at
    /// the last discovery, so a pane moving inside a section it already has
    /// can skip discovery entirely.
    private var gitSeedCoverage = GitSeedCoverage()
    /// The file system's spelling of the panes' working directories, which
    /// is what those directories are compared against the sections by. Held
    /// across the prompts that report the same directory again, and trimmed
    /// by `gitSeedWorkDirs()` to the directories the panes are in.
    private let gitPathStandardizer = GitPathStandardizer()
    /// Herdr layer-2 screen-classification poll (see
    /// `startScreenPollTask`). Runs for the window's lifetime, cancelled
    /// in `windowWillClose`.
    private var screenPollTask: Task<Void, Never>?
    private var expandTasks = KeyedTaskRegistry<String>()
    /// Tracks
    /// `processChildExited`'s per-surface reconnect-decision `Task`,
    /// keyed by surface ID like `diffTasks`/`expandTasks` above, so
    /// `windowWillClose` can cancel it the same way it cancels every
    /// other per-window `Task` instead of leaving it as the sole
    /// untracked fire-and-forget one -- consistency/resource hygiene
    /// (this `Task`'s longer 15s `sessionStateBoundTimeoutSeconds` bound
    /// triples how long an orphaned one could linger).
    private var childExitedTasks = KeyedTaskRegistry<UUID>()
    #if DEBUG
    /// Test seam: read-only observability
    /// into `childExitedTasks`, mirroring `_closingTabIDsForTesting`'s
    /// naming/gating convention, so tests can await a tracked Task's
    /// `.value` and then confirm it removed its own entry. DO NOT use
    /// from production code.
    var _childExitedTasksForTesting: KeyedTaskRegistry<UUID> { childExitedTasks }
    #endif
    /// Reconnect-flashing-bug fix: `performReconnect`'s deferred-reset
    /// confirmation `Task` per replacement surface, keyed by the NEW
    /// surfaceID (not sessionID) so two different reconnects never
    /// collide on the same key. See `performReconnect`'s doc comment for
    /// why the `markEstablished(sessionID:)` reset itself is deferred
    /// behind a grace period rather than firing immediately. Cancelled
    /// and cleared in `windowWillClose` alongside `childExitedTasks`'s
    /// other siblings, per this file's established per-window `Task`-
    /// dictionary discipline.
    private var reconnectEstablishGraceTasks = KeyedTaskRegistry<UUID>()
    private var reviewStores: [UUID: DiffReviewStore] = [:]
    private var clipboardConfirmationController: ClipboardConfirmationController?
    private var composeOverlayTargetSurfaceID: UUID?
    /// Git badges for Mission Map's cards. Polls only while the map is
    /// shown: started by `showMissionMap()`, stopped by
    /// `dismissMissionMap(restoresFocus:)` and `windowWillClose`.
    private let missionMapGitPoller = MissionMapGitPoller()
    /// The Mission Map's Escape-catching view, handed back by
    /// `MissionMapKeyCatcherView` each time the map is shown. Weak: the
    /// view hierarchy owns it and drops it when the map closes.
    private weak var missionMapKeyCatcher: NSView?
    /// Mission Map's selected line, cleared on dismiss and by a tap on
    /// its popover.
    /// Not `private`: pinned by `CalyxWindowControllerMissionMapPopoverStackingTests`.
    let missionMapSelection = MissionMapSelection()
    /// The selected line's popover, drawn above the main hosting view
    /// (see `MissionMapPopoverHost` for why it is not in the SwiftUI
    /// tree). Shown only while the map is open with a line selected.
    let missionMapPopoverHost = MissionMapPopoverHost()
    /// Decides reconnect vs. close for this window's persistent-session
    /// surfaces on `GHOSTTY_ACTION_SHOW_CHILD_EXITED` (wired in
    /// `handleShowChildExitedNotification`). One instance per window
    /// controller is enough — decisions are keyed by surface UUID, and
    /// each surface only ever belongs to one window.
    private lazy var sessionReconnectCoordinator = SessionReconnectCoordinator(
        daemonClient: SessionDaemonClient.shared,
        surfaceMap: .shared,
        onDecision: { [weak self] surfaceID, decision in
            self?.handleSessionReconnectDecision(surfaceID: surfaceID, decision: decision)
        }
    )
    #if DEBUG
    /// Test seam: when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `performReconnect`, mirroring `AppDelegate
    /// ._createSurfaceWithPwdHookForTesting`'s exact style/reasoning (a
    /// real ghostty surface is confirmed unsafe to construct in this
    /// test host, see `AppDelegateAttachWindowTests`'s header comment
    /// for the hang this caused). Returns the UUID to report as the
    /// newly created replacement surface (simulating success), or
    /// `nil` to simulate surface-creation failure. `nil` (the default)
    /// leaves production behavior unchanged: every guard/step around
    /// this call in `performReconnect`, including the `markEstablished`
    /// timing under test, remains real, unmodified production code. DO
    /// NOT use from production code.
    var _performReconnectSurfaceCreationHookForTesting: (() -> UUID?)?

    /// Test seam, remote sessions: when non-nil, called
    /// with the synthesized `command` from inside `performReconnect`,
    /// immediately after it is computed and before `createReconnectSurface`
    /// is invoked. Mirrors `AppDelegate
    /// ._createSurfaceWithPwdCommandObserverForTesting`'s identical
    /// reasoning: `_performReconnectSurfaceCreationHookForTesting` only
    /// ever needs the resulting surfaceID, never the command string, so
    /// this is a second, independent observer rather than a change to
    /// that hook's signature. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _performReconnectCommandObserverForTesting: ((String?) -> Void)?

    /// Test seam: when non-nil, called INSTEAD of
    /// the real `SessionDaemonClient.shared.listAllBounded()` daemon query
    /// inside `reconnectGraceProbe(sessionID:)`, mirroring
    /// `_performReconnectSurfaceCreationHookForTesting`'s exact
    /// hook-first/real-fallback style. A throwing hook is fail-closed by
    /// construction: `reconnectGraceProbe(sessionID:)` treats it exactly
    /// like an explicit `.notEstablished` answer. `nil` (the default)
    /// leaves production behavior unchanged. DO NOT use from production
    /// code.
    var _reconnectGraceProbeForTesting: (() async throws -> ReconnectGraceProbeResult)?

    /// Test seam: read-only access to `sessionReconnectCoordinator`,
    /// mirroring `_childExitedTasksForTesting`'s/`_closingTabIDsForTesting`'s
    /// read-only-accessor convention, so a test can inspect
    /// `attemptCounts` (and, via `SessionReconnectCoordinator
    /// ._testSeedAttemptCount(sessionID:count:)`, seed it) without a
    /// live daemon round-trip. DO NOT use from production code.
    var _sessionReconnectCoordinatorForTesting: SessionReconnectCoordinator { sessionReconnectCoordinator }

    /// Test seam, remote sessions: when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `createManagedSurface`, mirroring
    /// `_performReconnectSurfaceCreationHookForTesting`'s/`AppDelegate
    /// ._createSurfaceWithPwdHookForTesting`'s exact intercept-right-
    /// before-the-unsafe-FFI-call style (a real ghostty surface is
    /// confirmed unsafe to construct in this test host, see
    /// `AppDelegateAttachWindowTests`'s header comment). Returns the
    /// UUID to report as the newly created surface (simulating success),
    /// or `nil` to simulate surface-creation failure. `nil` (the
    /// default) leaves production behavior unchanged: every guard/step
    /// around this call, including the `sessionRefs`/`SessionSurfaceMap`
    /// bookkeeping under test, remains real, unmodified production code.
    /// DO NOT use from production code.
    var _createManagedSurfaceHookForTesting: (() -> UUID?)?

    /// Test seam (issue #43, tab-create cwd): when non-nil, called with
    /// the pwd this call hands to `SurfaceRegistry.createSurface` --
    /// `explicitCwd` on the `.passthrough` branch below, `sessionCwd`
    /// on the `.persistent` branch (branch-dependent; a reader must not
    /// assume one meaning) -- immediately before that call, in BOTH
    /// branches, and BEFORE the existing `_createManagedSurfaceHookForTesting`
    /// short-circuit (that hook `return`s early, so an observer placed
    /// after it would never fire under a hook-installed test). A second,
    /// independent observer rather than a change to
    /// `_createManagedSurfaceHookForTesting`'s signature -- mirrors
    /// `_performReconnectCommandObserverForTesting`'s exact "observe
    /// right before the real (tracked, fire-and-forget) work; the real
    /// work still runs unmodified" style (see that property's own doc
    /// comment) and `AppDelegate
    /// ._createSurfaceWithPwdCommandObserverForTesting`'s identical
    /// precedent: `_createManagedSurfaceHookForTesting` is `(() ->
    /// UUID?)?` and has no way to observe a pwd, and every existing
    /// caller of it only ever needs the resulting surfaceID, so widening
    /// its arity would force every unrelated test file that installs it
    /// to churn. `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _createManagedSurfacePwdObserverForTesting: ((String?) -> Void)?

    /// Test seam, remote sessions: when non-nil,
    /// called with `(sessionID, host)` immediately before
    /// `killSessionIfPersistent`'s `SessionKillTracker.track` dispatch --
    /// `host` is `nil` for a local kill, non-nil for a remote kill.
    /// `SessionDaemonClient.shared` is a real singleton, so a controller-
    /// level test cannot otherwise distinguish "kill(id:) was dispatched"
    /// from "killRemote(host:sessionID:) was dispatched" by inspecting
    /// the daemon client itself; this seam mirrors
    /// `_performReconnectCommandObserverForTesting`'s exact "observe
    /// right before the real (tracked, fire-and-forget) work; the real
    /// work still runs unmodified" style. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _killSessionIfPersistentRouteObserverForTesting: ((String, String?) -> Void)?

    /// Test seam, herdr auto-close: when non-nil,
    /// called with `surfaceID` alongside `processChildExited`'s real
    /// close action for a herdr-hosted OR a herdr-bridged surface --
    /// mirrors `_killSessionIfPersistentRouteObserverForTesting`'s exact
    /// "observe right alongside the real (tracked) work; the real work
    /// still runs unmodified" style, NOT a replacement/bypass hook like
    /// `_openHerdrAttachTabSurfaceCreationHookForTesting`: closing a
    /// `_testInsert`-only fake surface through `closeSurfaceAndCleanUp`
    /// is already exercised safely by `SessionReconnectGiveUpTests`, so
    /// no FFI-avoidance bypass is needed here. `nil` (the default)
    /// leaves production behavior unchanged.
    ///
    /// Implementation contract: inside
    /// `processChildExited`, immediately after resolving `surfaceID`,
    /// consult `HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted:
    /// HerdrHostedSurfaces.shared.contains(surfaceID), isBridgeSurface:
    /// HerdrPaneRegistry.shared.isBridgeSurface(surfaceID))`. On `true`,
    /// fire this observer with `surfaceID`, close the pane SYNCHRONOUSLY
    /// through the same `findTabAndGroup` + `closeSurfaceAndCleanUp`
    /// shape `closeDeadPersistentSessionSurface` uses (default
    /// `killSessions: true` is safe here: `SessionSurfaceMap.shared
    /// .sessionID(for:)` is always `nil` for either kind of herdr
    /// surface, so `SessionCloseKillPolicy.shouldKill`'s `hasSession`
    /// gate is always `false` and no kill call ever fires -- herdr's
    /// child process is already dead, nothing left to signal), and
    /// `return` BEFORE the `childExitedTasks` Task insert below: a herdr
    /// decision needs no daemon round-trip, so it must never reach
    /// `sessionReconnectCoordinator` at all. On `false`, fall through to
    /// the existing (unchanged) reconnect-coordinator path. DO NOT use
    /// from production code.
    var _herdrHostedAutoCloseObserverForTesting: ((UUID) -> Void)?
    #endif
    /// Surface UUIDs currently being destroyed as part of
    /// `performReconnect`'s surface swap (populated right before, and
    /// cleared right after, its `destroySurface` call). Consulted by
    /// `killSessionIfPersistent` via `SessionCloseKillPolicy` — defense
    /// in depth on top of `performReconnect`'s own ordering (re-pointing
    /// `SessionSurfaceMap` before destroying the old surface) — so a
    /// `destroySurface` call that synchronously re-enters
    /// `handleCloseSurfaceNotification` (ghostty's `close_surface`
    /// callback fires from inside `requestClose()`) can never self-kill
    /// the very session `performReconnect` is reconnecting to.
    private var reconnectingSurfaceIDs: Set<UUID> = []

    /// A `.childExited` notification,
    /// `.decision`, or `.closeSurface`
    /// notification deferred by `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision`/`handleCloseSurfaceNotification`
    /// while `AppDelegate.isConfirmingQuit` was `true`, instead of being
    /// dropped outright. A dropped `SHOW_CHILD_EXITED` notification has
    /// no recovery path (one-shot, never re-emitted, see ghostty's
    /// `Surface.zig:1202`), a dropped `.giveUp` decision silently
    /// downgrades the pane's eventual keypress-close to kill semantics
    /// instead of the intended detach, and a
    /// dropped `close_surface` relies entirely on the user pressing a
    /// key to self-heal. Drained by
    /// `drainDeferredReconnectEvents()`, scheduled on a fresh MainActor
    /// turn once the gate clears (see `handleConfirmingQuitDidEnd`'s doc
    /// comment).
    private enum DeferredReconnectEvent {
        case childExited(surfaceView: SurfaceView)
        case decision(surfaceID: UUID, decision: SessionReconnectDecision)
        case closeSurface(surfaceView: SurfaceView)
    }
    private var deferredReconnectEvents: [DeferredReconnectEvent] = []

    /// True while THIS window's own
    /// teardown (`isClosingForShutdown`) or the app itself
    /// (`isAppActuallyTerminating`) is shutting down. Consulted by the
    /// deferred-event drain and its handlers so a decision is never
    /// replayed, or a fresh one processed, on top of quit teardown that
    /// already preserved tracking state into the snapshot, see
    /// `windowWillClose`'s own preserve branch.
    private var isShuttingDown: Bool {
        isClosingForShutdown || isAppActuallyTerminating
    }

    /// True once the app is genuinely quitting, not just this window
    /// closing. A thin forward to `AppDelegate.isApplicationTerminating`,
    /// the one canonical "is the app actually terminating" query: the
    /// per-window `isClosingForShutdown` flag alone is not a safe "app
    /// terminating" discriminator (`closeLastWindow` sets it for every
    /// close that empties this one window, terminating or not, see that
    /// flag's own doc comment). Used by `windowWillClose`'s destroy loop
    /// to decide whether to run the normal kill/detach close policy (app
    /// not terminating) or preserve tracking state into the snapshot
    /// exactly as before (app terminating).
    private var isAppActuallyTerminating: Bool {
        (NSApp.delegate as? AppDelegate)?.isApplicationTerminating ?? false
    }

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    /// This window's active tab's display title -- backs the app-wide
    /// approval panel's header (`ApprovalBannerView.targetLabel`) for a
    /// window-agnostic (nil `targetSurfaceID`) request when this window
    /// is `AppDelegate.currentWindowController`. Not `private`: read
    /// directly from `ApprovalPanelContentView.glassWrapped(request:)`
    /// through `ApprovalPanelLayout.hostWindowController`.
    var activeTabDisplayTitle: String? {
        activeTab?.displayTitle
    }

    #if DEBUG
    /// Test seam: replaces `restoreTerminalFocusAfterApproval(reclaimKey:)`'s
    /// real AppKit `makeKey()`/`restoreFocus()` calls entirely when set. `nil`
    /// (the default) leaves production behavior unchanged. DO NOT use
    /// from production code.
    var _restoreTerminalFocusAfterApprovalHookForTesting: (() -> Void)?
    #endif

    /// Called by `AppDelegate.restoreTerminalFocusAfterApproval(targetSurfaceID:)`
    /// once an approval decision resolves (or a question's free-text
    /// field loses relevance) while this window is the one that should
    /// regain terminal focus.
    ///
    /// The floating approval panel can itself become key (its free-text
    /// field taking first responder), which leaves this window non-key
    /// even while its own terminal should get focus back. `reclaimKey`
    /// (`AppDelegate`'s own `_approvalPanelController?.panel?.isKeyWindow
    /// == true`, computed at call time) tells this window whether the
    /// panel actually held key status just before the decision -- key is
    /// reclaimed only in that case, `makeKey()`, never
    /// `makeKeyAndOrderFront`, so Calyx is never brought to the front by
    /// an approval decision made without it, and only when the window is
    /// actually showable (visible, not miniaturized, on the current
    /// Space): reclaiming key status for a minimized or off-Space window
    /// would silently deminiaturize/Space-switch out from under the user.
    /// `restoreFocus()`'s own `attemptFocusRestore` guards on
    /// `window?.isKeyWindow`, so when `reclaimKey` is false and this
    /// window was never key to begin with, it is simply a no-op.
    ///
    /// When this window cannot actually take key (minimized, off-Space,
    /// or otherwise not showable), this method does nothing further: no
    /// other window is made key on this window's behalf. AppKit's own
    /// key-window restoration decides once the panel orders out.
    func restoreTerminalFocusAfterApproval(reclaimKey: Bool) {
        #if DEBUG
        if let hook = _restoreTerminalFocusAfterApprovalHookForTesting {
            hook()
            return
        }
        #endif
        if reclaimKey, let window, window.isVisible, !window.isMiniaturized, window.isOnActiveSpace {
            window.makeKey()
        }
        if case .terminal = activeTab?.content {
            restoreFocus()
        }
    }

    /// The tab (in any group) whose `SurfaceRegistry` owns `surfaceID`'s
    /// own `displayTitle`, or nil if no tab in this window does -- backs
    /// the app-wide approval panel's header for a surface-targeted
    /// request (`ApprovalBannerView.targetLabel`).
    func tabDisplayTitle(owningSurface surfaceID: UUID) -> String? {
        windowSession.groups.tabAndGroup(owningSurface: surfaceID)?.tab.displayTitle
    }

    /// Gate shared by the `session.detach`/`session.kill` command
    /// palette entries: `true` only when the focused pane (the active
    /// tab's `splitTree.focusedLeafID`) has a tracked `SessionRef` —
    /// an ordinary (non-persistent) pane, or no focused leaf at all,
    /// has nothing to detach or kill.
    private var focusedPaneHasTrackedSession: Bool {
        guard let tab = activeTab, let leafID = tab.splitTree.focusedLeafID else { return false }
        return tab.sessionRefs[leafID] != nil
    }

    private var activeBrowserController: BrowserTabController? {
        guard let tab = activeTab, case .browser = tab.content else { return nil }
        return browserController(for: tab.id)
    }

    var activeBrowserControllerForExternal: BrowserTabController? {
        activeBrowserController
    }

    private var activeDiffState: DiffLoadState? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return diffStates[tab.id]
    }

    private var activeDiffSource: DiffSource? {
        guard let tab = activeTab, case .diff(let source) = tab.content else { return nil }
        return source
    }

    private var activeDiffReviewStore: DiffReviewStore? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return reviewStores[tab.id]
    }

    private var totalReviewCommentCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.reduce(0) { $0 + $1.comments.count }
    }

    private var reviewFileCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.count
    }

    private func browserController(for tabID: UUID) -> BrowserTabController? {
        if let existing = browserControllers[tabID] { return existing }
        guard let tab = windowSession.groups.tabAndGroup(tabID: tabID)?.tab,
              case .browser(let url) = tab.content else { return nil }
        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tabID] = controller
        return controller
    }

    func browserController(forExternal tabID: UUID) -> BrowserTabController? {
        browserController(for: tabID)
    }

    #if DEBUG
    /// Test seam: registers `controller` as tabID's live BrowserTabController
    /// without driving a full navigation through the real
    /// BrowserView/WebKit stack, so windowSnapshot()'s live-browserURL-
    /// override branch (which reads `browserControllers`) can be
    /// exercised directly against a URL that deliberately differs from
    /// the tab's configured `content` URL. Mirrors
    /// `_closingTabIDsForTesting`'s naming/gating convention. DO NOT use
    /// from production code.
    func _setBrowserControllerForTesting(tabID: UUID, controller: BrowserTabController) {
        browserControllers[tabID] = controller
    }
    #endif

    private func wireBrowserCallbacks(controller: BrowserTabController, tab: Tab) {
        controller.browserView.onTitleChanged = { [weak tab] title in
            tab?.title = title
        }
        controller.browserView.onURLChanged = { [weak self, weak tab] url in
            guard let tab else { return }
            tab.content = .browser(url: url)
            self?.requestSave()
        }
    }

    // MARK: - Initialization

    /// The default content size for a brand-new (non-restored, non-quick-
    /// terminal) window, before ghostty's own `window-width`/`window-height`
    /// config (applied via `applyPendingInitialSizeFromFirstSurface()`) or a
    /// persisted frame takes over. Shared by this file's own `convenience
    /// init` below and `AppDelegate.attachWindow`'s `makeRestoringWindowController`
    /// call, which previously duplicated this literal. NOT the QuickTerminal's
    /// 800x400 default (`QuickTerminalController.swift`), a visually and
    /// behaviorally distinct window that just happens to share this window's
    /// width.
    static let defaultContentSize = NSSize(width: 800, height: 600)

    /// `initialHost` (remote sessions): forwarded to
    /// `setupTerminalSurface(host:)` for this window's first tab --
    /// see that method's own doc comment.
    convenience init(windowSession: WindowSession, initialHost: String? = nil) {
        let window = CalyxWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window, windowSession: windowSession, initialHost: initialHost)
    }

    init(window: NSWindow, windowSession: WindowSession, restoring: Bool = false, initialHost: String? = nil) {
        self.windowSession = windowSession
        self.isRestoring = restoring
        // A restored/reattached window's size is already spoken for (see
        // `hasAppliedInitialSize`'s own doc comment) -- seed it alongside
        // `isRestoring` so it stays true for this window's whole life,
        // not just until `isRestoring` flips back to `false`.
        self.hasAppliedInitialSize = restoring
        super.init(window: window)
        window.delegate = self
        setupCommandRegistry()
        setupUI()
        if !restoring {
            setupTerminalSurface(host: initialHost)
            // Must run before window.center() below: a fresh window's
            // initial content size (from ghostty's window-width/
            // window-height config, applied here) can differ materially
            // from the 800x600 `contentRect` this controller's
            // `convenience init` constructed `window` with.
            // `NSWindow.setContentSize(_:)` (inside applyInitialSize)
            // does not itself re-center, so centering BEFORE this ran
            // (the previous order) could leave a brand-new window
            // slightly off-center once its real size took effect.
            applyPendingInitialSizeFromFirstSurface()
        }
        // For a restoring window, nothing above this point in the
        // `if !restoring` branch runs, so this executes at exactly the
        // same point relative to `setupUI()` as before -- unchanged
        // timing for that path, matching whatever frame the caller
        // already set up via `contentRect:`.
        window.center()
        registerNotificationObservers()
        startScreenPollTask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupCommandRegistry() {
        commandRegistry.register(PaletteCommand(id: "tab.new", title: "New Tab", shortcut: "Cmd+T", category: "Tabs") { [weak self] in
            self?.createNewTab()
        })
        commandRegistry.register(PaletteCommand(id: "tab.close", title: "Close Tab", shortcut: "Cmd+Opt+W", category: "Tabs") { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.closeTab(id: tab.id)
        })
        commandRegistry.register(PaletteCommand(id: "tab.next", title: "Next Tab", shortcut: "Cmd+Shift+]", category: "Tabs") { [weak self] in
            self?.selectNextTab(nil)
        })
        commandRegistry.register(PaletteCommand(id: "tab.previous", title: "Previous Tab", shortcut: "Cmd+Shift+[", category: "Tabs") { [weak self] in
            self?.selectPreviousTab(nil)
        })
        commandRegistry.register(PaletteCommand(id: "group.new", title: "New Group", shortcut: "Ctrl+Shift+N", category: "Groups") { [weak self] in
            self?.createNewGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.close", title: "Close Group", shortcut: "Ctrl+Shift+W", category: "Groups") { [weak self] in
            self?.closeActiveGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.next", title: "Next Group", shortcut: "Ctrl+Shift+]", category: "Groups") { [weak self] in
            self?.switchToNextGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.previous", title: "Previous Group", shortcut: "Ctrl+Shift+[", category: "Groups") { [weak self] in
            self?.switchToPreviousGroup()
        })
        commandRegistry.register(PaletteCommand(id: "view.sidebar", title: "Toggle Sidebar", shortcut: "Cmd+Opt+S", category: "View") { [weak self] in
            self?.toggleSidebar()
        })
        commandRegistry.register(PaletteCommand(id: "view.fullscreen", title: "Toggle Full Screen", shortcut: "Ctrl+Cmd+F", category: "View") { [weak self] in
            self?.window?.toggleFullScreen(nil)
        })
        commandRegistry.register(PaletteCommand(id: "window.new", title: "New Window", shortcut: "Cmd+N", category: "Window") {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindow()
            }
        })
        commandRegistry.register(PaletteCommand(id: "edit.find", title: "Find in Terminal", shortcut: "Cmd+F", category: "Edit") { [weak self] in
            guard let controller = self?.focusedController else { return }
            controller.performAction("start_search")
        })
        commandRegistry.register(PaletteCommand(
            id: "edit.compose",
            title: "Compose Input",
            shortcut: "Cmd+Shift+E",
            category: "Edit"
        ) { [weak self] in
            self?.toggleComposeOverlay()
        })
        commandRegistry.register(PaletteCommand(
            id: "view.missionMap",
            title: "Mission Map",
            shortcut: "Cmd+Shift+M",
            category: "View"
        ) { [weak self] in
            self?.toggleMissionMap()
        })
        commandRegistry.register(PaletteCommand(id: "browser.open", title: "Open Browser Tab", category: "Browser") { [weak self] in
            self?.promptAndOpenBrowserTab()
        })
        commandRegistry.register(PaletteCommand(id: "browser.back", title: "Browser Back", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goBack()
        })
        commandRegistry.register(PaletteCommand(id: "browser.forward", title: "Browser Forward", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goForward()
        })
        commandRegistry.register(PaletteCommand(id: "browser.reload", title: "Browser Reload", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.reload()
        })
        commandRegistry.register(PaletteCommand(id: "git.showChanges", title: "Show Git Changes", category: "Git") { [weak self] in
            self?.windowSession.showSidebar = true
            self?.setSidebarMode(.changes)
            self?.refreshHostingView()
        })
        commandRegistry.register(PaletteCommand(id: "git.refresh", title: "Refresh Git Changes", category: "Git") { [weak self] in
            self?.refreshGitSidebar(trigger: .manualRefresh)
        })
        commandRegistry.register(PaletteCommand(id: "cli.install", title: "Install CLI to PATH", category: "System") {
            let appPath = Bundle.main.bundlePath
            let cliSource = "\(appPath)/Contents/Resources/bin/calyx"
            let cliDest = "/usr/local/bin/calyx"

            // Check if source exists
            guard FileManager.default.fileExists(atPath: cliSource) else {
                let alert = NSAlert()
                alert.messageText = "CLI Not Found"
                alert.informativeText = "CLI binary not found in app bundle. Please rebuild the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            // Use AppleScript to create symlink with admin privileges
            let script = "do shell script \"ln -sf '\(cliSource)' '\(cliDest)'\" with administrator privileges"
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Installation Failed"
                    alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "CLI Installed"
                    alert.informativeText = "The 'calyx' command is now available. Run 'calyx browser --help' to get started."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        })
        commandRegistry.register(PaletteCommand(id: "tab.jumpToUnread", title: "Jump to Unread Tab", shortcut: "Cmd+Shift+U", category: "Tabs", isAvailable: { [weak self] in
            guard let self else { return false }
            return self.windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }) { [weak self] in
            self?.jumpToMostRecentUnreadTab()
        })
        commandRegistry.register(PaletteCommand(
            id: "review.submitAll",
            title: "Submit All Review Comments",
            category: "Git",
            isAvailable: { [weak self] in (self?.reviewFileCount ?? 0) >= 2 }
        ) { [weak self] in
            self?.submitAllDiffReviews()
        })
        commandRegistry.register(PaletteCommand(
            id: "session.attach",
            title: "Session Browser…",
            category: "Sessions"
        ) {
            SessionBrowserWindowController.shared.showBrowser()
        })
        commandRegistry.register(PaletteCommand(
            id: "session.detach",
            title: "Detach Session",
            category: "Sessions",
            isAvailable: { [weak self] in self?.focusedPaneHasTrackedSession ?? false }
        ) { [weak self] in
            self?.closeFocusedSessionSurface(killSessions: false)
        })
        commandRegistry.register(PaletteCommand(
            id: "session.kill",
            title: "Kill Session",
            category: "Sessions",
            isAvailable: { [weak self] in self?.focusedPaneHasTrackedSession ?? false }
        ) { [weak self] in
            self?.closeFocusedSessionSurface(killSessions: true)
        })
        // A herdr row click opens that workspace NATIVELY
        // (SessionBrowserWindowController.createHerdrWorkspace(_:)/
        // .attachHerdrWorkspace(_:), one Calyx tab per opened workspace);
        // this command keeps a TUI-attach tab available from the
        // palette. `isAvailable`
        // reuses `SessionBrowserModel.showHerdrSection` (the only
        // synchronous, already-cached "herdr detected with a live
        // socket" signal in this codebase -- it reflects the Session
        // Browser's own 1s poll, so this command reads unavailable until
        // that browser has been opened at least once; re-resolving the
        // binary or probing a socket per palette keystroke would be
        // strictly worse, see `SessionBrowserModel.defaultHerdrAvailability()`'s
        // own doc comment on why even a binary-resolution MISS is hopped
        // off the main thread there). Single-session simplification: this
        // action always targets `herdrRows.first` -- exactly
        // one herdr row is ever attachable at a time; a multi-session
        // picker is out of scope.
        commandRegistry.register(PaletteCommand(
            id: "herdr.attachTUI",
            title: "Attach herdr TUI",
            category: "Sessions",
            isAvailable: { SessionBrowserWindowController.shared.model.showHerdrSection }
        ) {
            guard let row = SessionBrowserWindowController.shared.model.herdrRows.first,
                  let herdrBin = HerdrBinaryResolver().resolve() else { return }
            let command = HerdrAttachCommandSynthesizer.attachCommand(herdrBin: herdrBin, socketPath: row.info.id)
            (NSApp.delegate as? AppDelegate)?.openHerdrAttachTab(command: command, title: row.attachTabTitle)
        })
        // Gated on `SessionSettings.persistentSessionsEnabled` -- unlike
        // `session.attach` (ungated: it only opens the browser) and
        // `session.detach`/`session.kill` (gated on an existing tracked
        // pane) -- because this command's entire purpose is spawning a
        // brand-new persistent session, exactly what
        // `SessionSpawnPlanner.plan(for:)`'s own guard already gates.
        commandRegistry.register(PaletteCommand(
            id: "session.newRemote",
            title: "New Remote Session…",
            category: "Sessions",
            isAvailable: { SessionSettings.persistentSessionsEnabled }
        ) { [weak self] in
            self?.presentSessionsBrowserForRemoteHostPicker()
        })
        // Gated on AppDelegate.hasPreservedSessionSnapshot, the
        // synchronous cache set by restoreSession()'s preserve branches
        // (and initialized at launch from any file preserved by a
        // previous run) -- mirrors every other AppDelegate-level query
        // this codebase already reads via `NSApp.delegate as? AppDelegate`
        // (isApplicationTerminating, hasPreservedSessionSnapshot, etc.).
        commandRegistry.register(PaletteCommand(
            id: "session.recoverPreviousSession",
            title: "Recover Previous Session",
            category: "Sessions",
            isAvailable: { (NSApp.delegate as? AppDelegate)?.hasPreservedSessionSnapshot ?? false }
        ) {
            (NSApp.delegate as? AppDelegate)?.recoverPreservedSession()
        })
    }

    /// `session.newRemote`'s handler: reuses the existing Sessions
    /// browser panel, where remote host candidates surface via
    /// `SessionBrowserModel.remoteHostCandidates` -- no new visual
    /// components needed.
    private func presentSessionsBrowserForRemoteHostPicker() {
        SessionBrowserWindowController.shared.showBrowser()
    }

    /// Turns a chosen remote host into the `SessionSpawnContext` the
    /// spawn path (`SessionSpawnPlanner`) consumes. `origin == .tab`:
    /// a remote session created via the palette is still a new TAB at
    /// the surface-creation level -- `SessionSpawnOrigin` has no
    /// dedicated palette-specific case.
    func remoteSessionSpawnContext(forHost host: String) -> SessionSpawnContext {
        SessionSpawnContext(host: host, origin: .tab)
    }

    private func setupUI() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        // Create the split container (shared across tabs — we swap its tree)
        let container = SplitContainerView(registry: SurfaceRegistry())
        container.onTargetRatioChange = { [weak self] firstChildID, secondChildID, targetRatio, direction, splitRect in
            self?.handleDividerDrag(
                firstChildFirstLeafID: firstChildID,
                secondChildFirstLeafID: secondChildID,
                targetRatio: targetRatio,
                direction: direction,
                splitRect: splitRect
            )
        }
        container.onActiveLeafChange = { [weak self] leafID in
            self?.activeTab?.splitTree.focusedLeafID = leafID
            self?.requestSave()
        }
        self.splitContainerView = container

        let mainContent = buildMainContentView()
        let hosting = NSHostingView(rootView: mainContent)
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)
        self.hostingView = hosting

        // The AppKit side installs no titlebar material of its own: CalyxWindow already
        // makes the window transparent (titlebarAppearsTransparent, isOpaque = false,
        // .fullSizeContentView), and MainContentView's root glass sheet (a .background
        // with .ignoresSafeArea()) supplies the fill under the titlebar strip.
    }

    /// `host` (remote sessions): threaded straight into
    /// `createManagedSurface(host:)` for this window's very first tab --
    /// `nil` (every existing caller's shape) leaves this unchanged, a
    /// local surface exactly as before this parameter existed. Lets
    /// `AppDelegate.spawnRemoteSessionTab(host:)` open a fresh window
    /// whose sole initial tab is the remote session directly, instead
    /// of a spurious local tab that would need a second, wasteful
    /// teardown.
    private func setupTerminalSurface(host: String? = nil) {
        guard let tab = activeTab else {
            logger.error("No active tab during setup")
            return
        }

        guard let app = GhosttyAppController.shared.app,
              let window = self.window else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            explicitCwd: tab.pwd, sessionFallbackCwd: nil, origin: .tab, host: host
        ) else {
            logger.error("Failed to create initial surface")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Create a SplitContainerView bound to this tab's registry
        rebuildSplitContainer()
        updateLayout()

        if let surfaceView = tab.registry.view(for: surfaceID) {
            window.makeFirstResponder(surfaceView)
        }
    }

    // MARK: - Session Persistence

    /// Calyx's own reconstruction of the directory libghostty would inherit
    /// for a new surface: the source pane's own live OSC 7 report, degrading
    /// to the owning tab's last-known `pwd` when that pane hasn't reported
    /// one yet (e.g. a snapshot-restored pane before its first OSC 7, or any
    /// surface created before `SurfacePropertyStore.startObserving()`).
    private func livePaneCwd(of surfaceID: UUID?, in tab: Tab?) -> String? {
        surfaceID.flatMap { SurfacePropertyStore.shared.cwd(for: $0) } ?? tab?.pwd
    }

    /// The established grid of the currently focused terminal pane. A new
    /// full-size tab or group uses the same viewport, or a larger one when
    /// the focused pane is split, so this is a safe initial grid for the new
    /// shell. Without it, embedded Ghostty starts the command at its fixed
    /// 800x600 bootstrap grid and resizes only after AppKit installs the view.
    private func focusedTerminalGridSize() -> SessionInitialGridSize? {
        guard let tab = activeTab,
              let surfaceID = tab.splitTree.focusedLeafID,
              let surface = tab.registry.controller(for: surfaceID)?.surface else {
            return nil
        }
        let size = GhosttyFFI.surfaceSize(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return SessionInitialGridSize(columns: size.columns, rows: size.rows)
    }

    /// Applies `SessionSpawnPlanner`'s decision for a freshly-created
    /// terminal surface. `.passthrough` (the default — feature off, or
    /// `origin == .quickTerminal`) creates the surface exactly as
    /// before this feature existed, via `explicitCwd` — every existing
    /// call site's pre-feature `pwd` argument, unchanged, so the OFF
    /// path has zero observable difference. `.persistent` creates it
    /// with the synthesized attach command instead, using `sessionCwd`
    /// (below), and records the new session in `tab.sessionRefs`
    /// (persisted into `TabSnapshot.sessionRefs` at save time) and
    /// `SessionSurfaceMap.shared` (so `/agent-event` routing, the
    /// close=kill path below, and `SessionReconnectCoordinator` can all
    /// find it later).
    ///
    /// Issue #43 root cause: cwd used to arrive as THREE independently-
    /// settable parameters (`passthroughPwd`, `spawnCwd`, `inheritedCwd`)
    /// -- every pre-fix call site hardcoded `passthroughPwd: nil`
    /// unconditionally while threading its real cwd only into
    /// `spawnCwd`, so an explicit override wired the `.persistent`
    /// branch but silently never reached `.passthrough`, the default (an
    /// MCP `tab_create` cwd override was dropped whenever persistent
    /// sessions were off). Collapsed here to two, combined ONCE into a
    /// single `sessionCwd = explicitCwd ?? sessionFallbackCwd ??
    /// NSHomeDirectory()` fed to BOTH branches below -- a caller can no
    /// longer wire one branch and forget the other, because neither
    /// branch has its own independent cwd parameter left to forget.
    ///
    /// - `explicitCwd`: an explicit directive, honored by both branches
    ///   when non-nil. `nil` means "no directive": `.passthrough` passes
    ///   it straight through as `pwd` (i.e. leaves ghostty's
    ///   `working_directory` unset), so libghostty inherits the FOCUSED
    ///   surface's own LIVE OSC 7 pwd
    ///   (`window-inherit-working-directory`'s default `true`,
    ///   `ghostty/src/apprt/surface.zig`'s `newConfig`) -- the correct
    ///   behavior for an ordinary override-less Cmd+T, more accurate
    ///   than anything Calyx could resolve independently.
    /// - `sessionFallbackCwd`: deliberately ignored by `.passthrough`,
    ///   which has real FFI-level inheritance to fall back on instead.
    ///   Exists only to give a `.persistent` plan a concrete `--cwd`
    ///   when there is no explicit directive -- the spawned
    ///   `calyx-session attach --create` command's cwd is fixed at spawn
    ///   time, with nothing equivalent to libghostty's live inheritance.
    ///
    /// `performCreateNewTab`/`performSplit`/`performCreateNewGroup` all pass
    /// `sessionFallbackCwd: livePaneCwd(of:in:)` rather than `tab.pwd`
    /// directly: turning persistent sessions on must not change which
    /// directory a new tab or split opens in relative to `.passthrough`,
    /// which gets the FOCUSED pane's live OSC 7 cwd straight from
    /// libghostty, not Calyx's own possibly-stale `Tab.pwd` snapshot --
    /// with multiple panes in a tab, `tab.pwd` can be a sibling pane's
    /// directory. (Calyx does have a surface-level pwd getter now --
    /// `SurfacePropertyStore.cwd(for:)`, fed by the same
    /// `.ghosttySetPwd` notification `Tab.pwd` is -- `livePaneCwd`
    /// prefers it for exactly this reason.)
    ///
    /// `host` (remote sessions): the remote ssh host to spawn this
    /// surface's session against, `nil` for every existing call site
    /// (unchanged, all still local). Passed into the
    /// `SessionSpawnContext` this method builds; the `SessionRef` it
    /// stores reads the resulting plan's OWN `host` (not this parameter
    /// directly -- see `SessionSpawnPlannerHostPropagationTests` for why
    /// the plan itself is the source of truth for a caller applying it).
    ///
    /// Not `private` (mirrors `closeAllTabsInGroup(id:)`'s/
    /// `processChildExited`'s/`handleSessionReconnectDecision`'s own
    /// identical "un-privated for direct test access" precedent):
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests` drives
    /// this directly with a dummy `ghostty_app_t` pointer, exactly like
    /// `AppDelegateRestoreRemoteSessionTests` drives `restoreTabSurfaces`.
    func createManagedSurface(
        tab: Tab,
        app: ghostty_app_t,
        config: ghostty_surface_config_s,
        explicitCwd: String?,
        sessionFallbackCwd: String?,
        origin: SessionSpawnOrigin,
        host: String? = nil,
        initialGridSize: SessionInitialGridSize? = nil
    ) -> UUID? {
        let sessionCwd = explicitCwd ?? sessionFallbackCwd ?? NSHomeDirectory()
        let context = SessionSpawnContext(
            cwd: sessionCwd,
            host: host,
            origin: origin,
            initialGridSize: initialGridSize
        )
        switch SessionSpawnPlanner.plan(for: context) {
        case .passthrough:
            #if DEBUG
            _createManagedSurfacePwdObserverForTesting?(explicitCwd)
            if let hook = _createManagedSurfaceHookForTesting {
                return hook()
            }
            #endif
            return tab.registry.createSurface(app: app, config: config, pwd: explicitCwd)
        case .persistent(let sessionID, let command, let planHost):
            #if DEBUG
            _createManagedSurfacePwdObserverForTesting?(sessionCwd)
            if let hook = _createManagedSurfaceHookForTesting {
                guard let surfaceID = hook() else { return nil }
                tab.sessionRefs[surfaceID] = SessionRef(sessionID: sessionID, host: planHost)
                SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: surfaceID)
                return surfaceID
            }
            #endif
            guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: sessionCwd, command: command) else {
                return nil
            }
            tab.sessionRefs[surfaceID] = SessionRef(sessionID: sessionID, host: planHost)
            SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: surfaceID)
            return surfaceID
        }
    }

    /// Explicit-close half of the close=kill / quit=detach contract: a
    /// user-initiated pane/tab close ends the underlying calyx-session
    /// too (rather than leaving it running headless forever), and drops
    /// its now-stale `SessionSurfaceMap` entry and `tab.sessionRefs`
    /// entry so neither routing nor the next snapshot still reference a
    /// leaf that no longer exists. Called from `closeTab(id:)`,
    /// `closeActiveGroup()`, `closeAllTabsInGroup(id:)`, and
    /// `handleCloseSurfaceNotification` right before/alongside
    /// `SurfaceRegistry.destroySurface(_:)` — including reentrant calls
    /// `destroySurface` triggers synchronously via ghostty's
    /// `close_surface` callback, which is exactly why the actual kill
    /// decision is delegated to `SessionCloseKillPolicy` rather than
    /// just checking `hasSession`: this method is reachable,
    /// unconditionally, from two unsafe reentrant paths:
    /// `performReconnect` (which destroys the OLD surface to make room
    /// for the reconnected one, so must not self-kill) and
    /// `windowWillClose`/quit teardown (must detach, not kill, so the
    /// session survives to be reattached on next launch; `windowWillClose`
    /// passes its own already-computed `isAppActuallyTerminating` as
    /// `isTerminating`, the app-wide discriminator `AppDelegate
    /// .applicationShouldTerminate`/`applicationWillTerminate` set, NOT
    /// the per-window `isClosingForShutdown` that `markAllControllersClosingForShutdown()`
    /// sets, see `closeSurfaceAndCleanUp`'s doc comment below for why
    /// the two flags must not be conflated).
    ///
    /// `isTerminating` is REQUIRED, with no default: `tearDownSurfaces`
    /// passes its own `isTerminating`
    /// parameter straight through for `closeTab`/`closeActiveGroup`/
    /// `closeAllTabsInGroup` (always `false`) and `windowWillClose`
    /// (its own already-computed discriminator); `closeSurfaceAndCleanUp`
    /// passes the app-wide `isAppActuallyTerminating` explicitly too
    /// (not this window's own
    /// `isClosingForShutdown`, which a non-terminating
    /// close can also set, see that method's own doc comment), so
    /// the outer "is the app actually terminating" gate and this policy
    /// call always visibly agree, with no caller left relying on an
    /// implicit default.
    /// `host` (remote sessions): read from `tab.sessionRefs[surfaceID]
    /// ?.host` BEFORE this method's own `tab.sessionRefs[surfaceID] = nil`
    /// clears the entry two lines later -- exactly like `performReconnect`'s
    /// own identical read of the same storage (see that method's doc
    /// comment). `nil` routes through the LOCAL-only `kill(id:)`;
    /// non-nil routes through `killRemote(host:
    /// sessionID:)` instead, so closing a remote pane no longer silently
    /// orphans the calyx-session running entirely on the remote host.
    private func killSessionIfPersistent(tab: Tab, surfaceID: UUID, isTerminating: Bool) {
        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        guard SessionCloseKillPolicy.shouldKill(
            hasSession: sessionID != nil,
            isTerminating: isTerminating,
            isReconnectSwap: reconnectingSurfaceIDs.contains(surfaceID)
        ), let sessionID else {
            return
        }
        let host = tab.sessionRefs[surfaceID]?.host
        SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        tab.sessionRefs[surfaceID] = nil
        sessionReconnectCoordinator.markClosed(sessionID: sessionID)
        #if DEBUG
        _killSessionIfPersistentRouteObserverForTesting?(sessionID, host)
        #endif
        SessionKillTracker.track {
            if let host {
                await SessionDaemonClient.shared.killRemote(host: host, sessionID: sessionID)
            } else {
                await SessionDaemonClient.shared.kill(id: sessionID)
            }
        }
    }

    /// `session.detach` command palette action's per-surface half:
    /// drops `surfaceID`'s `SessionSurfaceMap`/`tab.sessionRefs`
    /// tracking exactly like `killSessionIfPersistent` above, but never
    /// calls `daemonClient.kill` -- the underlying calyx-session keeps
    /// running headless, reattachable later from the session browser or
    /// a future restore. A no-op for a surface with no tracked session.
    ///
    /// Routes through `SessionCloseKillPolicy.shouldDetach` exactly like
    /// `killSessionIfPersistent` routes
    /// through `shouldKill`, rather than reasoning
    /// about reentrancy/teardown state ad hoc. During quit/last-window-close
    /// teardown, `tab.sessionRefs` must survive untouched into the
    /// snapshot `applicationWillTerminate`/`windowWillClose` save, not be
    /// cleared here first: without that, a `.giveUp`/`session.detach`
    /// teardown racing Cmd+Q could clear `SessionRef` before that
    /// snapshot is built, permanently losing this session's tracking
    /// even though it survives in the daemon.
    ///
    /// Unlike `killSessionIfPersistent`,
    /// takes no `isTerminating` parameter: this always reads the app-wide
    /// `isAppActuallyTerminating` directly instead, matching what
    /// `closeSurfaceAndCleanUp` passes `killSessionIfPersistent`'s own
    /// `isTerminating` explicitly below (reading
    /// this window's own `isClosingForShutdown` here instead
    /// would misread an ordinary non-terminating close of one of several
    /// open windows as app termination and wrongly detach rather than kill,
    /// see `closeSurfaceAndCleanUp`'s doc comment for why the two flags
    /// must not be conflated).
    private func detachSessionIfPersistent(tab: Tab, surfaceID: UUID) {
        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        guard SessionCloseKillPolicy.shouldDetach(
            hasSession: sessionID != nil,
            isTerminating: isAppActuallyTerminating,
            isReconnectSwap: reconnectingSurfaceIDs.contains(surfaceID)
        ), let sessionID else {
            return
        }
        SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        tab.sessionRefs[surfaceID] = nil
        sessionReconnectCoordinator.markClosed(sessionID: sessionID)
    }

    /// Shared per-tab teardown loop for
    /// `closeTab`/`closeActiveGroup`/`closeAllTabsInGroup`/`windowWillClose`,
    /// replacing what used to be each one's own separate copy of "kill
    /// every persistent surface, then destroy it". `isTerminating` is
    /// passed straight through to `killSessionIfPersistent`: an explicit tab/
    /// group close always passes `false` (never mid-quit at this point,
    /// `isClosingForShutdown` is still unset here even for the last-
    /// window case, see `closeLastWindow`'s own doc comment for when it
    /// gets set); `windowWillClose` passes its own already-computed
    /// `isAppActuallyTerminating`, so its outer gate and this loop's
    /// inner kill decision always read the same value.
    private func tearDownSurfaces(in tab: Tab, isTerminating: Bool) {
        for surfaceID in tab.registry.allIDs {
            // Same wiring as `closeSurfaceAndCleanUp`'s own
            // (see that method's own comment) -- this loop is the OTHER
            // Calyx-side path a herdr-bridged leaf can disappear through
            // (a whole tab/group/window closing at once, rather than one
            // pane at a time), and any reentrant `closeSurfaceAndCleanUp`
            // call `destroySurface` below triggers is a no-op for a tab
            // this loop already claimed in `closingTabIDs` -- so this is
            // the only place that fires for THIS path, never a double.
            if HerdrPaneRegistry.shared.isBridgeSurface(surfaceID) {
                (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator?.handleCalyxSurfaceClosed(surfaceID: surfaceID)
            }
            killSessionIfPersistent(tab: tab, surfaceID: surfaceID, isTerminating: isTerminating)
            tab.registry.destroySurface(surfaceID)
        }
    }

    /// Shared close body that can empty the last managed window. There
    /// are three call sites: `closeTab`, `closeSurfaceAndCleanUp`, and
    /// `closeTabs(_:removingEmptyGroups:)`. The group/batch entry points
    /// (`closeActiveGroup`, `closeAllTabsInGroup`, `closeTabs(_:in:)`,
    /// both `closeGroups` overloads) all reach it through that core.
    /// Sets `isClosingForShutdown` eagerly, then closes the window.
    /// `isClosingForShutdown` must be set BEFORE `window?.close()`:
    /// without this, `windowDidExitFullScreen`'s stale-snapshot guard
    /// (which checks `isClosingForShutdown`) is dead code during this
    /// teardown, and the fullscreen tracking flags/frame get incorrectly
    /// cleared mid-close. Emptying the last
    /// managed window this way does not terminate the app (see
    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), so
    /// there is nothing left to confirm or mark confirmed here: AppKit's
    /// own default `windowShouldClose` (this controller does not
    /// override it) just closes the window.
    private func closeLastWindow() {
        isClosingForShutdown = true
        window?.close()
    }

    /// True when `tab` is the sole tab of the sole group of this window
    /// AND has exactly one pane (a single, unsplit leaf): closing
    /// this one pane empties the tab, the group, and the window all at
    /// once. Used by `handleReconnectGiveUp` (alone, with no
    /// `&& AppDelegate.closingWouldTerminate` condition; the close-path
    /// confirm-quit prompt this once gated is gone, see that
    /// method's own doc comment) to decide whether to leave the pane in
    /// place instead of closing it.
    private func isLastPaneEverywhere(tab: Tab, group: TabGroup) -> Bool {
        !tab.splitTree.isEmpty && !tab.splitTree.isSplit
            && group.tabs.count == 1
            && windowSession.groups.count == 1
    }

    /// `session.detach`/`session.kill` command palette actions' shared
    /// implementation: tears down only the focused pane's surface, via
    /// the same single-surface `closeSurfaceAndCleanUp` path
    /// `closeDeadPersistentSessionSurface` uses, instead of the whole
    /// tab: `closeTab(id:)` destroys EVERY surface in the active tab even
    /// though `focusedPaneHasTrackedSession` only checks the ONE focused
    /// pane, so invoking either command on a
    /// multi-pane tab through `closeTab` would silently tear down
    /// untracked sibling panes too.
    /// A no-op if there is no active tab, no focused leaf, or the
    /// focused leaf has no tracked session (re-checked here, not just
    /// via the palette's `isAvailable` gate, in case focus moved to an
    /// untracked pane between the palette listing this command and the
    /// user invoking it).
    ///
    /// Closing the last pane/tab/group/window
    /// does not terminate the app, so there is nothing left to confirm
    /// here.
    ///
    /// Inserts `tab.id` into
    /// `closingTabIDs` before tearing the surface down (mirroring
    /// `closeTab`'s own insert-then-remove-on-cancel pattern), so a
    /// synchronous reentrant `close_surface` callback for this same tab,
    /// firing from inside `closeSurfaceAndCleanUp`'s own `destroySurface`
    /// call below, hits that method's reentrancy guard instead of
    /// tearing the tab down a second time. `closeSurfaceAndCleanUp` is
    /// told `callerAlreadyClaimedClosingTabIDs: true` since this method
    /// (not that one) owns the insert/remove lifecycle for this call.
    private func closeFocusedSessionSurface(killSessions: Bool) {
        guard let group = windowSession.activeGroup,
              let tab = group.activeTab,
              let surfaceID = tab.splitTree.focusedLeafID,
              tab.sessionRefs[surfaceID] != nil else { return }
        guard !closingTabIDs.contains(tab.id) else { return }

        closingTabIDs.insert(tab.id)

        closeSurfaceAndCleanUp(
            tab: tab, group: group, surfaceID: surfaceID,
            killSessions: killSessions,
            callerAlreadyClaimedClosingTabIDs: true
        )
        closingTabIDs.remove(tab.id)
    }

    // MARK: - Content View Building

    private func buildMainContentView() -> MainContentView {
        return MainContentView(
            windowSession: windowSession,
            commandRegistry: commandRegistry,
            splitContainerView: splitContainerView ?? SplitContainerView(registry: SurfaceRegistry()),
            activeBrowserController: activeBrowserController,
            activeDiffState: activeDiffState,
            activeDiffSource: activeDiffSource,
            activeDiffReviewStore: activeDiffReviewStore,
            recoveryBarModel: recoveryBarModel,
            sidebarMode: Binding(
                get: { [weak self] in self?.windowSession.sidebarMode ?? .tabs },
                set: { [weak self] in self?.setSidebarMode($0) }
            ),
            gitSidebarState: buildGitSidebarViewState(),
            onTabSelected: { [weak self] tabID in self?.switchToTab(id: tabID) },
            onGroupSelected: { [weak self] groupID in self?.switchToGroup(id: groupID) },
            onNewTab: { [weak self] in self?.createNewTab() },
            onNewGroup: { [weak self] in self?.createNewGroup() },
            onCloseTab: { [weak self] tabID in self?.closeTab(id: tabID) },
            onCloseOtherTabs: { [weak self] tabID in
                self?.closeTabs(relativeTo: tabID, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)
            },
            onCloseTabsToTheRight: { [weak self] tabID in
                self?.closeTabs(relativeTo: tabID, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT)
            },
            onShowAllTabs: { [weak self] in self?.showMissionMap() },
            onGroupRenamed: { [weak self] in self?.requestSave() },
            onTabRenamed: { [weak self] in self?.requestSave() },
            onToggleSidebar: { [weak self] in self?.toggleSidebar() },
            onDismissCommandPalette: { [weak self] in self?.dismissCommandPalette() },
            onWorkingFileSelected: { [weak self] repoID, entry in
                self?.handleWorkingFileSelected(repoID: repoID, entry: entry)
            },
            onCommitFileSelected: { [weak self] repoID, entry in
                self?.handleCommitFileSelected(repoID: repoID, entry: entry)
            },
            onRefreshGitStatus: { [weak self] in self?.refreshGitSidebar(trigger: .manualRefresh) },
            onLoadMoreCommits: { [weak self] repoID in self?.loadMoreCommits(repoID: repoID) },
            onExpandCommit: { [weak self] repoID, hash in
                self?.expandCommit(repoID: repoID, hash: hash)
            },
            onToggleGitRepoSection: { [weak self] repoID in self?.toggleGitRepoSection(repoID: repoID) },
            onRetryGitRepoSection: { [weak self] repoID in self?.retryGitRepoSection(repoID: repoID) },
            onSelectRefFilter: { [weak self] repoID, selection in
                self?.setGitRefSelection(repoID: repoID, selection: selection)
            },
            onSidebarWidthChanged: { [weak self] width in self?.windowSession.sidebarWidth = width },
            onCollapseToggled: { [weak self] in self?.requestSave() },
            onCloseAllTabsInGroup: { [weak self] groupID in self?.closeAllTabsInGroup(id: groupID) },
            onCloseOtherGroups: { [weak self] groupID in self?.closeGroups(relativeTo: groupID, mode: .others) },
            onCloseGroupsBelow: { [weak self] groupID in self?.closeGroups(relativeTo: groupID, mode: .below) },
            onGroupColorChanged: { [weak self] in self?.requestSave() },
            onMoveTab: { [weak self] groupID, fromIndex, toIndex in
                guard let self,
                      let group = self.windowSession.groups.first(where: { $0.id == groupID })
                else { return }
                group.moveTab(fromIndex: fromIndex, toIndex: toIndex)
                self.refreshHostingView()
                self.requestSave()
            },
            paneTitle: { SurfacePropertyStore.shared.title(for: $0) },
            paneCwd: { SurfacePropertyStore.shared.cwd(for: $0) },
            onSidebarDragCommitted: { [weak self] in self?.requestSave() },
            onSubmitReview: { [weak self] in
                guard let self, let tab = self.activeTab else { return }
                self.submitDiffReview(tabID: tab.id)
            },
            onDiscardReview: { [weak self] in
                guard let self, let tab = self.activeTab else { return }
                if let store = self.reviewStores[tab.id] {
                    store.clearAll()
                    self.refreshHostingView()
                }
            },
            onSubmitAllReviews: { [weak self] in
                self?.submitAllDiffReviews()
            },
            onDiscardAllReviews: { [weak self] in
                self?.discardAllDiffReviews()
            },
            onComposeOverlaySend: { [weak self] text in self?.sendComposeText(text) ?? false },
            onDismissComposeOverlay: { [weak self] in self?.dismissComposeOverlay() },
            onComposeOverlayEscapePressed: { [weak self] in self?.forwardEscapeToTerminal() },
            missionMapGitPoller: missionMapGitPoller,
            missionMapSelection: missionMapSelection,
            missionMapPanes: { [weak self] in self?.missionMapPanes() ?? [] },
            missionMapCardOffsets: { [weak self] in self?.missionMapCardOffsets() ?? [:] },
            onMissionMapFocusSurface: { [weak self] surfaceID in self?.focusSurfaceFromMissionMap(surfaceID) },
            onDismissMissionMap: { [weak self] in self?.dismissMissionMap() },
            onMissionMapAllow: { [weak self] requestID in self?.allowApprovalFromMissionMap(requestID) },
            onMissionMapOpenApproval: { [weak self] requestID in self?.openApprovalFromMissionMap(requestID) },
            onMissionMapKeyCatcherReady: { [weak self] view in self?.missionMapKeyCatcherReady(view) },
            onMissionMapPopoverPlacementChange: { [weak self] placement in
                self?.missionMapPopoverPlacementChanged(placement)
            },
            onMissionMapCardOffsetChange: { [weak self] surfaceID, offset in
                self?.missionMapCardOffsetChanged(surfaceID: surfaceID, offset: offset)
            },
            totalReviewCommentCount: totalReviewCommentCount,
            reviewFileCount: reviewFileCount
        )
    }

    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
    }

    /// Called by `AppDelegate.broadcastHasPreservedSessionSnapshotToRecoveryBars()`
    /// immediately after `recoveryBarModel.updateHasPreservedSessionSnapshot(_:)`,
    /// mirroring `toggleComposeOverlay()`'s/`dismissComposeOverlay()`'s own
    /// "mutate observable state, then explicitly refresh" pattern (this
    /// codebase's established convention -- `NSHostingView` is not relied
    /// on to pick up an external `@Observable` change on its own). Not
    /// `private`: called from AppDelegate.swift, a different file.
    func refreshRecoveryBar() {
        refreshHostingView()
    }

    /// Not `private`: pinned by `CalyxWindowControllerToggleMissionMapTests`.
    func recreateHostingView() {
        guard let contentView = window?.contentView else { return }
        let mainContent = buildMainContentView()
        let newHosting = NSHostingView(rootView: mainContent)
        newHosting.frame = contentView.bounds
        newHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(newHosting)
        newHosting.layoutSubtreeIfNeeded()
        hostingView?.removeFromSuperview()
        self.hostingView = newHosting
        // The new hosting view was added on top; the map's popover must
        // stay above it.
        if missionMapPopoverHost.isShown {
            missionMapPopoverHost.restack(above: newHosting)
        }
    }

    // MARK: - Split Container Management

    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry)
        } else {
            let container = SplitContainerView(registry: tab.registry)
            container.onTargetRatioChange = { [weak self] firstChildID, secondChildID, targetRatio, direction, splitRect in
                self?.handleDividerDrag(
                    firstChildFirstLeafID: firstChildID,
                    secondChildFirstLeafID: secondChildID,
                    targetRatio: targetRatio,
                    direction: direction,
                    splitRect: splitRect
                )
            }
            container.onActiveLeafChange = { [weak self] leafID in
                self?.activeTab?.splitTree.focusedLeafID = leafID
                self?.requestSave()
            }
            self.splitContainerView = container
        }
    }

    private func updateTerminalLayout() {
        guard let tab = activeTab, let container = splitContainerView else { return }
        container.updateLayout(tree: tab.splitTree)
    }

    private func updateLayout() {
        updateTerminalLayout()
    }

    @discardableResult
    private func focusActiveTabImmediately() -> Bool {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else {
            return false
        }

        let becameFirstResponder = window?.makeFirstResponder(focusView) ?? false
        guard becameFirstResponder else { return false }

        tab.registry.controller(for: focusedID)?.setFocus(true)
        tab.registry.controller(for: focusedID)?.refresh()
        focusView.needsDisplay = true
        tab.clearUnreadNotifications()
        return true
    }

    // MARK: - Tab Activation Helpers

    private func activateCurrentTab() {
        #if DEBUG
        _activateCurrentTabCountForTesting += 1
        #endif
        refreshHostingView()
        guard let tab = activeTab else { return }
        switch tab.content {
        case .terminal:
            tab.registry.resumeAll()
            rebuildSplitContainer()
            updateTerminalLayout()
            focusActiveTabImmediately()  // best-effort synchronous focus
            restoreFocus()               // async safety net (handles post-layout focus loss)
        case .browser:
            DispatchQueue.main.async { [weak self] in
                if let bv = self?.browserController(for: tab.id)?.browserView {
                    self?.window?.makeFirstResponder(bv)
                }
            }
        case .diff:
            break  // Diff tabs don't need special activation
        }
        retargetComposeOverlayIfNeeded()
        if isGitChangesSidebarVisible {
            refreshGitSidebar(trigger: .tabActivated)
        }
    }

    private func deactivateCurrentTab() {
        guard let tab = activeTab else { return }
        if case .terminal = tab.content {
            focusedController?.setFocus(false)
            tab.registry.pauseAll()
        }
    }

    // MARK: - Tab Operations

    /// `host` (remote sessions): threaded into `createManagedSurface
    /// (host:)` for the new tab's surface -- `nil` (every existing
    /// caller's shape) is unchanged, a local tab exactly as before this
    /// parameter existed. Reached by `AppDelegate.spawnRemoteSessionTab
    /// (host:)` when a key window controller already exists.
    ///
    /// `spawnCwd` (Cockpit `tab_create`, issue #43): normalized via
    /// `Self.normalizedCwdOverride(_:)` into `createManagedSurface`'s
    /// `explicitCwd` argument, so a non-nil override now reaches the
    /// spawned shell's pwd in BOTH the `.passthrough` and `.persistent`
    /// branches -- the bug this fixed was `.passthrough` silently
    /// dropping it (see `createManagedSurface`'s doc comment). `nil`
    /// (every existing caller's shape) still yields `explicitCwd: nil`,
    /// so libghostty performs its own live-OSC-7-based inheritance
    /// exactly as before this parameter existed.
    ///
    /// Thin wrapper resolving `GhosttyAppController.shared.app` and
    /// delegating everything else to `performCreateNewTab` -- same split,
    /// same reason, as `handleNewSplitNotification`/`performSplit`: that
    /// global is `nil` in the unit-test host, so a version of this method
    /// that resolves `app` internally could never be driven end-to-end by
    /// a test. See `performCreateNewTab`'s doc comment for the actual
    /// tab-creation body and its two load-bearing orderings.
    func createNewTab(inheritedConfig: Any? = nil, host: String? = nil, spawnCwd: String? = nil) {
        guard let app = GhosttyAppController.shared.app else { return }
        performCreateNewTab(app: app, inheritedConfig: inheritedConfig, host: host, spawnCwd: spawnCwd)
    }

    /// `createNewTab`'s body, taking `app` directly instead of resolving
    /// `GhosttyAppController.shared.app` internally -- see that method's
    /// doc comment for why, and `performSplit`'s identical precedent
    /// (down to `handleNewSplitNotification` resolving `app` before
    /// calling it). Not `private` (test access; mirrors `performSplit`'s/
    /// `createManagedSurface`'s own "un-privated for direct test access"
    /// precedent) -- a `CalyxWindowController` unit test can drive this
    /// directly with a dummy `ghostty_app_t` pointer even though
    /// `createNewTab` itself cannot. `inheritedConfig`/`host`/`spawnCwd`
    /// are forwarded straight through unchanged; see `createNewTab`'s doc
    /// comment for their semantics.
    ///
    /// CRITICAL ordering (issue #43 fix design): the `createManagedSurface
    /// (...)` call below MUST stay above `group.addTab(tab)`/
    /// `group.activeTabID = tab.id`. Its `sessionFallbackCwd:` argument
    /// calls `livePaneCwd(of: activeTab?.splitTree.focusedLeafID, in:
    /// activeTab)`, which falls back to `activeTab?.pwd` -- and
    /// `activeTab` reads `windowSession.activeGroup?.activeTab`, so it
    /// MUST still resolve to the OLD active tab at the point
    /// `createManagedSurface` runs. Hoisting the tab-wiring (`addTab`/
    /// `activeTabID =`) above `createManagedSurface` would silently make
    /// that same read resolve to the brand-new tab instead (which has no
    /// focused leaf and a `nil` `pwd`, no surface having reported one
    /// yet), regressing every override-less new tab's spawn cwd from the
    /// previous tab's directory back to `$HOME`.
    ///
    /// `self.window` is resolved INSIDE this method, not in the
    /// `createNewTab` wrapper above -- mirrors `performSplit`'s own `if
    /// let window = self.window`. It's used only for `config
    /// .scale_factor`, and the unit-test host DOES construct a real
    /// `CalyxWindow` (unlike `GhosttyAppController.shared.app`), so
    /// keeping the resolution in here, rather than requiring it as a
    /// parameter from the caller, is what makes this method drivable by
    /// a test in the first place.
    func performCreateNewTab(app: ghostty_app_t, inheritedConfig: Any? = nil, host: String? = nil, spawnCwd: String? = nil) {
        guard let window = self.window, let group = windowSession.activeGroup else { return }

        let tab = Tab()
        let initialGridSize = focusedTerminalGridSize()

        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig as? ghostty_surface_config_s {
            config = inherited
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            explicitCwd: Self.normalizedCwdOverride(spawnCwd),
            sessionFallbackCwd: livePaneCwd(of: activeTab?.splitTree.focusedLeafID, in: activeTab),
            origin: .tab, host: host, initialGridSize: initialGridSize
        ) else {
            logger.error("Failed to create surface for new tab")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Pause current tab
        activeTab?.registry.pauseAll()

        group.addTab(tab)
        group.activeTabID = tab.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    // MARK: - Cockpit Seams
    //
    // Backs LiveCockpitAppAccess (Calyx/Features/Cockpit/CockpitAppAccess.swift)
    // -- see CalyxTests/Cockpit/CockpitAppAccessSeamTests.swift for the
    // specced contract these satisfy.

    /// Extracted from `handleNewSplitNotification`'s body (same
    /// createManagedSurface + splitTree.insert shape), but taking a
    /// `surfaceID` directly (Cockpit's `pane_split` has no
    /// `SurfaceView`/notification to key off of) and an explicit `app`
    /// parameter rather than resolving `GhosttyAppController.shared.app`
    /// internally -- that global is `nil` in this test host (same
    /// constraint `createManagedSurface` was already adjusted for, see
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'s
    /// header), so an internally-resolving `performSplit` could never be
    /// driven by a unit test even once correctly implemented. Returns
    /// `nil` when `surfaceID` isn't a leaf in any tab this window owns,
    /// without touching the tree or creating a surface.
    ///
    /// `config` defaults to `nil` (Cockpit callers never have a
    /// pre-built ghostty config); `handleNewSplitNotification` passes its
    /// own `inherited_config` userInfo value through here unchanged so
    /// that notification-triggered splits keep inheriting the source
    /// surface's font size/theme exactly as before this method was
    /// extracted -- a trailing defaulted parameter rather than dropping
    /// that behavior, since no test exercises it either way.
    ///
    /// `explicitCwd: nil` -- a split carries no user-supplied cwd
    /// directive of its own (unlike Cockpit `tab_create`'s optional
    /// override), so this always leaves it unset to preserve
    /// `.passthrough`'s live OSC-7-based inheritance (see
    /// `createManagedSurface`'s doc comment). `sessionFallbackCwd:
    /// livePaneCwd(of: surfaceID, in: tab)` -- only ever consulted by a
    /// `.persistent` plan, since `.passthrough` ignores it -- prefers
    /// the SOURCE pane's own live cwd (`surfaceID`, the leaf being split,
    /// not just "the tab") over `tab.pwd`: a new split should land in
    /// the directory it was split from, even when the tab's own
    /// last-persisted pwd is stale or reflects a different pane
    /// entirely.
    func performSplit(
        surfaceID: UUID,
        direction: SplitDirection,
        app: ghostty_app_t,
        config: ghostty_surface_config_s? = nil
    ) -> UUID? {
        guard let tab = findTab(bySplitLeaf: surfaceID) else { return nil }

        var resolvedConfig = config ?? GhosttyFFI.surfaceConfigNew()
        if let window = self.window {
            resolvedConfig.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = createManagedSurface(
            tab: tab, app: app, config: resolvedConfig,
            explicitCwd: nil, sessionFallbackCwd: livePaneCwd(of: surfaceID, in: tab), origin: .tab
        ) else {
            return nil
        }

        let (newTree, _) = tab.splitTree.insert(at: surfaceID, direction: direction, newID: newSurfaceID)
        tab.splitTree = newTree

        splitContainerView?.updateLayout(tree: tab.splitTree)

        if let newView = tab.registry.view(for: newSurfaceID) {
            window?.makeFirstResponder(newView)
        }

        return newSurfaceID
    }

    /// Normalizes Cockpit's `tab_create` `cwd` argument into the
    /// `explicitCwd` `createManagedSurface` expects: `nil` when
    /// `override` is `nil` or blank (an MCP caller passing `""`/`"\n"`
    /// almost certainly means "no override", not "spawn at the empty
    /// path"), otherwise the trimmed-and-tilde-expanded path. `static`
    /// because it no longer reads any instance state -- the `??
    /// activeTab?.pwd ?? NSHomeDirectory()` fallback half is now carried
    /// entirely by the caller's own `sessionFallbackCwd` argument plus
    /// `createManagedSurface`'s own `?? NSHomeDirectory()` (see that
    /// method's doc comment), so this helper has nothing left to resolve
    /// beyond the override itself.
    ///
    /// `override` is trimmed of leading/trailing whitespace AND newlines
    /// first (an agent-constructed payload built from raw shell output,
    /// e.g. `$(pwd)`, plausibly carries a trailing `\n`); a non-nil
    /// override takes priority UNLESS the trimmed result is empty,
    /// treated the same as `nil`, then expanded via
    /// `expandingTildeInPath` since it comes straight from an MCP caller
    /// rather than already-resolved UI state. Does not validate the
    /// resulting path exists.
    static func normalizedCwdOverride(_ override: String?) -> String? {
        guard let override else { return nil }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NSString(string: trimmed).expandingTildeInPath
    }

    /// Shared by every synthetic-Return submission path
    /// (`cockpitSendCommand`, `sendComposeText`'s AI-agent branch,
    /// `sendReviewToAgent`): a pasted trailing newline alone is not
    /// reliably treated as Return by bracketed-paste-aware shells (see
    /// `AppDelegate.offerAgentResume`'s doc comment, ~line 2484, for the
    /// verified-against-ghostty-core rationale), so the first synthetic
    /// Return is always deferred 0.5s to let the paste complete before
    /// confirming it; `double` (AI-agent targets: confirm the paste, then
    /// submit) sends a second Return 0.5s after that. Preserves the exact
    /// timing/order the two precedent call sites already had.
    private func sendSyntheticReturn(controller: GhosttySurfaceController, double: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.keycode = 0x24 // macOS keycode for Return/Enter
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false

            keyEvent.action = GHOSTTY_ACTION_PRESS
            controller.sendKey(keyEvent)
            keyEvent.action = GHOSTTY_ACTION_RELEASE
            controller.sendKey(keyEvent)

            guard double else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                keyEvent.action = GHOSTTY_ACTION_PRESS
                controller.sendKey(keyEvent)
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                controller.sendKey(keyEvent)
            }
        }
    }

    /// Every Cockpit write path enters through `cockpitSendCommand`/
    /// `cockpitSendKeys`, so the Cockpit approval gate has ONE choke point
    /// per write kind.
    ///
    /// Sends `command` to `surfaceID`'s live surface via
    /// `GhosttySurfaceController.sendText` (GhosttySurface.swift), which
    /// resolves to ghostty's clipboard-paste completion path rather than
    /// a raw keystroke stream -- deliberate, see `sendSyntheticReturn`'s
    /// own doc comment for why a real synthetic keypress (not the pasted
    /// text alone) is required to submit. Resolves its tab via
    /// `findTab(bySplitLeaf:)` (the unified pane-identity check
    /// `ownsSplitLeaf`/`performSplit` also use), not the
    /// registry-based `findTab(surfaceID:)` -- so a `surfaceID`
    /// `LiveCockpitAppAccess.paneExists`/`listPanes` reports as a pane
    /// is never rejected here for a different reason. Returns whether
    /// `surfaceID` resolved to a live surface in this window at all --
    /// not whether the deferred keypresses eventually ran.
    ///
    /// No test currently drives this -- see CockpitAppAccessSeamTests.swift's
    /// header for why (same `GhosttyAppController.shared.app`/live-surface
    /// constraint as the rest of this section). Gating every caller of
    /// this on human approval, and covering it end-to-end, are both future work.
    func cockpitSendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) -> Bool {
        guard let tab = findTab(bySplitLeaf: surfaceID),
              let controller = tab.registry.controller(for: surfaceID) else {
            return false
        }

        controller.sendText(command)
        sendSyntheticReturn(controller: controller, double: doubleReturn)

        return true
    }

    /// Every Cockpit write path enters through `cockpitSendCommand`/
    /// `cockpitSendKeys`, so the Cockpit approval gate has ONE choke point
    /// per write kind.
    ///
    /// Sends raw `text` to `surfaceID`'s live surface via
    /// `GhosttySurfaceController.sendText`, with NO synthetic Return --
    /// unlike `cockpitSendCommand` (command submission), this backs
    /// Cockpit's `pane_send_keys` tool, which injects arbitrary key/paste
    /// input the caller controls the framing of. Resolves its tab via
    /// `findTab(bySplitLeaf:)`, same as `cockpitSendCommand` -- see that
    /// method's doc comment for why. Returns whether `surfaceID`
    /// resolved to a live surface in this window at all.
    func cockpitSendKeys(surfaceID: UUID, text: String) -> Bool {
        guard let tab = findTab(bySplitLeaf: surfaceID),
              let controller = tab.registry.controller(for: surfaceID) else {
            return false
        }

        controller.sendText(text)
        return true
    }

    /// Looks up `id` in this window's `commandRegistry` and, only if
    /// `isAvailable()` is true, records usage and runs its handler --
    /// unlike `CommandPaletteView.executeSelected()` (which relies on
    /// `search(query:)` having already filtered unavailable commands out
    /// before the user could ever select one), an MCP caller can name any
    /// command id directly with no such filter upstream, so this seam
    /// must gate on `isAvailable()` itself rather than trust the caller.
    /// `nil` when no command with `id` is registered at all; `executed:
    /// false` when found but currently unavailable (its handler is never
    /// called in that case) -- `LiveCockpitAppAccess.executePaletteCommand`
    /// turns the two into `.paletteCommandNotFound`/`.paletteCommandUnavailable`
    /// respectively.
    func cockpitExecutePaletteCommand(id: String) -> (command: PaletteCommand, executed: Bool)? {
        guard let command = commandRegistry.allCommands.first(where: { $0.id == id }) else { return nil }
        guard command.isAvailable() else { return (command, false) }

        commandRegistry.recordUsage(command.id)
        command.handler()

        return (command, true)
    }

    /// Wires an already-constructed tab (built by `AppDelegate
    /// .attachSessionAsTab`'s `.attachAsTab` branch via the same
    /// `restoreTabSurfaces`/`fallbackCreateSurface` machinery a window
    /// restore uses to reattach a persistent session's live surface,
    /// rather than `createManagedSurface` spawning a brand-new one) into
    /// this window's active group as a new tab. Reuses `createNewTab`'s
    /// own tail (pause current tab, add/activate, rebuild/refresh,
    /// restore focus, save) so an externally-constructed tab ends up
    /// wired up identically to one `createNewTab` builds itself.
    func attachRestoredTab(_ tab: Tab) {
        guard let group = windowSession.activeGroup else { return }

        activeTab?.registry.pauseAll()

        group.addTab(tab)
        group.activeTabID = tab.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    func createBrowserTab(url: URL) {
        guard let group = windowSession.activeGroup else { return }
        let tab = Tab(title: url.host() ?? url.absoluteString, content: .browser(url: url))

        deactivateCurrentTab()

        group.addTab(tab)
        group.activeTabID = tab.id

        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tab.id] = controller

        refreshHostingView()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(controller.browserView)
        }
        requestSave()
    }

    func promptAndOpenBrowserTab() {
        let alert = NSAlert()
        alert.messageText = "Open Browser Tab"
        alert.informativeText = "Enter a URL:"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        var input = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Normalize: add https:// if no scheme
        if !input.contains("://") {
            input = "https://" + input
        }

        guard let url = URL(string: input),
              let scheme = url.scheme,
              BrowserSecurity.isAllowedTopLevelScheme(scheme) else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Invalid URL"
            errorAlert.informativeText = "Only http and https URLs are allowed."
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
            return
        }

        createBrowserTab(url: url)
    }

    /// Releases everything this controller holds for `tab` (its browser
    /// controller, diff task and state, review store) and destroys its
    /// surfaces, killing any persistent session they were attached to.
    /// Shared by every tab-closing path.
    private func releaseTabResources(_ tab: Tab) {
        browserControllers.removeValue(forKey: tab.id)
        diffTasks[tab.id]?.cancel()
        diffTasks.removeValue(forKey: tab.id)
        diffStates.removeValue(forKey: tab.id)
        reviewStores.removeValue(forKey: tab.id)
        tearDownSurfaces(in: tab, isTerminating: false)
    }

    /// The prompt shown before closing `tab` when it still has
    /// unsubmitted review comments. Returns `true` when the tab may close:
    /// no such comments, or the user chose to discard them. Names `tab` in
    /// the prompt text via `tab.displayTitle`, falling back to "Untitled"
    /// for the empty title a diff tab gets when its source path's last
    /// path component is itself empty.
    private func confirmClosingDespiteUnsubmittedReviewComments(_ tab: Tab) -> Bool {
        guard let store = reviewStores[tab.id], store.hasUnsubmittedComments else { return true }
        let name = tab.displayTitle.isEmpty ? "Untitled" : tab.displayTitle
        let alert = NSAlert()
        alert.messageText = "Unsent Review Comments"
        alert.informativeText = "The diff tab \"\(name)\" has \(store.comments.count) unsent review comment(s). Closing will discard them."
        alert.addButton(withTitle: "Discard & Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeTab(id tabID: UUID) {
        // Prevent double execution
        guard !closingTabIDs.contains(tabID) else { return }

        guard let (tab, group) = windowSession.groups.tabAndGroup(tabID: tabID) else { return }

        closingTabIDs.insert(tabID)

        // Check for unsent review comments
        guard confirmClosingDespiteUnsubmittedReviewComments(tab) else {
            closingTabIDs.remove(tabID)
            return
        }

        // Release the browser controller, diff state, review store and
        // surfaces for this tab: an explicit tab close, unlike quitting
        // the app, ends the session rather than detaching it.
        // (`session.detach`/`session.kill` no longer route through this
        // method, see `closeFocusedSessionSurface`.)
        releaseTabResources(tab)

        let result = windowSession.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab, .switchedGroup:
            activateCurrentTab()
        case .windowShouldClose:
            closeLastWindow()
        }

        refreshHostingView()
        requestSave()
        closingTabIDs.remove(tabID)
    }

    func switchToTab(id tabID: UUID) {
        guard let targetGroup = windowSession.groups.tabAndGroup(tabID: tabID)?.group else {
            logger.warning("Attempted to switch to non-existent tab: \(tabID)")
            return
        }
        let sameGroup = windowSession.activeGroupID == targetGroup.id
        let sameTab = sameGroup && targetGroup.activeTabID == tabID
        guard !sameTab else { return }

        deactivateCurrentTab()
        windowSession.activeGroupID = targetGroup.id
        targetGroup.activeTabID = tabID
        activateCurrentTab()
    }

    func switchToGroup(id groupID: UUID) {
        guard windowSession.groups.contains(where: { $0.id == groupID }) else {
            logger.warning("Attempted to switch to non-existent group: \(groupID)")
            return
        }
        guard windowSession.activeGroupID != groupID else { return }

        deactivateCurrentTab()
        windowSession.activeGroupID = groupID
        activateCurrentTab()
    }

    // MARK: - Group Operations

    func createNewGroup() {
        guard let app = GhosttyAppController.shared.app else { return }
        performCreateNewGroup(app: app)
    }

    /// `createNewGroup`'s body, taking `app` directly instead of
    /// resolving `GhosttyAppController.shared.app` internally --
    /// mirrors `performCreateNewTab`'s and `performSplit`'s identical
    /// precedent: that global is documented throughout this test target
    /// (see e.g. `CockpitAppAccessSeamTests.swift`'s and
    /// `CockpitTabCreateCwdWiringTests.swift`'s own headers) as ALWAYS
    /// `nil` in the `CalyxTests` process, so a version of this method
    /// that resolved it internally could never be driven end-to-end by a
    /// test even once correctly implemented -- exactly the gap
    /// `CockpitSplitAndGroupCwdWiringTests.swift`'s header reports
    /// upstream for `createNewGroup` before this extraction existed. Not
    /// `private` (test access; mirrors `performCreateNewTab`'s/
    /// `performSplit`'s/`createManagedSurface`'s own "un-privated for
    /// direct test access" precedent) -- a `CalyxWindowController` unit
    /// test can drive this directly with a dummy `ghostty_app_t` pointer
    /// even though `createNewGroup` itself cannot.
    ///
    /// `self.window` is resolved INSIDE this method, not in the
    /// `createNewGroup` wrapper above -- mirrors `performCreateNewTab`'s/
    /// `performSplit`'s own identical `self.window` resolution. It's
    /// used only for `config.scale_factor`, and the unit-test host DOES
    /// construct a real `CalyxWindow` (unlike `GhosttyAppController
    /// .shared.app`), so keeping the resolution in here, rather than
    /// requiring it as a parameter from the caller, is what makes this
    /// method drivable by a test in the first place.
    func performCreateNewGroup(app: ghostty_app_t) {
        guard let window = self.window else { return }

        let tab = Tab()
        let initialGridSize = focusedTerminalGridSize()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            explicitCwd: nil,
            sessionFallbackCwd: livePaneCwd(of: activeTab?.splitTree.focusedLeafID, in: activeTab),
            origin: .tab,
            initialGridSize: initialGridSize
        ) else {
            logger.error("Failed to create surface for new group")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Pause current tab
        activeTab?.registry.pauseAll()

        let newColor = TabGroupColor.nextColor(excluding: windowSession.groups.map { $0.color })
        let group = TabGroup(
            name: WindowSession.nextDefaultGroupName(existing: windowSession.groups.map(\.name)),
            color: newColor,
            tabs: [tab],
            activeTabID: tab.id
        )

        windowSession.addGroup(group)
        windowSession.activeGroupID = group.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    private func closeActiveGroup() {
        guard let group = windowSession.activeGroup else { return }
        closeGroups(relativeTo: group.id, mode: .this)
    }

    /// Not `private`: `CalyxWindowControllerCloseArmsTests`
    /// calls this directly to verify `isClosingForShutdown` timing
    /// without needing a live `MainContentView`/`onCloseAllTabsInGroup`
    /// SwiftUI wiring to reach it, matching this file's existing
    /// `handleSessionReconnectDecision` precedent for the same reason.
    func closeAllTabsInGroup(id groupID: UUID) {
        closeGroups(relativeTo: groupID, mode: .this)
    }

    private func switchToNextGroup() {
        deactivateCurrentTab()
        windowSession.nextGroup()
        activateCurrentTab()
    }

    private func switchToPreviousGroup() {
        deactivateCurrentTab()
        windowSession.previousGroup()
        activateCurrentTab()
    }

    @objc func toggleSidebar() {
        windowSession.showSidebar.toggle()
        if isGitChangesSidebarVisible {
            refreshGitSidebar(trigger: .sidebarShown)
        } else {
            stopGitChangesMonitoring()
        }
        requestSave()
    }

    @objc func toggleCommandPalette() {
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        } else {
            // Mission Map covers the whole content area, so a palette
            // opened under it would be invisible yet hold focus.
            dismissMissionMap(restoresFocus: false)
            windowSession.showCommandPalette = true
        }
    }

    private func dismissCommandPalette() {
        guard windowSession.showCommandPalette else { return }
        windowSession.showCommandPalette = false
        guard let tab = activeTab else { return }
        switch tab.content {
        case .terminal:
            restoreFocus()
        case .browser:
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        case .diff:
            break
        }
    }

    @objc func toggleComposeOverlay() {
        if windowSession.showComposeOverlay {
            dismissComposeOverlay()
        } else {
            guard let tab = activeTab, case .terminal = tab.content else { return }
            // Same exclusivity as `toggleCommandPalette()`: the overlay
            // would sit hidden under Mission Map.
            dismissMissionMap(restoresFocus: false)
            composeOverlayTargetSurfaceID = focusedController?.id
            windowSession.showComposeOverlay = true
            refreshHostingView()
        }
    }

    private func retargetComposeOverlayIfNeeded() {
        guard windowSession.showComposeOverlay else { return }
        composeOverlayTargetSurfaceID = focusedController?.id
    }

    private func dismissComposeOverlay() {
        guard windowSession.showComposeOverlay else { return }
        windowSession.showComposeOverlay = false
        composeOverlayTargetSurfaceID = nil
        refreshHostingView()
        if case .terminal = activeTab?.content {
            restoreFocus()
        }
    }

    // MARK: - Mission Map

    /// View menu / Cmd+Shift+M key monitor / palette entry point.
    @objc func toggleMissionMap() {
        processToggleMissionMap()
    }

    /// Shared by `toggleMissionMap()` and `.ghosttyToggleTabOverview`.
    func processToggleMissionMap() {
        if windowSession.showMissionMap {
            dismissMissionMap()
        } else {
            showMissionMap()
        }
    }

    /// Opens Mission Map (no-op if already shown). Also the tab context
    /// menu's "Show All Tabs" entry point, which opens rather than toggles.
    func showMissionMap() {
        guard !windowSession.showMissionMap else { return }
        dismissCommandPalette()
        dismissComposeOverlay()
        // Both dismissals above can queue a `restoreFocus()` that would
        // pull first responder back to the terminal after the map's key
        // catcher takes it; advancing the request ID after them turns
        // that queued attempt into a no-op.
        focusRequestID &+= 1
        focusedController?.setFocus(false)
        windowSession.showMissionMap = true
        missionMapGitPoller.start { [weak self] in
            // The same cwd each card resolves (entry cwd first), so
            // the poller fetches the badge the card looks up.
            self?.missionMapPanes().compactMap { pane in
                MissionMapSnapshotBuilder.resolvedCwd(
                    entryCwd: AgentRegistry.shared.entries[pane.surfaceID]?.cwd, paneCwd: pane.cwd
                )
            } ?? []
        }
        refreshHostingView()
    }

    /// Hides Mission Map. `restoresFocus: false` is for callers that move
    /// focus somewhere themselves right after (a card click, another
    /// overlay opening).
    func dismissMissionMap(restoresFocus: Bool = true) {
        guard windowSession.showMissionMap else { return }
        windowSession.showMissionMap = false
        missionMapGitPoller.stop()
        missionMapKeyCatcher = nil
        missionMapSelection.edgeID = nil
        missionMapPopoverHost.hide()
        refreshHostingView()
        guard restoresFocus, let tab = activeTab else { return }
        // Same per-content restore as `dismissCommandPalette()`: unlike
        // the Compose overlay, the map opens over any tab kind.
        switch tab.content {
        case .terminal:
            restoreFocus()
        case .browser:
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        case .diff:
            break
        }
    }

    /// This window's panes, in window order -- the Cockpit pane listing
    /// (the same pane identity `list_panes` reports), narrowed to this
    /// window.
    private func missionMapPanes() -> [CockpitPaneInfo] {
        let windowID = windowSession.id
        return LiveCockpitAppAccess().listPanes().filter { $0.windowID == windowID }
    }

    /// Shows, moves or hides the selected line's popover as the map
    /// reports its placement (in the main hosting view's coordinates).
    /// Not `private`: pinned by `CalyxWindowControllerToggleMissionMapTests`.
    ///
    /// A `nil` placement hides the popover only once no line is selected:
    /// while one is, `nil` just means the (re-identified) map has not
    /// measured that line's popover yet -- e.g. right after switching the
    /// selection from one line to another -- so the popover stays where it
    /// is until the next placement moves it. A placement for a line other
    /// than the selected one is a stale report and is ignored. Closing the
    /// map hides the popover in `dismissMissionMap`.
    func missionMapPopoverPlacementChanged(_ placement: MissionMapPopoverPlacementInfo?) {
        guard windowSession.showMissionMap, let contentView = window?.contentView, let hostingView else {
            missionMapPopoverHost.hide()
            return
        }
        guard let placement else {
            if missionMapSelection.edgeID == nil {
                missionMapPopoverHost.hide()
            }
            return
        }
        guard placement.edgeID == missionMapSelection.edgeID else { return }
        missionMapPopoverHost.show(placement, in: contentView, above: hostingView) { [weak self] in
            self?.missionMapPopoverTapped()
        }
    }

    /// Every tab's persisted Mission Map card offsets in this window,
    /// merged (leaf UUIDs are unique across tabs). Not `private`: pinned
    /// by `CalyxWindowControllerMissionMapCardOffsetsTests`.
    func missionMapCardOffsets() -> [UUID: CGSize] {
        var merged: [UUID: CGSize] = [:]
        for group in windowSession.groups {
            for tab in group.tabs {
                merged.merge(tab.missionMapCardOffsets) { _, new in new }
            }
        }
        return merged
    }

    /// Stores a card's committed drag offset on the tab owning that leaf
    /// and schedules a session save. A card with no owning tab (the UI
    /// test fixture's fabricated cards) has nowhere to persist to.
    /// Not `private`: pinned by `CalyxWindowControllerMissionMapCardOffsetsTests`.
    func missionMapCardOffsetChanged(surfaceID: UUID, offset: CGSize) {
        guard let tab = findTab(bySplitLeaf: surfaceID) else { return }
        tab.setMissionMapCardOffset(offset, for: surfaceID)
        requestSave()
    }

    /// A tap on the popover closes it. The click may have moved first
    /// responder into the popover's hosting view, so the map's key
    /// catcher takes it back for Escape.
    private func missionMapPopoverTapped() {
        missionMapSelection.edgeID = nil
        missionMapPopoverHost.hide()
        if let catcher = missionMapKeyCatcher, catcher.window === window {
            window?.makeFirstResponder(catcher)
        }
    }

    /// Takes first responder for the map's key catcher so Escape reaches
    /// it. Called once the catcher is in a window; the claim itself waits
    /// one runloop turn so it lands after the SwiftUI update in flight.
    private func missionMapKeyCatcherReady(_ view: NSView) {
        missionMapKeyCatcher = view
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowSession.showMissionMap,
                  let catcher = self.missionMapKeyCatcher, catcher.window === self.window else { return }
            self.window?.makeFirstResponder(catcher)
        }
    }

    /// A card click: closes the map and focuses the card's pane. A pane
    /// in this window gets the goto-split sequence (which also clears
    /// split zoom, so a zoomed-away pane actually shows); a pane in
    /// another window is handed to that window's controller through
    /// `.calyxFocusSurface`.
    private func focusSurfaceFromMissionMap(_ surfaceID: UUID) {
        dismissMissionMap(restoresFocus: false)
        guard let tab = findTab(bySplitLeaf: surfaceID) else {
            NotificationCenter.default.post(name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID])
            return
        }
        switchToTab(id: tab.id)
        tab.splitTree = tab.splitTree.settingFocus(surfaceID)
        splitContainerView?.updateLayout(tree: tab.splitTree)
        if let view = tab.registry.view(for: surfaceID) {
            window?.makeFirstResponder(view)
        }
    }

    /// A card's inline Allow button.
    private func allowApprovalFromMissionMap(_ requestID: UUID) {
        (NSApp.delegate as? AppDelegate)?.approvalBannerModel.allow(id: requestID)
    }

    /// A card's Open button: selects the request in the app-wide approval
    /// panel (whose `.calyxApprovalInboxChanged` re-render orders the
    /// panel front) and closes the map so the panel is in view.
    private func openApprovalFromMissionMap(_ requestID: UUID) {
        (NSApp.delegate as? AppDelegate)?.approvalBannerModel.select(id: requestID)
        dismissMissionMap()
    }

    /// Approval requests are not read through @Observable tracking in
    /// this hosting view (the established convention), so the map's
    /// Allow/Open buttons follow the inbox through this notification.
    @objc private func handleApprovalInboxChangedForMissionMap(_ notification: Notification) {
        guard windowSession.showMissionMap else { return }
        refreshHostingView()
    }

    /// `.ghosttyToggleTabOverview` (`GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW`)
    /// receiver. With a triggering surface, only the window owning it
    /// acts; with none (an app-targeted action), only the key window.
    @objc private func handleToggleTabOverviewNotification(_ notification: Notification) {
        if notification.object == nil {
            guard window?.isKeyWindow == true else { return }
        } else {
            guard let surfaceView = notification.object as? SurfaceView,
                  findTab(for: surfaceView) != nil else { return }
        }
        processToggleMissionMap()
    }

    private func forwardEscapeToTerminal() {
        guard let tab = activeTab, case .terminal = tab.content else { return }
        let targetID = composeOverlayTargetSurfaceID ?? tab.splitTree.focusedLeafID
        guard let targetID,
              let controller = tab.registry.controller(for: targetID) else { return }

        var escEvent = ghostty_input_key_s()
        escEvent.action = GHOSTTY_ACTION_PRESS
        escEvent.keycode = 0x35
        escEvent.mods = GHOSTTY_MODS_NONE
        escEvent.consumed_mods = GHOSTTY_MODS_NONE
        escEvent.text = nil
        escEvent.unshifted_codepoint = 0
        escEvent.composing = false
        controller.sendKey(escEvent)

        escEvent.action = GHOSTTY_ACTION_RELEASE
        controller.sendKey(escEvent)
    }

    @discardableResult
    private func sendComposeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let targetController: GhosttySurfaceController?
        if let targetID = composeOverlayTargetSurfaceID,
           let tab = activeTab,
           let controller = tab.registry.controller(for: targetID) {
            targetController = controller
        } else {
            targetController = focusedController
        }

        guard let controller = targetController else { return false }

        // Check if the target is an AI agent (same detection as sendReviewToAgent)
        let isAgent = activeTab.map { tab -> Bool in
            guard case .terminal = tab.content else { return false }
            return Self.isAIAgentTitle(tab.title)
        } ?? false

        controller.sendText(text)

        if isAgent {
            // AI agent: same timing as sendReviewToAgent (confirm paste + submit)
            sendSyntheticReturn(controller: controller, double: true)
        } else {
            // Regular terminal: single Enter, immediate
            var keyEvent = ghostty_input_key_s()
            keyEvent.keycode = 0x24
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false

            keyEvent.action = GHOSTTY_ACTION_PRESS
            controller.sendKey(keyEvent)
            keyEvent.action = GHOSTTY_ACTION_RELEASE
            controller.sendKey(keyEvent)
        }
        return true
    }

    private func restoreFocus() {
        focusRequestID &+= 1
        let requestID = focusRequestID
        let startTime = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
        }
    }

    private static let focusRestoreTimeout: Double = 0.5

    private func attemptFocusRestore(requestID: UInt64, startTime: Double) {
        guard requestID == focusRequestID else { return }
        // Mission Map holds first responder while shown (e.g. a hosting
        // view recreated on de-occlusion queues a restore under it).
        guard !windowSession.showMissionMap else { return }

        let elapsed = CACurrentMediaTime() - startTime

        // Non-key window → skip; windowDidBecomeKey will call restoreFocus()
        guard window?.isKeyWindow == true else { return }

        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else { return }

        let inWindow = focusView.window === self.window
        let hasSuperview = focusView.superview != nil

        // View must be attached to THIS window's hierarchy
        guard inWindow, hasSuperview else {
            guard elapsed < Self.focusRestoreTimeout else {
                splitContainerView?.onDeferredLayoutComplete = { [weak self] in
                    guard let self, requestID == self.focusRequestID else { return }
                    self.attemptFocusRestore(requestID: requestID, startTime: CACurrentMediaTime())
                }
                return
            }
            // Retry with 10ms backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
            }
            return
        }

        let result = window?.makeFirstResponder(focusView) ?? false
        if result {
            tab.registry.controller(for: focusedID)?.setFocus(true)
            tab.registry.controller(for: focusedID)?.refresh()
            focusView.needsDisplay = true
            activeTab?.clearUnreadNotifications()
        }
    }

    // MARK: - Split Operations

    private func handleDividerDrag(
        firstChildFirstLeafID: UUID,
        secondChildFirstLeafID: UUID,
        targetRatio: Double,
        direction: SplitDirection,
        splitRect: CGRect
    ) {
        guard let tab = activeTab,
              let container = splitContainerView,
              container.bounds.width > 0,
              container.bounds.height > 0 else { return }

        // Bound the absolute ratio against the LOCAL split rect, not the
        // outer container — otherwise dragging the inner divider of a
        // nested split would resize the wrong axis fraction (Bug C).
        let localSize = splitRect.size
        guard localSize.width > 0, localSize.height > 0 else { return }

        tab.splitTree = tab.splitTree.setRatio(
            firstChildFirstLeafID: firstChildFirstLeafID,
            secondChildFirstLeafID: secondChildFirstLeafID,
            direction: direction,
            to: targetRatio,
            bounds: localSize,
            minSize: 50
        )
        container.updateLayout(tree: tab.splitTree)
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(handleNewSplitNotification(_:)),
                           name: .ghosttyNewSplit, object: nil)
        center.addObserver(self, selector: #selector(handleCloseSurfaceNotification(_:)),
                           name: .ghosttyCloseSurface, object: nil)
        center.addObserver(self, selector: #selector(handleGotoSplitNotification(_:)),
                           name: .ghosttyGotoSplit, object: nil)
        center.addObserver(self, selector: #selector(handleResizeSplitNotification(_:)),
                           name: .ghosttyResizeSplit, object: nil)
        center.addObserver(self, selector: #selector(handleEqualizeSplitsNotification(_:)),
                           name: .ghosttyEqualizeSplits, object: nil)
        center.addObserver(self, selector: #selector(handleSetTitleNotification(_:)),
                           name: .ghosttySetTitle, object: nil)
        center.addObserver(self, selector: #selector(handleSetPwdNotification(_:)),
                           name: .ghosttySetPwd, object: nil)
        center.addObserver(self, selector: #selector(handleProgressReportNotification(_:)),
                           name: .ghosttyProgressReport, object: nil)
        center.addObserver(self, selector: #selector(handleDesktopNotification(_:)),
                           name: .ghosttyDesktopNotification, object: nil)
        center.addObserver(self, selector: #selector(handleGotoTabNotification(_:)),
                           name: .ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmClipboardNotification(_:)),
                           name: .ghosttyConfirmClipboard, object: nil)
        center.addObserver(self, selector: #selector(handleFocusSurfaceNotification(_:)),
                           name: .calyxFocusSurface, object: nil)
        center.addObserver(self, selector: #selector(handleShowChildExitedNotification(_:)),
                           name: .ghosttyShowChildExited, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmingQuitDidEnd(_:)),
                           name: .calyxConfirmingQuitDidEnd, object: nil)
        // These five notifications are posted by GhosttyActionRouter (see
        // "MARK: - Keybind Actions" below) but need an explicit observer
        // here to reach their handlers: without one, ghostty's default
        // close_tab/close_window/toggle_fullscreen keybinds and the
        // initial-window-size/renderer-health actions are silently inert.
        center.addObserver(self, selector: #selector(handleCloseTabNotification(_:)),
                           name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(handleCloseWindowNotification(_:)),
                           name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(handleToggleFullscreenNotification(_:)),
                           name: .ghosttyToggleFullscreen, object: nil)
        center.addObserver(self, selector: #selector(handleInitialSizeNotification(_:)),
                           name: .ghosttyInitialSize, object: nil)
        center.addObserver(self, selector: #selector(handleRendererHealthNotification(_:)),
                           name: .ghosttyRendererHealth, object: nil)
        // These six notifications are posted by
        // GhosttyActionRouter (GhosttyAction.swift's own "MARK: - Keybind
        // Actions" section) and, like the five above, need an explicit
        // observer here or their keybinds are silently inert.
        center.addObserver(self, selector: #selector(handleSetTabTitleNotification(_:)),
                           name: .ghosttySetTabTitle, object: nil)
        center.addObserver(self, selector: #selector(handleCopyTitleToClipboardNotification(_:)),
                           name: .ghosttyCopyTitleToClipboard, object: nil)
        center.addObserver(self, selector: #selector(handleToggleCommandPaletteNotification(_:)),
                           name: .ghosttyToggleCommandPalette, object: nil)
        center.addObserver(self, selector: #selector(handleMoveTabNotification(_:)),
                           name: .ghosttyMoveTab, object: nil)
        center.addObserver(self, selector: #selector(handleToggleMaximizeNotification(_:)),
                           name: .ghosttyToggleMaximize, object: nil)
        center.addObserver(self, selector: #selector(handleResetWindowSizeNotification(_:)),
                           name: .ghosttyResetWindowSize, object: nil)
        // GHOSTTY_ACTION_PROMPT_TITLE (GitHub issue #42): needs the same
        // explicit observer as the two batches above -- see "MARK: -
        // Prompt Title" below.
        center.addObserver(self, selector: #selector(handlePromptTitleNotification(_:)),
                           name: .ghosttyPromptTitle, object: nil)
        // GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: needs the same
        // explicit observer as the batches above -- see
        // "MARK: - Split Zoom" / processToggleSplitZoom's own doc comment.
        center.addObserver(self, selector: #selector(handleToggleSplitZoomNotification(_:)),
                           name: .ghosttyToggleSplitZoom, object: nil)
        // Mission Map: Ghostty's `toggle_tab_overview` keybind opens it,
        // and its approval buttons follow the inbox.
        center.addObserver(self, selector: #selector(handleToggleTabOverviewNotification(_:)),
                           name: .ghosttyToggleTabOverview, object: nil)
        center.addObserver(self, selector: #selector(handleApprovalInboxChangedForMissionMap(_:)),
                           name: .calyxApprovalInboxChanged, object: nil)
    }

    // MARK: - Screen State Polling (Herdr Layer 2)

    /// Starts the window-lifetime poll loop that feeds `ScreenStateClassifier`
    /// results into `AgentRegistry.handleScreenClassification` — the
    /// fallback for panes hooks haven't reported on (or aren't wired up
    /// at all). Mirrors `AgentRegistry.sweepTask`'s `while !Task.isCancelled`
    /// shape, but — unlike that task, started/stopped by IPC server
    /// lifecycle — this one runs for the whole life of the window: there's
    /// no property-observation hook on `WindowSession.sidebarMode` /
    /// `showSidebar` to react to (they're mutated from many call sites:
    /// palette commands, the sidebar's SwiftUI binding, toggles), so each
    /// tick instead checks the relevant gates itself and skips the
    /// (expensive — `ghostty_surface_read_text` is documented as costly)
    /// per-surface read entirely unless warranted.
    private func startScreenPollTask() {
        screenPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.pollScreenClassificationIfAgentsSidebarVisible()
            }
        }
    }

    /// Four gates, cheapest first, before the expensive per-surface
    /// `ghostty_surface_read_text` call:
    /// (a) `AgentRegistry.isServerRunning`: IPC disabled means Calyx's
    ///     own native (hooks/title-heuristic) tracking is off (a herdr
    ///     row can still keep the sidebar itself visible via
    ///     `AgentSidebarGate`, see `AgentRegistry.handleTitleChange`'s
    ///     own doc comment for the row-retirement reason this still
    ///     matters), so classifying screens into the registry in the
    ///     background would only produce native entries that immediately
    ///     (and confusingly) populate the sidebar the moment IPC is
    ///     re-enabled, with no way to retire themselves until then.
    /// (b) Per-surface: a `.hooks`-sourced entry is authoritative:
    ///     `handleScreenClassification` already no-ops for one, but
    ///     skipping here avoids the read itself, not just its effect.
    /// (c) Per-surface: `HerdrHeuristicIngestionPolicy.shouldIngest`:
    ///     a herdr-hosted surface's "real" state already arrives as an
    ///     external `AgentRegistry` row over herdr's own event stream, so
    ///     classifying its screen too would only produce a duplicate row.
    /// (d) `AgentRegistry.isAgentsSidebarVisibleAnywhere` (rather than
    ///     this window's own `sidebarMode`/`showSidebar`): see that
    ///     property's doc comment for the cross-window gap this closes.
    private func pollScreenClassificationIfAgentsSidebarVisible() {
        guard AgentRegistry.shared.isServerRunning else { return }
        guard AgentRegistry.shared.isAgentsSidebarVisibleAnywhere else { return }

        for group in windowSession.groups {
            for tab in group.tabs {
                for surfaceID in tab.registry.allIDs {
                    guard AgentRegistry.shared.entries[surfaceID]?.source != .hooks else { continue }
                    // Herdr-hosted / herdr-bridged surfaces are skipped
                    // before the expensive read below too, see
                    // HerdrHeuristicIngestionPolicy's doc comment.
                    guard HerdrHeuristicIngestionPolicy.shouldIngest(
                        isHerdrHosted: HerdrHostedSurfaces.shared.contains(surfaceID),
                        isBridgeSurface: HerdrPaneRegistry.shared.isBridgeSurface(surfaceID)
                    ) else { continue }
                    guard let surface = tab.registry.controller(for: surfaceID)?.surface else { continue }
                    guard let bottomText = GhosttySurfaceSelectionReader(surface: surface)
                        .readActiveBottomText(rows: 12) else { continue }

                    let kind = AgentRegistry.shared.entries[surfaceID]?.kind ?? AgentEntry.claudeCodeKind
                    let state = ScreenStateClassifier.classify(bottomText: bottomText, kind: kind)
                    AgentRegistry.shared.handleScreenClassification(surfaceID: surfaceID, state: state)
                }
            }
        }
    }

    // MARK: - Notification Handlers

    @objc private func handleNewSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        guard let app = GhosttyAppController.shared.app else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
        let splitDir: SplitDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            splitDir = .horizontal
        case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP:
            splitDir = .vertical
        default:
            splitDir = .horizontal
        }

        let inheritedConfig = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s

        if performSplit(surfaceID: surfaceID, direction: splitDir, app: app, config: inheritedConfig) == nil {
            logger.error("Failed to create split surface")
        }
    }

    /// Defers
    /// (rather than immediately tearing down) a `close_surface`
    /// notification while `AppDelegate.isConfirmingQuit` is true, via
    /// the same `deferOrRun` choke point `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision` use, mirroring their existing
    /// deferral instead of relying on ghostty's own keypress self-
    /// healing (`Surface.close()` refires on any encodable keypress
    /// while child_exited). Replayed by `drainDeferredReconnectEvents()`
    /// once the gate clears. Deliberately does NOT also bail on
    /// `isShuttingDown` (unlike `handleSessionReconnectDecision`/
    /// `handleReconnectGiveUp`/`processChildExited`): `closeSurfaceAndCleanUp`'s
    /// own `closingTabIDs` reentrancy guard already protects the actual-
    /// teardown case (see that method's doc comment), and this
    /// notification also fires for an ordinary, unrelated pane
    /// genuinely closing during quit, which must still tear down
    /// normally rather than be silently dropped.
    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        deferOrRun(.closeSurface(surfaceView: surfaceView)) { [weak self] in
            self?.processCloseSurface(surfaceView: surfaceView)
        }
    }

    /// The actual `close_surface` teardown `handleCloseSurfaceNotification`
    /// runs immediately, or `drainDeferredReconnectEvents()` replays
    /// later. Finds the tab that owns `surfaceView` (may be a background
    /// tab) and, since this notification fires for every ghostty-driven
    /// surface close, including a persistent-session pane whose user,
    /// having seen `SessionReconnectCoordinator` give up (or having
    /// decided not to wait), presses a key on the dead pane, ghostty's
    /// own close_surface callback then fires with process_alive=false
    /// (see SessionReconnectCoordinator.swift's header comment). In
    /// every case this notification fires, the pane is being explicitly
    /// torn down, so `closeSurfaceAndCleanUp` kills the underlying
    /// session the same as
    /// closeTab(id:)/closeActiveGroup()/closeAllTabsInGroup(id:) do. A
    /// stale surfaceView (already closed some other way) is a safe
    /// no-op via `findTab`'s lookup.
    private func processCloseSurface(surfaceView: SurfaceView) {
        guard let (owningTab, owningGroup) = findTab(for: surfaceView) else { return }
        guard let surfaceID = owningTab.registry.id(for: surfaceView) else { return }
        closeSurfaceAndCleanUp(tab: owningTab, group: owningGroup, surfaceID: surfaceID)
    }

    /// Shared surface-teardown sequence: kill (or, when `killSessions`
    /// is `false`, merely detach — see `detachSessionIfPersistent`'s
    /// doc comment) any persistent session attached to `surfaceID`,
    /// remove the leaf from `tab`'s split tree, destroy the surface,
    /// and — if that leaves the tab with no leaves at all — remove the
    /// tab (closing the window if it was the last one). Used by:
    /// `handleCloseSurfaceNotification` (a ghostty-driven close, e.g.
    /// `exit` in a plain pane, or a key press acknowledging a dead
    /// persistent-session pane — kill semantics, default);
    /// `closeDeadPersistentSessionSurface` (`SessionReconnectCoordinator`
    /// confirming, via the daemon, that a persistent session's process
    /// really did exit — kill semantics, default); `handleReconnectGiveUp`
    /// (reconnect attempts exhausted — detach semantics,
    /// `killSessions: false`, since the daemon may still be legitimately
    /// running); and `closeFocusedSessionSurface` (`session.detach`/
    /// `session.kill` command palette actions, either semantics per
    /// which command fired).
    ///
    /// Closing the last tab/group/window does
    /// not terminate the app or need confirming, so this method does
    /// not mark any "termination confirmed" flag once teardown
    /// reaches the `.windowShouldClose` case below: it just calls
    /// `closeLastWindow()`.
    ///
    /// The kill/detach decision below reads `isAppActuallyTerminating`
    /// (the app-wide discriminator), NOT this window's own
    /// `isClosingForShutdown`: `isClosingForShutdown` means only "this
    /// window is tearing down" (see that flag's own doc comment), which
    /// is also true for an ordinary, non-terminating close of one of
    /// several open windows — reading it here would misread that as "the
    /// app is quitting" and wrongly detach, rather than kill, a session
    /// whose pane's process exits while this window happens to be
    /// mid-close for an unrelated reason.
    ///
    /// `callerAlreadyClaimedClosingTabIDs`: set by
    /// `closeFocusedSessionSurface`/`handleReconnectGiveUp`, the two
    /// callers that insert `tab.id` into `closingTabIDs` themselves
    /// BEFORE calling this method (so a mid-modal reentrant close can
    /// already be blocked before teardown starts; see each of their doc
    /// comments). Without this, this method's OWN reentrancy guard right
    /// below would immediately bail out on their very first, legitimate
    /// call, since it can't otherwise distinguish "the caller already
    /// claimed this tab and is calling me directly" from "someone else
    /// is mid-teardown and this is an unwanted reentrant call". Every
    /// other caller (`handleCloseSurfaceNotification`,
    /// `closeDeadPersistentSessionSurface`) takes the default `false`
    /// and is subject to the guard exactly as before.
    ///
    /// The pairing contract
    /// is that `callerAlreadyClaimedClosingTabIDs: true` implies
    /// `closingTabIDs.contains(tab.id)` is ALREADY true by the time this
    /// method is called, checked by a DEBUG-only assertion below. A
    /// caller that passes `true` without having actually inserted first
    /// would otherwise silently no-op (this method's own guard would
    /// never fire, but neither would the reentrancy protection it
    /// exists for); both current callers must remain correctly
    /// paired.
    private func closeSurfaceAndCleanUp(
        tab: Tab,
        group: TabGroup,
        surfaceID: UUID,
        killSessions: Bool = true,
        callerAlreadyClaimedClosingTabIDs: Bool = false
    ) {
        // If closeTab/closeActiveGroup/closeAllTabsInGroup is already
        // driving this tab's teardown, this call is a reentrant one:
        // ghostty's close_surface callback firing synchronously from
        // inside `destroySurface`'s `requestClose()`, and that owning
        // method's own loop already kills/detaches every surface and
        // will remove the tab/group wholesale once it finishes.
        // Checked first, before any of the kill/
        // detach/split-tree work below, which would otherwise run
        // redundantly for every surface in the tab being closed.
        #if DEBUG
        assert(!callerAlreadyClaimedClosingTabIDs || closingTabIDs.contains(tab.id),
               "callerAlreadyClaimedClosingTabIDs was true but tab.id is not actually in " +
               "closingTabIDs, the caller must insert it BEFORE calling this method, see " +
               "that parameter's own doc comment")
        #endif
        guard callerAlreadyClaimedClosingTabIDs || !closingTabIDs.contains(tab.id) else { return }

        if killSessions {
            // isTerminating is
            // required, passed explicitly rather than relying on a
            // default, and reads the app-wide
            // isAppActuallyTerminating, not this window's own
            // isClosingForShutdown (see this method's own doc comment
            // for why the two must not be conflated).
            killSessionIfPersistent(tab: tab, surfaceID: surfaceID, isTerminating: isAppActuallyTerminating)
        } else {
            detachSessionIfPersistent(tab: tab, surfaceID: surfaceID)
        }
        // Tells HerdrTabCoordinator a herdr-bridged leaf is
        // closing from the Calyx side (Cmd+W, a pane's own close button,
        // ...) BEFORE `SurfaceRegistry.destroySurface` below runs, so
        // `HerdrPaneRegistry.shared` still has the entry to look up --
        // see `HerdrTabCoordinator.handleCalyxSurfaceClosed(surfaceID:)`'s
        // own doc comment for why this coordinator needs to hear about
        // this close at all (it never generates a herdr-side
        // `pane.closed` event the way a herdr-initiated close does).
        if HerdrPaneRegistry.shared.isBridgeSurface(surfaceID) {
            (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator?.handleCalyxSurfaceClosed(surfaceID: surfaceID)
        }
        let (newTree, focusTarget) = tab.splitTree.remove(surfaceID)
        tab.registry.destroySurface(surfaceID)
        tab.splitTree = newTree
        tab.pruneMissionMapCardOffsets()

        // Below runs only for process-initiated closes (e.g. `exit` command)
        if tab.splitTree.isEmpty {
            let wasActiveTab = (tab.id == activeTab?.id)
            let result = windowSession.removeTab(id: tab.id, fromGroup: group.id)
            if wasActiveTab {
                switch result {
                case .switchedTab, .switchedGroup:
                    activateCurrentTab()
                case .windowShouldClose:
                    closeLastWindow()
                }
            } else {
                refreshHostingView()
            }
            requestSave()
            return
        }

        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
            if let focusID = focusTarget, let focusView = tab.registry.view(for: focusID) {
                window?.makeFirstResponder(focusView)
            }
            requestSave()
        }
    }

    // MARK: - Session Reconnect

    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` for a persistent-session
    /// surface: hand off to `sessionReconnectCoordinator`, which queries
    /// the daemon (macOS never reports a trustworthy exit code for this
    /// action — see `SessionDaemonClient.swift`'s header comment) and
    /// decides reconnect vs. close vs. give up via
    /// `handleSessionReconnectDecision`. A no-op for an ordinary
    /// (non-persistent-session) surface, since the coordinator's own
    /// `surfaceMap.sessionID(for:)` lookup finds nothing for one.
    ///
    /// Also a no-op once `isClosingForShutdown` is set:
    /// `windowWillClose`'s teardown destroys every surface in the
    /// window, which can itself trigger this same notification for a
    /// persistent-session surface. Without this guard, that could
    /// enqueue a `.giveUp`/`.closePane` decision that races the
    /// in-flight quit teardown and reaches `detachSessionIfPersistent`/
    /// `killSessionIfPersistent` after (or racing) the snapshot save,
    /// even though `SessionCloseKillPolicy`/`detachSessionIfPersistent`'s
    /// own `isClosingForShutdown` checks are the last line of defense
    /// against that outcome.
    ///
    /// While `isConfirmingQuit` is true,
    /// defers this event instead of dropping it (see
    /// `deferredReconnectEvents`'s doc comment), replayed once the gate
    /// clears via `drainDeferredReconnectEvents()`. `processChildExited`'s
    /// own entry guard covers the shutdown-suppression
    /// case, so this method itself only needs
    /// `deferOrRun`'s isConfirmingQuit choke point.
    @objc private func handleShowChildExitedNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        deferOrRun(.childExited(surfaceView: surfaceView)) { [weak self] in
            self?.processChildExited(surfaceView: surfaceView)
        }
    }

    /// Bails out while this window or the
    /// app itself is shutting down (`isShuttingDown`), replacing the
    /// narrower `isClosingForShutdown`-only guard that used to live in
    /// `handleShowChildExitedNotification`. `windowWillClose`'s teardown
    /// intentionally preserves tracking state into the snapshot, so
    /// kicking off a fresh reconnect decision on top of that is both
    /// unnecessary and dangerous.
    ///
    /// Not `private` (mirroring
    /// `handleSessionReconnectDecision`'s own "Not `private`" doc
    /// comment): `CalyxWindowControllerChildExitedTasksTests` calls
    /// this directly to drive `childExitedTasks`'s insert without
    /// needing a real `GHOSTTY_ACTION_SHOW_CHILD_EXITED` notification
    /// and a `SurfaceView` actually attached to the window (which
    /// `handleShowChildExitedNotification`'s `belongsToThisWindow`
    /// guard would otherwise require).
    func processChildExited(surfaceView: SurfaceView) {
        guard !isShuttingDown else { return }
        guard let tab = findTab(for: surfaceView)?.0,
              let surfaceID = tab.registry.id(for: surfaceView) else { return }

        // Herdr auto-close: a herdr-hosted surface (full-TUI attach) or
        // a herdr-bridged surface (HerdrPaneRegistry, a native-tab pane
        // bridge) is deliberately never registered in `SessionSurfaceMap`
        // (see `HerdrHostedSurfaces.swift`'s header), so
        // `sessionReconnectCoordinator.childExited` below provably
        // no-ops for either -- nothing else would ever close this pane,
        // leaving ghostty's own "process exited" banner up forever.
        // Closed here instead, synchronously and BEFORE the
        // `childExitedTasks` Task insert below: a herdr decision needs
        // no daemon round-trip, so it must never reach
        // `sessionReconnectCoordinator` at all. `killSessions` stays at
        // its default `true` -- safe here since `SessionSurfaceMap
        // .shared.sessionID(for:)` is always `nil` for either kind of
        // herdr surface, so `SessionCloseKillPolicy.shouldKill`'s
        // `hasSession` gate is always `false` and no kill call ever
        // fires (herdr's child process is already dead, nothing left to
        // signal). For a bridged surface, `closeSurfaceAndCleanUp` below
        // also runs the same `HerdrPaneRegistry.shared.isBridgeSurface`
        // check `closeHerdrTrackedSurface` already runs for a
        // herdr-initiated close, landing on `HerdrTabCoordinator
        // .handleCalyxSurfaceClosed` -- the coordinator's own bookkeeping
        // and the registry entry are pruned exactly as they are for a
        // Cmd+W close of the same pane, and nothing is sent to herdr.
        if HerdrChildExitedPolicy.shouldAutoClose(
            isHerdrHosted: HerdrHostedSurfaces.shared.contains(surfaceID),
            isBridgeSurface: HerdrPaneRegistry.shared.isBridgeSurface(surfaceID)
        ) {
            #if DEBUG
            _herdrHostedAutoCloseObserverForTesting?(surfaceID)
            #endif
            if let (herdrTab, herdrGroup) = findTabAndGroup(surfaceID: surfaceID) {
                closeSurfaceAndCleanUp(tab: herdrTab, group: herdrGroup, surfaceID: surfaceID)
            }
            return
        }

        // Remote sessions: a remote SessionRef's host means the
        // LOCAL daemon has no record of this session at all, so
        // `sessionReconnectCoordinator.childExited` must skip its local
        // daemon query entirely rather than misreading that absence as
        // "exited" -- see `isRemote`'s own doc comment on that method.
        let isRemote = tab.sessionRefs[surfaceID]?.host != nil

        // Tracked in
        // `childExitedTasks`, cancelled alongside its `diffTasks`/
        // `expandTasks` siblings in `windowWillClose`, instead of being
        // left as an untracked fire-and-forget `Task`.
        //
        // Cancel-before-replace guards against
        // a same-key re-insert leaking the previous Task (cheap
        // insurance even though surfaceIDs are one-shot in practice);
        // the Task itself removes its own entry once it completes,
        // mirroring `expandTasks[hash]`'s self-removing Task
        // (`expandCommit(hash:)`) -- otherwise a completed entry is
        // retained forever.
        childExitedTasks.insert(surfaceID, task: Task { [weak self] in
            guard let self else { return }
            await self.sessionReconnectCoordinator.childExited(surfaceID: surfaceID, isRemote: isRemote)
            self.childExitedTasks.removeValue(forKey: surfaceID)
        })
    }

    // MARK: - Keybind Actions
    //
    // `GhosttyActionRouter` posts `.ghosttyCloseTab` / `.ghosttyCloseWindow` /
    // `.ghosttyToggleFullscreen` / `.ghosttyInitialSize` / `.ghosttyRendererHealth`
    // (GhosttyAction.swift). Each needs an `addObserver` registered in
    // `registerNotificationObservers()` above: without one, the router's own
    // handlers still return `true` (libghostty sees "handled"), so ghostty's
    // built-in keybinds for these (Ctrl+Cmd+F and Cmd+Enter =
    // toggle_fullscreen, Cmd+Opt+W = close_tab, Cmd+Shift+W = close_window,
    // etc.) go silently inert for every user who hasn't overridden them.
    //
    // Each `process*`/`apply*` method below has a real body, and
    // `registerNotificationObservers()` above registers a matching
    // `@objc private func handleXxxNotification` for each, defined right
    // next to its `process*`/`apply*` counterpart below. See the sibling
    // test files (CalyxWindowControllerCloseTabTests,
    // CalyxWindowControllerCloseWindowTests,
    // CalyxWindowControllerToggleFullscreenTests,
    // CalyxWindowControllerInitialSizeTests,
    // CalyxWindowControllerRendererHealthTests) for the contract each
    // satisfies.
    //
    // Destination resolution for every `handleXxxNotification` below uses
    // `findTab(for:)`, not `belongsToThisWindow(_:)`: the latter checks
    // `view.window === self.window`, which a `_testInsert`-only fixture
    // SurfaceView (this codebase's established no-live-ghostty-surface
    // test pattern) never satisfies, since it is never attached into a
    // real window's view hierarchy. `findTab(for:)` walks `windowSession`
    // instead, which DOES see a `_testInsert`-only surface.

    /// Has two callers: `handleCloseTabNotification` below (the
    /// `.ghosttyCloseTab` / `GHOSTTY_ACTION_CLOSE_TAB` close_tab keybind
    /// receiver, where `tab`/`group` are always the focused pane's tab and
    /// its owning group, resolved via `findTab(for:)`) and
    /// `closeTabs(relativeTo:mode:)` below (the tab context menu, which may
    /// pass a tab belonging to ANY group, including a non-active group
    /// shown in the sidebar). This method itself has no routing/ownership
    /// logic of its own, only the close-mode fan-out.
    ///
    /// `mode` semantics (`ghostty_action_close_tab_mode_e`,
    /// `GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h`):
    ///   - `GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS`: close only `tab`.
    ///   - `GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER`: close every OTHER tab in
    ///     `group`, leaving only `tab`.
    ///   - `GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT`: close every tab in
    ///     `group` positioned AFTER `tab` (tab-bar order).
    ///
    /// `OTHER`/`RIGHT` are scoped to the passed `group`'s own `tabs`, never
    /// `windowSession.activeGroup`: ghostty has no concept of "group" (a
    /// Calyx-only feature layered on top), so this matches what the user
    /// actually sees as "the tab bar" for whichever group `tab` belongs to,
    /// keybind or context menu alike.
    ///
    /// IMPLEMENTATION NOTE (verified by
    /// `CalyxWindowControllerProcessCloseTabBatchTests`): `OTHER`/`RIGHT`
    /// close their victims through the batch `closeTabs(_:in:)` below,
    /// rather than one `closeTab(id:)` call per victim, so the current tab
    /// is activated at most once for the whole action instead of once per
    /// victim, and is deactivated once before teardown when it is among
    /// the victims (`closeTab(id:)` never deactivates; see
    /// `closeTabs(_:in:)`'s own doc comment).
    func processCloseTab(tab: Tab, group: TabGroup, mode: ghostty_action_close_tab_mode_e) {
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
            closeTab(id: tab.id)

        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            closeTabs(group.tabs.filter { $0.id != tab.id }, in: group)

        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            guard let targetIndex = group.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            closeTabs(Array(group.tabs[(targetIndex + 1)...]), in: group)

        default:
            logger.warning("Unknown close_tab mode: \(mode.rawValue)")
        }
    }

    /// Closes every `(tab, group)` pair in `victims`, across one or more
    /// groups, in one pass, in the given order, and then removes every
    /// group in `emptyGroups` that is still present and still has no
    /// tabs. Tabs already mid-close are skipped, and each diff tab among
    /// `victims` with unsubmitted review comments gets the same prompt as
    /// `closeTab(id:)`, in order; a declined diff tab stays open, so its
    /// group survives with at least that tab, while the other victims in
    /// that group still close. All prompts happen before any teardown.
    ///
    /// The window's active tab is deactivated at most once, before any
    /// teardown, if it is among the victims (read via
    /// `windowSession.activeGroup?.activeTabID`, AFTER the prompts: they
    /// pump the main queue, so the active tab/group can change while they
    /// are up). It is then activated at most once afterwards, never once
    /// per victim or per emptied group. When several emptied groups chain
    /// through `WindowSession.removeGroup`'s active-group migration (each
    /// emptied active group hands activity to its neighbour in turn), no
    /// intermediate group is ever activated by this loop -- only the
    /// surviving group at the end, via the single closing
    /// `activateCurrentTab()` call.
    ///
    /// Closing every tab of a group empties it: `WindowSession.removeTab`
    /// removes the group and, only if it was the active group, moves
    /// activity to a neighbour, per `removeGroup`'s own rule. Removing an
    /// already-empty group in `emptyGroups` follows the same rule. The
    /// window closes when no group remains, or when the surviving active
    /// group itself has no active tab (an empty group being the only
    /// survivor is included in that second case). Otherwise, the
    /// surviving active group always has an active tab by the time
    /// `activateCurrentTab()` runs, and that call rebuilds the hosting
    /// view so the closed tabs leave the tab bar. When the active tab
    /// survives unchanged, the hosting view is refreshed here instead,
    /// and the Changes sidebar is refreshed alongside it when visible
    /// (the same `.tabActivated` refresh `activateCurrentTab()` runs).
    func closeTabs(_ victims: [(tab: Tab, group: TabGroup)], removingEmptyGroups emptyGroups: [TabGroup] = []) {
        let candidates = victims.filter { !closingTabIDs.contains($0.tab.id) }
        for victim in candidates { closingTabIDs.insert(victim.tab.id) }
        let tabsToClose = candidates.filter { victim in
            if confirmClosingDespiteUnsubmittedReviewComments(victim.tab) { return true }
            closingTabIDs.remove(victim.tab.id)
            return false
        }
        guard !tabsToClose.isEmpty || !emptyGroups.isEmpty else { return }

        // Read after the prompts: the prompts pump the main queue, so the
        // active tab and group can change while they are up.
        let activeGroupIDBefore = windowSession.activeGroupID
        let activeTabIDBefore = windowSession.activeGroup?.activeTabID
        let activeIsVictim = tabsToClose.contains { $0.tab.id == activeTabIDBefore }
        if activeIsVictim {
            deactivateCurrentTab()
        }

        for victim in tabsToClose {
            releaseTabResources(victim.tab)
            windowSession.removeTab(id: victim.tab.id, fromGroup: victim.group.id)
        }
        for victim in tabsToClose { closingTabIDs.remove(victim.tab.id) }

        for group in emptyGroups {
            guard let current = windowSession.groups.first(where: { $0.id == group.id }), current.tabs.isEmpty else { continue }
            windowSession.removeGroup(id: group.id)
        }

        if windowSession.groups.isEmpty || windowSession.activeGroup?.activeTab == nil {
            closeLastWindow()
            requestSave()
            return
        }
        if activeIsVictim || windowSession.activeGroupID != activeGroupIDBefore {
            activateCurrentTab()
        } else {
            refreshHostingView()
            if isGitChangesSidebarVisible {
                refreshGitSidebar(trigger: .tabActivated)
            }
        }
        requestSave()
    }

    /// Closes `victims`, which must all belong to `group`, in one batch.
    /// A thin wrapper over the multi-group core above.
    ///
    /// Not `private`: `CalyxWindowControllerProcessCloseTabBatchTests`
    /// calls this directly.
    func closeTabs(_ victims: [Tab], in group: TabGroup) {
        closeTabs(victims.map { (tab: $0, group: group) })
    }

    /// Closes every tab of every group in `groups`, in one batch, in the
    /// given group order (tabs within a group close in their existing
    /// order). `closeGroups(relativeTo:mode:)` below resolves its victim
    /// groups and calls this.
    func closeGroups(_ groups: [TabGroup]) {
        closeTabs(
            groups.flatMap { group in group.tabs.map { (tab: $0, group: group) } },
            removingEmptyGroups: groups.filter { $0.tabs.isEmpty }
        )
    }

    /// The shared entry for closing one or more groups: resolves `mode`
    /// against `windowSession.groups`' current order, relative to
    /// `groupID`, and closes the resulting groups in one batch. Backs the
    /// group context menu's "Close Other Groups" (`.others`) and "Close
    /// Groups Below" (`.below`), and the single-group paths
    /// `closeAllTabsInGroup(id:)` and `closeActiveGroup()` (`.this`). An
    /// unknown `groupID` (not present in `windowSession.groups`) is a
    /// no-op.
    func closeGroups(relativeTo groupID: UUID, mode: GroupCloseMode) {
        let groups = windowSession.groups
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        switch mode {
        case .this:
            closeGroups([groups[index]])
        case .others:
            closeGroups(groups.filter { $0.id != groupID })
        case .below:
            closeGroups(Array(groups[(index + 1)...]))
        }
    }

    /// The tab context menu's entry into `processCloseTab(tab:group:mode:)`.
    /// Resolves the right-clicked tab's owning group by `tabID` and
    /// delegates; an unknown `tabID` (no group contains it) is a no-op.
    func closeTabs(relativeTo tabID: UUID, mode: ghostty_action_close_tab_mode_e) {
        guard let (tab, group) = windowSession.groups.tabAndGroup(tabID: tabID) else { return }
        processCloseTab(tab: tab, group: group, mode: mode)
    }

    @objc private func handleCloseTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, owningGroup) = findTab(for: surfaceView) else { return }
        guard let mode = notification.userInfo?["mode"] as? ghostty_action_close_tab_mode_e else { return }
        processCloseTab(tab: owningTab, group: owningGroup, mode: mode)
    }

    #if DEBUG
    /// Test seam: mirrors `AppDelegate`'s
    /// `_focusWindowForExistingSessionShowHookForTesting` — a hook placed
    /// immediately before the actually-unsafe-to-drive-in-tests call
    /// (here, `window?.performClose(nil)`, which really closes the
    /// window). `nil` (the default) leaves production behavior unchanged.
    /// DO NOT use from production code.
    var _processCloseWindowHookForTesting: (() -> Void)?
    #endif

    /// `.ghosttyCloseWindow` (`GHOSTTY_ACTION_CLOSE_WINDOW`, close_window
    /// keybind) receiver. Takes no parameters: `handleCloseWindowNotification`
    /// below decides whether THIS window should react (via `findTab(for:)`
    /// on the posted surface, or key-window status for an app-targeted
    /// broadcast with no surface at all) BEFORE ever calling this method.
    ///
    /// `window?.performClose(nil)`, NOT `window?.close()`: stale doc note
    /// corrected — this controller no longer implements
    /// `windowShouldClose(_:)` (removed in `95cfcebff`, window-lifetime
    /// redesign), so there is no per-window confirm-quit gate on this
    /// path any more, and the unsent-review-comments guard
    /// (`closeTab(id:)`'s own `NSAlert`) does not apply here either —
    /// `windowWillClose` below tears down every tab directly, never
    /// through `closeTab(id:)`. `performClose(nil)` is kept anyway as
    /// the ordinary, user-initiated-close entry point: it respects the
    /// `.closable` style mask exactly like a real click on the Close
    /// button/menu item would, which plain `close()` does not.
    func processCloseWindow() {
        #if DEBUG
        if let hook = _processCloseWindowHookForTesting {
            hook()
            return
        }
        #endif
        window?.performClose(nil)
    }

    @objc private func handleCloseWindowNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard findTab(for: surfaceView) != nil else { return }
        } else {
            // App-targeted broadcast (GHOSTTY_TARGET_APP, no surface) —
            // only the key window should react, mirroring
            // handleEqualizeSplitsNotification's established nil-object
            // passthrough shape (conditionally unwrap, guard inside).
            guard window?.isKeyWindow == true else { return }
        }
        processCloseWindow()
    }

    // MARK: - calyxPerformClose (GitHub issue #45)
    //
    // `CalyxWindow.calyxPerformClose(_:)`'s intended receiver (once
    // implemented — see that method's own doc comment and
    // `NSWindow+CalyxClose.swift`'s header for the full root-cause
    // writeup of why Cmd+W needs its own selector distinct from
    // `closeTab(_:)`). `closeFocusedTarget` is the pure decision of
    // WHICH of this window's focused pane/tab/window Cmd+W should
    // actually close; `performCloseFocusedTarget` is its effectful
    // caller, invoked from `CalyxWindow.calyxPerformClose(_:)` via
    // `window?.windowController as? CalyxWindowController` (mirrors
    // `SurfaceView.isActiveTabSplit`'s identical reverse lookup).

    /// `CloseFocusedTarget` (top-level, near `TitlePromptScope` above)
    /// is this pure function's return type — see its own doc comment
    /// for the full decision contract.
    ///
    /// Pure function (testable). Same existing idiom as
    /// `AppDelegate.matchKeyEvent` / `adjacentWindowIndex` /
    /// `CalyxWindow.shouldPerformZoom`.
    static func closeFocusedTarget(tabID: UUID?, content: TabContent?, focusedLeafID: UUID?) -> CloseFocusedTarget {
        guard let tabID else { return .window }
        guard case .terminal = content, let focusedLeafID else { return .tab(tabID) }
        return .surface(tabID: tabID, surfaceID: focusedLeafID)
    }

    /// Effectful caller of `closeFocusedTarget` above, using THIS
    /// window's own `activeTab`/`activeTab.splitTree.focusedLeafID` as
    /// its inputs.
    ///
    /// `.surface` closes via `GhosttySurfaceController.requestClose()`,
    /// never `closeSurfaceAndCleanUp` directly: `requestClose()` asks
    /// libghostty itself to close the pane — the exact same entry point
    /// the `close_surface` keybind drives — which eventually fires
    /// ghostty's own close callback (`.ghosttyCloseSurface`) back into
    /// `processCloseSurface`/`closeSurfaceAndCleanUp`. Calling
    /// `closeSurfaceAndCleanUp` here directly would bypass libghostty's
    /// own close handling and create a second, redundant teardown path.
    ///
    /// `.tab` closes via the existing `closeTab(id:)`, not
    /// `closeSurfaceAndCleanUp`: `closeTab(id:)` is the one place the
    /// unsent-review-comments guard (diff tabs, its own `NSAlert`) lives
    /// — routing a whole-tab close any other way would silently drop
    /// that warning.
    ///
    /// `.window` closes via `window?.performClose(sender)`, never
    /// `closeLastWindow()` directly: `closeSurfaceAndCleanUp`/
    /// `closeTab(id:)` already call `closeLastWindow()` themselves once
    /// they empty the window, so `.window` here only fires for a window
    /// that has NO active tab at all to begin with — a real
    /// `performClose` is the correct, ordinary close for that case,
    /// matching `.ghosttyCloseWindow`'s own `processCloseWindow()`.
    func performCloseFocusedTarget(_ sender: Any?) {
        let target = Self.closeFocusedTarget(
            tabID: activeTab?.id,
            content: activeTab?.content,
            focusedLeafID: activeTab?.splitTree.focusedLeafID
        )
        #if DEBUG
        if let hook = _closeFocusedTargetHookForTesting {
            hook(target)
            return
        }
        #endif
        switch target {
        case .surface(_, let surfaceID):
            activeTab?.registry.controller(for: surfaceID)?.requestClose()
        case .tab(let tabID):
            closeTab(id: tabID)
        case .window:
            window?.performClose(sender)
        }
    }

    #if DEBUG
    /// Test seam: mirrors `_processCloseWindowHookForTesting`'s exact
    /// "hook right before the actually-unsafe-to-drive-in-tests real
    /// close" shape, carrying the `CloseFocusedTarget`
    /// `performCloseFocusedTarget` computed so a test can assert WHICH
    /// target it resolved without a real surface/tab/window close
    /// running. `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _closeFocusedTargetHookForTesting: ((CloseFocusedTarget) -> Void)?

    /// Test seam: overrides "is THIS window actually the key window"
    /// for `validateMenuItem`'s menu-enabling decisions, mirroring
    /// `_setHasAppliedInitialSizeForTesting`'s override-seam shape. A
    /// fixture's `CalyxWindow` is constructed but never shown/ordered
    /// front, so `window?.isKeyWindow` is always `false` in this test
    /// host (see `CalyxWindowControllerCloseWindowTests`'s own
    /// precondition assertion on exactly this) — this seam lets a test
    /// exercise BOTH the true and false branches of that gate without a
    /// real, driven-by-the-window-server key-window transition. `nil`
    /// (the default) leaves production behavior unchanged (falls back
    /// to the real `window?.isKeyWindow`). DO NOT use from production
    /// code.
    var _isKeyWindowOverrideForTesting: Bool?
    #endif

    #if DEBUG
    /// Test seam: see `_processCloseWindowHookForTesting`'s doc comment —
    /// same shape, guards `toggleFullScreen(nil)` (requires a real
    /// `NSScreen`; see `CalyxWindowControllerFullScreenTests.swift`'s
    /// header comment on why fullscreen transitions cannot be driven
    /// directly in tests). DO NOT use from production code.
    var _processToggleFullscreenHookForTesting: (() -> Void)?
    #endif

    /// `.ghosttyToggleFullscreen` (`GHOSTTY_ACTION_TOGGLE_FULLSCREEN`,
    /// Ctrl+Cmd+F / Cmd+Enter keybind) receiver. `mode` is
    /// `ghostty_action_fullscreen_e?` (optional: the notification handler
    /// may not always find a `"mode"` key in `userInfo`). Calyx implements
    /// only NATIVE fullscreen (`toggleFullScreen(nil)`, reusing the
    /// existing menu-action wrapper below rather than calling
    /// `window?.toggleFullScreen` directly, so both entry points share one
    /// path) — `shouldUseNativeFullscreen(for:)` below is the pure,
    /// directly testable decision of whether a given `mode` should still
    /// trigger it; today that is unconditionally `true`, since there is no
    /// non-native fallback implemented.
    func processToggleFullscreen(mode: ghostty_action_fullscreen_e?) {
        guard Self.shouldUseNativeFullscreen(for: mode) else { return }
        #if DEBUG
        if let hook = _processToggleFullscreenHookForTesting {
            hook()
            return
        }
        #endif
        toggleFullScreen(nil)
    }

    @objc private func handleToggleFullscreenNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        let mode = notification.userInfo?["mode"] as? ghostty_action_fullscreen_e
        processToggleFullscreen(mode: mode)
    }

    /// Pure decision function backing `processToggleFullscreen(mode:)`,
    /// pulled out so the "non-native ghostty modes must still fall back
    /// to Calyx's one native implementation" contract is
    /// assertion-testable in one line, without a live `NSScreen`.
    /// `ghostty_action_fullscreen_e` (ghostty.h) has four cases:
    /// `GHOSTTY_FULLSCREEN_NATIVE`, `GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE`,
    /// `GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU`,
    /// `GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH`. Calyx has no
    /// non-native fullscreen presentation of its own, so EVERY mode
    /// (including `nil`, an action with no mode at all) resolves to "yes,
    /// use native" — the three non-native modes are logged (extension
    /// point for when/if Calyx grows a non-native presentation of its own)
    /// but still fall back to native rather than silently no-op'ing.
    static func shouldUseNativeFullscreen(for mode: ghostty_action_fullscreen_e?) -> Bool {
        if let mode, mode != GHOSTTY_FULLSCREEN_NATIVE {
            logger.info("Non-native fullscreen mode \(mode.rawValue) requested; Calyx has no non-native fullscreen presentation, falling back to native fullscreen")
        }
        return true
    }

    /// `.ghosttyInitialSize` (`GHOSTTY_ACTION_INITIAL_SIZE`) receiver —
    /// applies libghostty's requested initial content size to `window`.
    /// Three guards gate the resize (see `CalyxWindowControllerInitialSizeTests`):
    ///   - `!isRestoring`: during session restore, a persisted frame has
    ///     already been applied; re-applying ghostty's own initial size on
    ///     top would silently reset every user's restored window size on
    ///     every launch (the regression this guard exists to prevent).
    ///   - `!hasAppliedInitialSize`: `GHOSTTY_ACTION_INITIAL_SIZE` is not a
    ///     one-shot-at-creation action the way the surrounding comments
    ///     used to assume — ghostty's `recomputeInitialSize()`
    ///     (`ghostty/src/Surface.zig`) also re-fires it from `setCellSize`,
    ///     which `setFontSize` calls, which the default
    ///     increase_font_size/decrease_font_size/reset_font_size keybinds
    ///     AND every config hot-reload (`updateConfig`) both trigger.
    ///     Without this guard, changing font size (or just saving the
    ///     config file) on a single-pane window would silently snap a
    ///     user's manual resize back to `window-width`/`window-height`.
    ///     `hasAppliedInitialSize` is set once this method actually
    ///     resizes, is seeded `true` (not `false`) for a restoring window
    ///     (see its own doc comment), and is never otherwise reset in
    ///     production — so it protects BOTH a fresh window (after its own
    ///     first successful application) AND a restored/reattached one
    ///     (from the moment it's constructed, before `isRestoring` even
    ///     flips) from any later re-fire. Matches both other ghostty
    ///     reference apprts, which apply this value exactly once, only
    ///     pre-show (macOS: `TerminalController`/`Ghostty.App` read
    ///     `surfaceView.initialSize` once while computing the window's
    ///     `defaultSize`; GTK: `setDefaultSize` only affects an
    ///     as-yet-unrealized window).
    ///   - exactly one group, one tab, one pane
    ///     (`tab.splitTree.allLeafIDs().count == 1`, `group.tabs.count ==
    ///     1`, `windowSession.groups.count == 1`): a second tab/pane
    ///     appearing later in the window's life must not cause the window
    ///     to jump back to ghostty's single-surface initial size.
    func applyInitialSize(_ size: NSSize) {
        guard !isRestoring, !hasAppliedInitialSize else { return }
        guard windowSession.groups.count == 1,
              let group = windowSession.groups.first,
              group.tabs.count == 1,
              let tab = group.tabs.first,
              tab.splitTree.allLeafIDs().count == 1 else { return }

        window?.setContentSize(size)
        hasAppliedInitialSize = true
        requestSave()
    }

    /// Recovers the very first surface's `GHOSTTY_ACTION_INITIAL_SIZE`,
    /// which `GhosttyActionRouter.handleInitialSize` fires synchronously
    /// from inside `ghostty_surface_new` — i.e. from inside
    /// `setupTerminalSurface` just above in `init` — before
    /// `registerNotificationObservers()` has had a chance to register
    /// `.ghosttyInitialSize`'s observer. Without this, a brand-new
    /// window's initial size (as opposed to one restored from a
    /// persisted frame, which never reaches this branch — see `init`'s
    /// own `if !restoring` guard) would be silently dropped.
    /// `GhosttyActionRouter.handleInitialSize` stores the requested size
    /// onto the just-created `SurfaceView` itself (`SurfaceView
    /// .initialSize`) precisely so it can be recovered here, mirroring
    /// `handleCellSize`'s identical store-on-the-view-then-post-too shape
    /// (`SurfaceView.cachedCellSize`). Delegates the actual decision to
    /// `applyInitialSize(_:)`'s own guards (single group/tab/pane,
    /// `!isRestoring`) so that contract lives in exactly one place; a
    /// failed `setupTerminalSurface` (no surface ever created) is a safe
    /// no-op via the `tab.registry.view(for:)` lookup below.
    private func applyPendingInitialSizeFromFirstSurface() {
        guard let tab = activeTab,
              let leafID = tab.splitTree.allLeafIDs().first,
              let surfaceView = tab.registry.view(for: leafID),
              let size = surfaceView.initialSize else { return }
        applyInitialSize(size)
    }

    @objc private func handleInitialSizeNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let width = notification.userInfo?["width"] as? UInt32,
              let height = notification.userInfo?["height"] as? UInt32 else { return }
        applyInitialSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
    }

    /// `.ghosttyRendererHealth` (`GHOSTTY_ACTION_RENDERER_HEALTH`)
    /// receiver — mirrors `healthy` onto `surfaceView.isRendererHealthy`
    /// (`SurfaceView.swift`) unconditionally (no ownership check of its
    /// own, mirroring `processCloseSurface`'s identical shape: routing
    /// lives in `handleRendererHealthNotification` below). When
    /// unhealthy, additionally logs and — if this window can resolve the
    /// surface's owning tab — surfaces a user-facing notification via
    /// `NotificationManager`; pane-level overlay presentation is out of
    /// scope here.
    func processRendererHealth(surfaceView: SurfaceView, healthy: Bool) {
        surfaceView.isRendererHealthy = healthy
        guard !healthy else { return }

        logger.error("Renderer reported unhealthy for a surface")
        guard let (tab, _) = findTab(for: surfaceView) else { return }
        NotificationManager.shared.sendNotification(
            title: "Rendering Issue",
            body: "This pane's renderer reported a problem. Try resizing the window, or restart Calyx if " +
                  "the display looks wrong.",
            tabID: tab.id
        )
    }

    @objc private func handleRendererHealthNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let health = notification.userInfo?["health"] as? ghostty_action_renderer_health_e else { return }
        processRendererHealth(surfaceView: surfaceView, healthy: health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
    }

    // MARK: - Keybind Actions (continued)
    //
    // A second batch of GHOSTTY_ACTION_* cases: SET_TAB_TITLE,
    // COPY_TITLE_TO_CLIPBOARD, TOGGLE_COMMAND_PALETTE, MOVE_TAB,
    // TOGGLE_MAXIMIZE, RESET_WINDOW_SIZE. `GhosttyActionRouter` fully
    // routes and posts all six (GhosttyAction.swift's own "MARK: - Keybind
    // Actions" section), and each `process*` method below
    // has a real body, but each also needs its own
    // `addObserver` in `registerNotificationObservers()`, the same gap
    // fixed above for the first batch: ghostty's default set_tab_title /
    // copy_title_to_clipboard / toggle_command_palette / move_tab /
    // toggle_maximize / reset_window_size keybinds go silently inert
    // regardless of `process*` being fully implemented, since nothing ever
    // calls it from a real notification post without that observer.
    //
    // `registerNotificationObservers()` above registers a matching
    // `@objc private func handleXxxNotification` for each, defined right
    // next to its `process*` counterpart below, mirroring the first
    // batch's shape above. See the sibling test files
    // (CalyxWindowControllerSetTabTitleTests, CopyTitleToClipboardTests,
    // ToggleCommandPaletteTests, MoveTabTests, ToggleMaximizeTests,
    // ResetWindowSizeTests) for the contract each satisfies: both the
    // direct `process*` call and, in each file's own "Notification post
    // (Tactic A)" section, the end-to-end notification-post path, and
    // `TabGroup.moveTab(fromIndex:by:)` for the pure wrap arithmetic
    // `processMoveTab` delegates to.
    //
    // Destination resolution for every `handleXxxNotification` below again
    // uses `findTab(for:)`, not `belongsToThisWindow(_:)`: see the first
    // batch's header comment above for why.

    /// `.ghosttySetTabTitle` (`GHOSTTY_ACTION_SET_TAB_TITLE`) receiver,
    /// reusing `ghostty_action_set_title_s` (ghostty.h: `set_tab_title` and
    /// `set_title` share one payload type, just a different union tag).
    /// Sets `tab.titleOverride` to `title`, or `nil` for an empty string
    /// (mirrors ghostty's own prompt_surface_title "empty clears back to
    /// the default" convention). `refreshHostingView()` is required (not
    /// automatic — see this file's own "mutate observable state, then
    /// explicitly refresh" convention on `refreshRecoveryBar()`'s doc
    /// comment): the TabBar/Sidebar read `tab.displayTitle`.
    /// `requestSave()` persists it into `TabSnapshot.titleOverride`.
    func processSetTabTitle(tab: Tab, title: String) {
        tab.titleOverride = title.isEmpty ? nil : title
        refreshHostingView()
        requestSave()
    }

    @objc private func handleSetTabTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        processSetTabTitle(tab: owningTab, title: title)
    }

    /// `.ghosttyCopyTitleToClipboard` (`GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD`)
    /// receiver. Copies `tab.displayTitle` via `clipboardWriter`, writing
    /// nothing when that resolved title is empty (an empty clipboard write
    /// would silently clobber whatever the user last copied, for no
    /// useful payload).
    func processCopyTitleToClipboard(tab: Tab) {
        let resolvedTitle = tab.displayTitle
        guard !resolvedTitle.isEmpty else { return }
        clipboardWriter.copyToClipboard(resolvedTitle)
    }

    @objc private func handleCopyTitleToClipboardNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        processCopyTitleToClipboard(tab: owningTab)
    }

    /// `.ghosttyToggleCommandPalette` (`GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE`)
    /// receiver. Delegates to the existing `toggleCommandPalette()`, which
    /// already performs its own `refreshHostingView()`-free toggle (its
    /// existing menu-item and key-monitor entry points both already work
    /// without one).
    func processToggleCommandPalette() {
        toggleCommandPalette()
    }

    @objc private func handleToggleCommandPaletteNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        processToggleCommandPalette()
    }

    /// `.ghosttyMoveTab` (`GHOSTTY_ACTION_MOVE_TAB`) receiver. `tab`/`group`
    /// are the pane's owning tab/group, already resolved by
    /// `handleMoveTabNotification` below via `findTab(for:)` — this method
    /// itself has no routing/ownership logic of its own, mirroring
    /// `processCloseTab`'s identical shape. `amount` is
    /// `ghostty_action_move_tab_s.amount` (`ssize_t`, ghostty.h). Resolves
    /// `tab`'s current index within `group.tabs` (a no-op if `tab` is
    /// somehow not a member of `group`) and delegates to `group.moveTab
    /// (fromIndex:by:)` for the actual reorder (wrap, not clamp — see that
    /// method's own doc comment). `refreshHostingView()` + `requestSave()`
    /// mirror `processCloseTab`'s sibling `closeTab(id:)` call chain's own
    /// eventual UI refresh/persistence.
    func processMoveTab(tab: Tab, group: TabGroup, amount: Int) {
        guard let fromIndex = group.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        group.moveTab(fromIndex: fromIndex, by: amount)
        refreshHostingView()
        requestSave()
    }

    @objc private func handleMoveTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, owningGroup) = findTab(for: surfaceView) else { return }
        guard let amount = notification.userInfo?["amount"] as? Int else { return }
        processMoveTab(tab: owningTab, group: owningGroup, amount: amount)
    }

    /// `.ghosttyToggleMaximize` (`GHOSTTY_ACTION_TOGGLE_MAXIMIZE`) receiver.
    /// Calls `window?.performZoom(nil)`, guarded on both `!trackedFullScreen`
    /// (this controller's own tracked state) AND `!styleMask.contains
    /// (.fullScreen)` (the live AppKit state) — macOS zoom and fullscreen
    /// are mutually confusing to combine, and `performZoom` has no
    /// well-defined target frame while already fullscreen. Mirrors
    /// `CalyxWindow`'s own identical double-guard on its double-click-to-
    /// zoom title bar handler (`CalyxWindow.swift`).
    func processToggleMaximize() {
        guard !trackedFullScreen else { return }
        guard !(window?.styleMask.contains(.fullScreen) ?? false) else { return }
        window?.performZoom(nil)
    }

    @objc private func handleToggleMaximizeNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        processToggleMaximize()
    }

    /// `.ghosttyResetWindowSize` (`GHOSTTY_ACTION_RESET_WINDOW_SIZE`)
    /// receiver. Calls `window?.setContentSize(Self.defaultContentSize)`
    /// followed by `window?.center()`, mirroring this controller's own
    /// fresh-window `convenience init` default. Guarded identically to
    /// `processToggleMaximize` above (`trackedFullScreen` AND
    /// `styleMask.contains(.fullScreen)`): resizing the content area while
    /// natively fullscreen has no well-defined meaning either.
    /// `requestSave()` persists the new frame.
    func processResetWindowSize() {
        guard !trackedFullScreen else { return }
        guard !(window?.styleMask.contains(.fullScreen) ?? false) else { return }
        window?.setContentSize(Self.defaultContentSize)
        window?.center()
        requestSave()
    }

    @objc private func handleResetWindowSizeNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        processResetWindowSize()
    }

    // MARK: - Prompt Title (GHOSTTY_ACTION_PROMPT_TITLE, GitHub issue #42)
    //
    // prompt_tab_title/prompt_surface_title keybinds. `GhosttyActionRouter
    // .handlePromptTitle` (GhosttyAction.swift) posts `.ghosttyPromptTitle`
    // for `GHOSTTY_ACTION_PROMPT_TITLE`, `registerNotificationObservers()`
    // above registers `handlePromptTitleNotification` for it, and both
    // methods below have real bodies, wired the same way as the two
    // keybind-action batches above. See `CalyxWindowControllerPromptTitleTests` for the
    // direct-call contract and that file's own "Notification post (Tactic
    // A)" section for the end-to-end wiring test.

    /// Which of the two independent, per-`Tab` `@State isEditing` rename
    /// UIs (`TabBarContentView`'s `TabItemButton`, `SidebarContentView`'s
    /// `TabRowItemView` — both can render the SAME `tab` at once, see
    /// `TabRenameHost`'s own doc comment) should handle `tab`'s inline
    /// rename, or `nil` if neither currently renders it. Reads only
    /// `windowSession.activeGroupID`/`showSidebar`/`sidebarMode` plus the
    /// passed-in `group`'s own `isCollapsed` — no other `self` access, so
    /// this is directly unit-testable against a bare `tab`/`group` pair
    /// that need not even be members of `windowSession.groups`.
    ///
    /// Not `private`: mirrors `processChildExited`'s own "Not `private`"
    /// doc comment — `CalyxWindowControllerPromptTitleTests` calls this
    /// directly.
    ///
    /// The active-group check runs FIRST so it wins even when the sidebar
    /// ALSO renders the same `tab` at once — see `TabRenameHost`'s own doc
    /// comment on the double-open hazard a wrong ordering (or a caller
    /// passing a `tab`/`group` pair that doesn't actually match) would
    /// otherwise risk.
    ///
    /// `sidebarMode == .tabs` is required, not just `windowSession
    /// .showSidebar && !group.isCollapsed`: `SidebarContentView`'s
    /// group/tab tree (where `TabRowItemView` lives) only renders inside
    /// `switch sidebarMode { case .tabs: ... }` — while `sidebarMode` is
    /// `.changes` or `.agents`, the sidebar shows `GitChangesView`/
    /// `AgentStatusView` instead, and no `TabRowItemView` exists for `tab`
    /// at all regardless of `showSidebar`/`isCollapsed`. Every current
    /// caller reaches this method for the keybind-focused surface, which
    /// is always the active group's active tab (so it always resolves via
    /// the `.tabBar` branch above and never reaches this check) — but
    /// `renameHost` is a general `tab`/`group` function, not itself
    /// focus-scoped, so a future caller (e.g. a sidebar row's own "Rename"
    /// context-menu item) must not have its request silently dropped just
    /// because the sidebar happens to be showing Git changes or Agents at
    /// that moment.
    func renameHost(for tab: Tab, in group: TabGroup) -> TabRenameHost? {
        if group.id == windowSession.activeGroupID {
            return .tabBar
        }
        if windowSession.showSidebar && !group.isCollapsed && windowSession.sidebarMode == .tabs {
            return .sidebar
        }
        return nil
    }

    /// `.ghosttyPromptTitle` (`GHOSTTY_ACTION_PROMPT_TITLE`, `prompt_title`
    /// union member: `GHOSTTY_PROMPT_TITLE_SURFACE` / `_TAB`) receiver, via
    /// `handlePromptTitleNotification` below. `scope` mirrors that C enum
    /// via `TitlePromptScope` (see its own doc comment for why v1 collapses
    /// both cases onto the same tab-level rename — this method does not
    /// switch on `scope` at all; it is threaded through only so a future
    /// per-pane title editor has a single call site to add a case to).
    ///
    /// Not `private` (mirrors `processChildExited`'s own "Not `private`"
    /// doc comment): `CalyxWindowControllerPromptTitleTests` calls this
    /// directly with a `_testInsert`-only `SurfaceView` never attached to a
    /// real window. Ownership is enforced by `findTab(for:)` below either
    /// way — there is no separate `belongsToThisWindow` guard to bypass
    /// (see `handlePromptTitleNotification`'s own doc comment for why).
    ///
    /// No `requestSave()`: `renameRequest` is transient UI-routing state,
    /// deliberately excluded from `Tab.snapshot()` (see its own doc
    /// comment), so persisting it here would be a bug, not an omission.
    func processPromptTitle(surfaceView: SurfaceView, scope: TitlePromptScope) {
        guard let (tab, group) = findTab(for: surfaceView) else { return }
        guard let host = renameHost(for: tab, in: group) else { return }
        tab.renameRequest = TabRenameRequest(id: UUID(), host: host)
        refreshHostingView()
    }

    /// Destination resolution uses `findTab(for:)` (inside
    /// `processPromptTitle` above), not `belongsToThisWindow(_:)`: mirrors
    /// every other handler in both keybind-action batches above
    /// (their own header comments explain why). A `SurfaceView` this
    /// window doesn't own resolves to `findTab(for:) == nil` inside
    /// `processPromptTitle`, which already no-ops, so a second ownership
    /// check here would be redundant.
    @objc private func handlePromptTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        let scope = (notification.userInfo?["scope"] as? String)
            .flatMap(TitlePromptScope.init(rawValue:)) ?? .tab
        processPromptTitle(surfaceView: surfaceView, scope: scope)
    }

    /// Single choke point pairing the
    /// isConfirmingQuit guard with the deferred-event enqueue, so a
    /// future handler cannot separate them. Runs
    /// `body` immediately unless `AppDelegate.isConfirmingQuit` is true,
    /// in which case `event` is appended to `deferredReconnectEvents`
    /// instead (replayed once the gate clears, see
    /// `drainDeferredReconnectEvents`'s doc comment). A replay that
    /// re-enters this same primitive (directly, or via a public handler
    /// that calls it) re-defers instead of applying early when it lands
    /// during a second, already-active modal.
    private func deferOrRun(_ event: DeferredReconnectEvent, _ body: () -> Void) {
        guard !((NSApp.delegate as? AppDelegate)?.isConfirmingQuit ?? false) else {
            deferredReconnectEvents.append(event)
            return
        }
        body()
    }

    /// Replays events deferred by `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision`/`handleCloseSurfaceNotification`
    /// while `AppDelegate.isConfirmingQuit` was `true`, once the gate
    /// clears. Called from that flag's own `didSet` (see its doc
    /// comment), which covers both the real `confirmQuitIfNeeded` return
    /// path and the `_setConfirmingQuitForTesting` test seam.
    ///
    /// Scheduled
    /// on a fresh MainActor turn (rather than run synchronously inside
    /// the `didSet`) so the caller's own stack (e.g.
    /// `applicationShouldTerminate` -> `confirmQuitIfNeeded` ->
    /// `alert.runModal()` returning once the user cancels Cmd+Q) has
    /// fully unwound, and `applicationShouldTerminate`'s own handling of
    /// that `false` return (returning `.terminateCancel`, with neither
    /// `markAllControllersClosingForShutdown()` nor `isApplicationTerminating`
    /// ever set) has finished, before any replay lands. A deferred event
    /// whose surface no longer resolves in this window (closed some
    /// other way while the gate was up) is a safe no-op: `findTab`/
    /// `findTabAndGroup` (reached via `processChildExited`/
    /// `handleSessionReconnectDecision`'s own existing lookups) already
    /// treat a stale ID that way.
    @objc private func handleConfirmingQuitDidEnd(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.drainDeferredReconnectEvents()
        }
    }

    /// Bails out entirely, without
    /// touching the queue, while this window or the app itself is
    /// shutting down (`isShuttingDown`): replaying on top of quit
    /// teardown that already preserved tracking state into the snapshot
    /// is both unnecessary and dangerous.
    ///
    /// All three cases below follow the
    /// SAME single pattern, replaying exactly what a live, real-time
    /// occurrence of that event would have done, with the SAME gating.
    /// For `.decision`, that means calling the public
    /// `handleSessionReconnectDecision` handler directly: its own
    /// `isShuttingDown` guard re-applies "for free" before it re-enters
    /// `deferOrRun`. For `.childExited`/`.closeSurface`, it means
    /// calling their PRIVATE processing function
    /// (`processChildExited`/`processCloseSurface`) wrapped in
    /// `deferOrRun` here, rather than their `@objc` public handler
    /// (`handleShowChildExitedNotification`/`handleCloseSurfaceNotification`),
    /// since those need an actual `Notification` to unwrap and this
    /// call site already has the unwrapped `SurfaceView`; that
    /// difference is purely mechanical, NOT a gating difference, since
    /// each public handler's own gating lives in the exact function this
    /// replays: `processChildExited` re-checks `isShuttingDown` itself
    /// (so it's exactly as gated as `handleShowChildExitedNotification`,
    /// which calls nothing else first), and `handleCloseSurfaceNotification`
    /// deliberately has NO `isShuttingDown` gate of its own (see its own
    /// doc comment), so `processCloseSurface` having none either is the
    /// SAME behavior, not a missing one.
    private func drainDeferredReconnectEvents() {
        guard !isShuttingDown else { return }
        guard !deferredReconnectEvents.isEmpty else { return }
        let events = deferredReconnectEvents
        deferredReconnectEvents.removeAll()
        for event in events {
            switch event {
            case .childExited(let surfaceView):
                deferOrRun(event) { [weak self] in self?.processChildExited(surfaceView: surfaceView) }
            case .decision(let surfaceID, let decision):
                handleSessionReconnectDecision(surfaceID: surfaceID, decision: decision)
            case .closeSurface(let surfaceView):
                deferOrRun(event) { [weak self] in self?.processCloseSurface(surfaceView: surfaceView) }
            }
        }
    }

    /// Not `private`: `SessionReconnectGiveUpTests`
    /// calls this directly to drive the `.giveUp` case end-to-end
    /// without needing a live daemon to actually exhaust
    /// `maxReconnectAttempts`, matching the existing direct-query test
    /// style (`commandRegistry`, `_testInsert`) this codebase favors
    /// over driving real UI. The real production call site remains
    /// `sessionReconnectCoordinator`'s `onDecision` closure.
    func handleSessionReconnectDecision(surfaceID: UUID, decision: SessionReconnectDecision) {
        // Bail out
        // entirely while this window or the app itself is shutting
        // down, BEFORE even considering deferral: a decision arriving
        // (or replaying) once the app is genuinely terminating must
        // never be queued either, since windowWillClose's teardown
        // already preserved tracking state into the snapshot.
        guard !isShuttingDown else { return }

        // A `.giveUp`/`.closePane` decision already in flight (queried from
        // the daemon before a confirm-quit modal started) must not dispatch
        // into teardown while that modal is pumping the MainActor -- see
        // `AppDelegate.isConfirmingQuit`'s header comment. Deferred,
        // not dropped, replayed once the gate
        // clears (see `deferredReconnectEvents`'s doc comment).
        deferOrRun(.decision(surfaceID: surfaceID, decision: decision)) { [weak self] in
            self?.dispatchReconnectDecision(surfaceID: surfaceID, decision: decision)
        }
    }

    private func dispatchReconnectDecision(surfaceID: UUID, decision: SessionReconnectDecision) {
        switch decision {
        case .closePane:
            closeDeadPersistentSessionSurface(surfaceID: surfaceID)
        case .reconnect(let sessionID, let attempt):
            scheduleReconnect(surfaceID: surfaceID, sessionID: sessionID, attempt: attempt)
        case .giveUp:
            handleReconnectGiveUp(surfaceID: surfaceID)
        }
    }

    /// The daemon confirmed the session's child process actually
    /// exited — close the pane exactly as an ordinary ghostty-driven
    /// close would (see `closeSurfaceAndCleanUp`'s doc comment).
    private func closeDeadPersistentSessionSurface(surfaceID: UUID) {
        guard let (tab, group) = findTabAndGroup(surfaceID: surfaceID) else { return }
        closeSurfaceAndCleanUp(tab: tab, group: group, surfaceID: surfaceID)
    }

    /// Reconnect attempts for `surfaceID`'s session exceeded
    /// `maxReconnectAttempts` (`SessionReconnectDecision.giveUp`).
    /// Unlike `.closePane` (the daemon confirmed the session's process
    /// actually exited, so a full kill is correct), the daemon here was
    /// only ever reported unreachable — the underlying `calyx-session`
    /// daemon may still be legitimately running (e.g. slow to start),
    /// so this closes the pane with DETACH, not kill, semantics: the
    /// session survives, reattachable later from the session browser
    /// (`calyx-session ls --all` still lists it) or a future restore.
    ///
    /// Deliberately closes the pane now, through the same
    /// `closeSurfaceAndCleanUp` path `closeDeadPersistentSessionSurface`
    /// uses (with `killSessions: false`), rather than leaving it open:
    /// leaving a dead pane open does not prevent the
    /// last-pane/last-window quit cascade it might seem to avoid, it
    /// only defers that same cascade to whenever the user next
    /// presses a key on the dead pane, and ghostty may not even render
    /// an informative screen by then on a fast/abnormal exit. Closing
    /// deterministically here keeps cascade timing consistent with
    /// every other session-ending path.
    ///
    /// The condition below is `isLastPaneEverywhere` alone: closing this
    /// pane deterministically, the way the
    /// two-pane case below always has, is wrong specifically when it is
    /// the LAST pane app-wide, since that would silently close the user's
    /// only remaining window with no trace of why, right as they were
    /// waiting for a reconnect. So when `isLastPaneEverywhere`, this
    /// method does not close the pane at all: it does detach bookkeeping
    /// only (clearing `SessionSurfaceMap`/`tab.sessionRefs` tracking) and
    /// leaves the leaf in the split tree. The surface still shows
    /// ghostty's own child-exited state; a later keypress on it closes it
    /// through the ordinary `handleCloseSurfaceNotification` path, with
    /// `hasSession` now `false`, so no kill call and no data loss. The
    /// two-pane (and any other non-last-pane-everywhere) case below is
    /// unchanged: closing deterministically is safe there because it can
    /// never empty the window.
    ///
    /// The remaining close branch inserts `tab.id`
    /// into `closingTabIDs` before tearing the surface down, mirroring
    /// `closeFocusedSessionSurface`'s own insert (see its doc comment).
    ///
    /// A no-op if the pane was already closed by the user in the
    /// meantime (`findTabAndGroup` returns `nil`).
    ///
    /// Bails out
    /// entirely while this window or the app itself is shutting down,
    /// for the same reason `handleSessionReconnectDecision`'s identical
    /// guard does (this method is also reachable directly, from tests
    /// and potentially future callers, not only via that dispatcher).
    ///
    /// The kept-pane (last-pane-everywhere)
    /// branch also shows a persistent in-pane overlay (see
    /// `showReconnectGiveUpOverlay`'s doc comment): the macOS
    /// notification alone can silently vanish (permission not granted),
    /// and ghostty's own child-exited text is suppressed for this
    /// surface, leaving no other in-app signal.
    private func handleReconnectGiveUp(surfaceID: UUID) {
        guard !isShuttingDown else { return }
        guard let (tab, group) = findTabAndGroup(surfaceID: surfaceID) else { return }
        guard !closingTabIDs.contains(tab.id) else { return }

        if isLastPaneEverywhere(tab: tab, group: group) {
            logger.info("Reconnect exhausted for last pane app-wide; detaching without closing (see F1)")
            detachSessionIfPersistent(tab: tab, surfaceID: surfaceID)
            showReconnectGiveUpOverlay(tab: tab, surfaceID: surfaceID)
            sendReconnectGiveUpNotification(tabID: tab.id)
            return
        }

        closingTabIDs.insert(tab.id)

        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        logger.error("Reconnect attempts exhausted for session \(sessionID ?? "unknown", privacy: .public); detaching and closing pane")
        sendReconnectGiveUpNotification(tabID: tab.id)

        closeSurfaceAndCleanUp(
            tab: tab, group: group, surfaceID: surfaceID,
            killSessions: false,
            callerAlreadyClaimedClosingTabIDs: true
        )
        closingTabIDs.remove(tab.id)
    }

    /// Shared give-up notification
    /// text for both of `handleReconnectGiveUp`'s branches. Avoids claiming
    /// scrollback or running commands are lost, or that only a brand-new
    /// session with the same ID is possible: both are false in the
    /// reachable cases this fires for. `SessionReconnectCoordinator` feeds
    /// `.giveUp` from both `.running` and `.unreachable` daemon states
    /// (i.e. even when the daemon just confirmed the session is alive),
    /// the daemon-side PTY is `setsid()`'d (surviving the attach
    /// process disconnecting), and the session browser's `attach()`
    /// reattaches the SAME session, not a new one.
    private func sendReconnectGiveUpNotification(tabID: UUID) {
        NotificationManager.shared.sendNotification(
            title: "Session unreachable",
            body: "Calyx couldn't reattach this session, but it may still be running with its state intact. " +
                  "Reattach it from the session browser once the daemon is reachable again.",
            tabID: tabID
        )
    }

    /// A Calyx-side, persistent in-pane indication for
    /// `handleReconnectGiveUp`'s last-pane-everywhere branch, which keeps
    /// the pane open (detach bookkeeping only) instead of closing it.
    /// Ghostty's own child-exited text is
    /// suppressed for every surface (`GhosttyAction.swift`'s
    /// `show_child_exited` handling always returns `true`), the child
    /// process is dead so `sendText` goes nowhere, and the macOS
    /// notification alone can silently vanish if permission was never
    /// granted, so this overlay is the only remaining in-app signal. A
    /// no-op if the surface no longer resolves, or already has an
    /// overlay (idempotent against a duplicate call). Removed
    /// automatically once the surface is destroyed, since the overlay is
    /// a subview of the surface's own view.
    private func showReconnectGiveUpOverlay(tab: Tab, surfaceID: UUID) {
        guard let surfaceView = tab.registry.view(for: surfaceID) else { return }
        guard !surfaceView.subviews.contains(where: { $0 is GiveUpOverlayView }) else { return }
        let overlay = GiveUpOverlayView(frame: surfaceView.bounds)
        overlay.autoresizingMask = [.width, .height]
        surfaceView.addSubview(overlay)
    }

    /// Waits out `attempt`'s backoff delay, then re-attaches. A stale
    /// `surfaceID` (the pane was closed by the user in the meantime) is
    /// handled by `performReconnect`'s own `findTab` lookup coming back
    /// `nil`.
    private func scheduleReconnect(surfaceID: UUID, sessionID: String, attempt: Int) {
        let delaySeconds = Self.reconnectBackoffSeconds(forAttempt: attempt)
        Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            self?.performReconnect(oldSurfaceID: surfaceID, sessionID: sessionID)
        }
    }

    /// Re-runs `calyx-session attach --create` for `sessionID` in a
    /// fresh surface, then swaps it in for `oldSurfaceID` everywhere
    /// that referenced it: the split tree (`SplitTree.remapLeafIDs`,
    /// the same contract `AppDelegate.restoreTabSurfaces` uses),
    /// `tab.sessionRefs` (`remappingKeys`, so the next snapshot points
    /// at the live leaf), and `SessionSurfaceMap` (`replaceSurface`).
    /// `attach --create`'s idempotency is what makes this safe to retry
    /// on a daemon that turned out to be merely unreachable rather than
    /// truly gone.
    ///
    /// CRITICAL ordering: `SurfaceRegistry
    /// .destroySurface(_:)` synchronously re-enters ghostty's
    /// `close_surface` callback (`handleCloseSurfaceNotification` ->
    /// `closeSurfaceAndCleanUp`) from inside `requestClose()`, *before*
    /// this method returns. The remap/replace calls below run BEFORE
    /// `destroySurface(oldSurfaceID)` specifically so that reentrant
    /// call observes state that already points at `newSurfaceID`:
    /// `SessionSurfaceMap.shared.sessionID(for: oldSurfaceID)` is
    /// already `nil` (so `killSessionIfPersistent` naturally does not
    /// kill), and `oldSurfaceID` is already absent from `tab.splitTree`
    /// (so `SplitTree.remove(_:)` — verified by inspection — treats a
    /// leaf ID it can't find as a no-op and returns an unchanged tree
    /// with `focusTarget == nil`, so the reentrant `closeSurfaceAndCleanUp`
    /// tail becomes a harmless redundant layout refresh, not tree
    /// corruption). `reconnectingSurfaceIDs` adds a second, independent
    /// layer of defense in `killSessionIfPersistent` regardless of this
    /// ordering.
    /// Thin wrapper around the one actually-unsafe-to-test call
    /// `performReconnect` makes (`tab.registry.createSurface`, a real
    /// ghostty FFI surface), mirroring `AppDelegate.createRegistrySurface`'s
    /// identical wrapper/reasoning, so
    /// `_performReconnectSurfaceCreationHookForTesting` can intercept
    /// exactly that call and nothing else.
    private func createReconnectSurface(
        tab: Tab, app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?, command: String?
    ) -> UUID? {
        #if DEBUG
        if let hook = _performReconnectSurfaceCreationHookForTesting {
            return hook()
        }
        #endif
        return tab.registry.createSurface(app: app, config: config, pwd: pwd, command: command)
    }

    /// Positive-evidence check `performReconnect`'s grace
    /// `Task` consults immediately before `markEstablished`, alongside
    /// (not instead of) the existing surface-identity check -- see that
    /// call site's doc comment for why time and surface identity alone
    /// are insufficient. Mirrors `createReconnectSurface`'s
    /// hook-first/real-fallback shape: under `#if DEBUG`, a set
    /// `_reconnectGraceProbeForTesting` hook is consulted first, with a
    /// throwing hook collapsed to `.notEstablished` (fail-closed) rather
    /// than propagated. The real fallback reuses the existing bounded
    /// `listAllBounded()` race (already used by
    /// `SessionBrowserModel.refresh()`/`AppDelegate
    /// .fetchSessionsForAgentResume()`) against the same
    /// `SessionDaemonClient.shared` singleton `sessionReconnectCoordinator`
    /// already wires in, rather than adding a second daemon-query
    /// primitive. `.established` requires a matching `SessionInfo` whose
    /// `state == .running` AND `attachedClients >= 1`; a missing match,
    /// `.exited`, zero attached clients, or `listAllBounded()`'s own
    /// already-bounded degrade-to-`[]` all fall through to
    /// `.notEstablished` for free.
    private func reconnectGraceProbe(sessionID: String) async -> ReconnectGraceProbeResult {
        #if DEBUG
        if let hook = _reconnectGraceProbeForTesting {
            return (try? await hook()) ?? .notEstablished
        }
        #endif
        let sessions = await SessionDaemonClient.shared.listAllBounded()
        guard let match = sessions.first(where: { $0.id == sessionID }) else {
            return .notEstablished
        }
        return (match.state == .running && match.attachedClients >= 1) ? .established : .notEstablished
    }

    private func performReconnect(oldSurfaceID: UUID, sessionID: String) {
        guard let tab = findTab(surfaceID: oldSurfaceID) else { return }
        guard let app = GhosttyAppController.shared.app, let window = self.window else { return }

        // Read BEFORE the leaf remap below overwrites tab.sessionRefs'
        // old key -- tab.sessionRefs is keyed by leaf (== surface) UUID,
        // the same convention AppDelegate.restoreTabSurfaces/
        // createSurfaceWithPwd already rely on.
        let host = tab.sessionRefs[oldSurfaceID]?.host
        let command: String
        if let host {
            command = SessionCommandSynthesizer.remoteAttachCommand(
                host: host, sessionID: sessionID, cwd: tab.pwd ?? NSHomeDirectory()
            )
        } else {
            guard let localCommand = SessionCommandSynthesizer.reattachCommand(sessionID: sessionID, cwd: tab.pwd ?? NSHomeDirectory()) else {
                logger.error("No calyx-session binary resolvable; cannot reconnect session \(sessionID, privacy: .public)")
                return
            }
            command = localCommand
        }
        #if DEBUG
        _performReconnectCommandObserverForTesting?(command)
        #endif

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let newSurfaceID = createReconnectSurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: command) else {
            logger.error("Failed to create reconnect surface for session \(sessionID, privacy: .public)")
            return
        }

        let mapping = [oldSurfaceID: newSurfaceID]
        tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
        tab.sessionRefs = tab.sessionRefs.remappingKeys(mapping)
        tab.missionMapCardOffsets = tab.missionMapCardOffsets.remappingKeys(mapping)
        SessionSurfaceMap.shared.replaceSurface(old: oldSurfaceID, new: newSurfaceID)
        CommandLogStore.shared.remapSurface(old: oldSurfaceID, new: newSurfaceID)
        // Before `destroySurface`: the store tears down the views of a
        // destroyed surface, and these now belong to the new one.
        (NSApp.delegate as? AppDelegate)?.mcpHostComposition?.store.remapSurface(old: oldSurfaceID, new: newSurfaceID)

        reconnectingSurfaceIDs.insert(oldSurfaceID)
        tab.registry.destroySurface(oldSurfaceID)
        reconnectingSurfaceIDs.remove(oldSurfaceID)

        // HIGH-SPEED RECONNECT FLASHING BUG (see
        // SessionReconnectAttemptResetTimingTests's header comment):
        // resetting sessionID's attempt count immediately here, right
        // after the swap, used to mean a replacement surface whose
        // attach process dies right away against a still-unreachable
        // daemon is followed by another childExited decision that gets
        // treated as attempt 1 again (0s backoff, see
        // `reconnectBackoffSeconds(forAttempt:)`) instead of attempt 2+
        // -- backoff never grows and `maxReconnectAttempts` is never
        // reached, so `giveUp` never fires: an infinite full-speed
        // reconnect loop (the user-visible pane flashing). Deferring the
        // reset behind a grace period instead lets a replacement that
        // keeps dying accumulate attempts normally; only a replacement
        // that survives past the grace period resets the count, so a
        // later, unrelated disconnect still starts backing off from
        // attempt 1 again (`markEstablished`'s original purpose).
        //
        // Time alone still proved insufficient -- an
        // attach process that dies SLOWER than the grace window (e.g. a
        // ~2.5s die/respawn cycle against a daemon that keeps answering
        // `.running`/`.unreachable`) got its attempt count reset every
        // single cycle by the surface-identity check alone, since the
        // surface itself was never swapped out again in that scenario.
        // The count never advanced past 1, so `.giveUp` never fired: an
        // unbounded reconnect loop at roughly the grace window's own
        // cadence. Establishment now also requires
        // `reconnectGraceProbe(sessionID:)` to report the daemon sees the
        // session running with at least one attached client. A probe
        // failure is fail-closed: skipping a legitimate reset only delays
        // backoff recovery, while wrongly resetting reopens the unbounded
        // loop.
        //
        // The cancel-before-replace inside `insert` below is cheap
        // insurance, not the real mechanism: newSurfaceID is a fresh
        // UUID on every call, so this key was never registered before
        // and the cancel never actually matches an in-flight task.
        // Superseded grace tasks are not proactively cancelled; they are
        // outlived and neutralized by the SessionSurfaceMap re-check once
        // the wait elapses: if this replacement was itself already
        // swapped out again by a second reconnect within the grace
        // window, `SessionSurfaceMap.shared.surfaceID(for:)` no longer
        // equals newSurfaceID, so that second attempt now owns the
        // attempt count, and this stale confirmation must not wrongly
        // reset it out from under an unrelated, still-in-progress retry.
        //
        // Remote sessions: `reconnectGraceProbe` queries the LOCAL
        // calyx-session daemon, which can never have a matching
        // SessionInfo for a REMOTE session (its daemon lives entirely on
        // the remote host) -- the probe would forever report
        // `.notEstablished`, so a remote pane's attempt count would never
        // reset, and independent ssh disconnects occurring days apart
        // would wrongly accumulate toward the same permanent
        // `maxReconnectAttempts` give-up cap instead of each recovering
        // independently. For a remote session (`isRemote`, captured from
        // the same `host` read above before the leaf remap), establishment
        // therefore falls back to the surface-survival check ALONE --
        // exactly the pre-G6 semantics -- without ever consulting
        // `reconnectGraceProbe`. Local semantics are unchanged: the probe
        // is still required. ACCEPTED TRADEOFF: a positive LOCAL probe of
        // a REMOTE session is structurally impossible in v1 (no local
        // knowledge of remote daemon state), so the G6 unbounded-slow-loop
        // risk (an attach process dying slower than the grace window keeps
        // resetting the attempt count every cycle) is knowingly accepted,
        // unmitigated, for remote panes -- bounded in practice by ssh's
        // own connection failures being comparatively slow (seconds, not
        // the sub-second churn G6's local-daemon scenario produced). A
        // second, adjacent v1 limitation follows from the same root cause:
        // see `SessionReconnectCoordinator.childExited`'s doc comment for
        // why a genuinely-exited remote session takes the reconnect-
        // attempts-then-giveUp route instead of the clean `.closePane`.
        let isRemote = host != nil
        reconnectEstablishGraceTasks.insert(newSurfaceID, task: Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reconnectEstablishGraceMilliseconds))
            guard let self else { return }
            if !Task.isCancelled, SessionSurfaceMap.shared.surfaceID(for: sessionID) == newSurfaceID {
                if isRemote {
                    self.sessionReconnectCoordinator.markEstablished(sessionID: sessionID)
                } else if await self.reconnectGraceProbe(sessionID: sessionID) == .established {
                    self.sessionReconnectCoordinator.markEstablished(sessionID: sessionID)
                }
            }
            self.reconnectEstablishGraceTasks.removeValue(forKey: newSurfaceID)
        })

        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
            if let newView = tab.registry.view(for: newSurfaceID) {
                window.makeFirstResponder(newView)
            }
        }
        requestSave()
    }

    /// Exponential backoff for reconnect attempts, capped at 30s:
    /// attempt 1 reconnects immediately (0s); attempts 2-6 wait
    /// 1/2/4/8/16s; attempt 7+ waits the 30s cap. Keeps a persistently
    /// unreachable daemon from spinning the pane in a tight retry loop
    /// while still reconnecting instantly for the common case (the
    /// attach process merely disconnected once).
    private static func reconnectBackoffSeconds(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        return min(30.0, pow(2.0, Double(attempt - 2)))
    }

    /// How long `performReconnect`'s confirmation `Task` waits before
    /// resetting a replacement surface's session's attempt count (see
    /// that method's doc comment for why the reset is deferred at all).
    /// Production default 2000ms: long enough that a replacement whose
    /// attach process dies right away (the flashing bug's own failure
    /// mode) is very unlikely to still look "alive" by the time this
    /// fires, without leaving a legitimately-recovered session's attempt
    /// count wrongly nonzero for long after it's actually fine again.
    /// Same `#if DEBUG`-only override seam as `SessionDaemonClientProtocol
    /// .daemonQueryBoundTimeoutSeconds`.
    private static var reconnectEstablishGraceMilliseconds: UInt64 {
        #if DEBUG
        if let override = CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds {
            return override
        }
        #endif
        return 2000
    }

    @objc private func handleGotoSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_goto_split_e

        let focusDir: FocusDirection
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDir = .spatial(.down)
        default: focusDir = .next
        }

        guard let targetID = tab.splitTree.focusTarget(for: focusDir, from: surfaceID) else { return }
        // settingFocus(_:), not a direct focusedLeafID assignment: while
        // zoomed, moving focus to a DIFFERENT (necessarily hidden, per
        // SplitContainerView.applyLayout's isHidden branch) pane must also
        // clear zoom — Calyx doesn't implement ghostty's
        // split-preserve-zoom config, whose default (navigation: false)
        // means goto_split always clears zoom. Without this, the screen
        // wouldn't visibly change (the zoomed pane stays on screen) but
        // keystrokes would silently route to the now-focused, still-hidden
        // pane instead. The decision lives in the model (settingFocus)
        // rather than here so it stays unit-testable — see
        // SplitTreeTests.swift's own settingFocus coverage.
        tab.splitTree = tab.splitTree.settingFocus(targetID)
        splitContainerView?.updateLayout(tree: tab.splitTree)

        if let targetView = tab.registry.view(for: targetID) {
            window?.makeFirstResponder(targetView)
        }
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        // Refuse to compute a ratio against zero-sized bounds — `resize`
        // would otherwise divide by zero and pin a NaN/Inf into the tree
        // (Bug D).
        guard let container = splitContainerView,
              container.bounds.width > 0,
              container.bounds.height > 0 else { return }

        guard let resize = notification.userInfo?["resize"] as? ghostty_action_resize_split_s else { return }

        let direction: SplitDirection
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT, GHOSTTY_RESIZE_SPLIT_RIGHT:
            direction = .horizontal
        case GHOSTTY_RESIZE_SPLIT_UP, GHOSTTY_RESIZE_SPLIT_DOWN:
            direction = .vertical
        default:
            direction = .horizontal
        }

        let sign: Double
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_RIGHT, GHOSTTY_RESIZE_SPLIT_DOWN:
            sign = 1.0
        default:
            sign = -1.0
        }

        let amount = Double(resize.amount) * sign
        tab.splitTree = tab.splitTree.resize(
            node: surfaceID,
            by: amount,
            direction: direction,
            bounds: container.bounds.size,
            minSize: 50
        )
        container.updateLayout(tree: tab.splitTree)
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }

        guard let tab = activeTab else { return }
        tab.splitTree = tab.splitTree.equalize()
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    /// `GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM` receiver (Calyx's newest split
    /// feature, ported from upstream ghostty's `BaseTerminalController
    /// .ghosttyDidToggleSplitZoom` / `SplitTree.zoomed` — see
    /// `Calyx/Models/SplitTree.swift`'s own "MARK: - Zoom" section).
    ///
    /// Resolves `surfaceView` against `activeTab.registry`, exactly like
    /// `handleGotoSplitNotification`/`handleResizeSplitNotification`/
    /// `handleEqualizeSplitsNotification` above (not `findTab(for:)`,
    /// which the other keybind-action handlers use): a
    /// keybind-triggered action always targets the currently-focused
    /// surface, which can only ever belong to this window's ACTIVE tab:
    /// background tabs have no first responder to trigger the action
    /// from. This also means a `surfaceView` this window doesn't own, or
    /// that belongs to a background tab, naturally no-ops via the
    /// `tab.registry.id(for:)` lookup failing, without a separate
    /// `belongsToThisWindow` check (which would reject every
    /// `_testInsert`-only fixture in this file's own test suite, since
    /// those are never attached to a real `NSWindow`).
    ///
    /// Not `private`, mirroring `processChildExited`'s/`processPromptTitle`'s
    /// own "Not `private`" precedent, so `CalyxWindowControllerToggleSplitZoomTests`
    /// can drive it directly without also wiring the real notification path.
    func processToggleSplitZoom(surfaceView: SurfaceView) {
        guard let tab = activeTab, let surfaceID = tab.registry.id(for: surfaceView) else { return }
        tab.splitTree = tab.splitTree.togglingZoom(at: surfaceID)
        splitContainerView?.updateLayout(tree: tab.splitTree)
        if let view = tab.registry.view(for: surfaceID) {
            window?.makeFirstResponder(view)
        }
        requestSave()
    }

    /// `handleToggleSplitZoomNotification`'s own receiver half. Extracts
    /// `surfaceView` and forwards straight to `processToggleSplitZoom(
    /// surfaceView:)` above, which owns the entire ownership check (see
    /// that method's own doc comment for why no separate
    /// `belongsToThisWindow` guard lives here) — mirrors
    /// `handlePromptTitleNotification`'s identically-reasoned thin-adapter
    /// shape.
    @objc private func handleToggleSplitZoomNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        processToggleSplitZoom(surfaceView: surfaceView)
    }

    @objc private func handleSetTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }

        // Feed the title-heuristic fallback for every pane's title change,
        // not just the tab's focused surface — a background split running
        // Claude Code still needs to report into the Agents sidebar.
        // Skipped for a herdr-hosted or herdr-bridged surface
        // (HerdrHeuristicIngestionPolicy): its "real" agent state already
        // arrives as an external AgentRegistry row over herdr's own event
        // stream, so heuristic ingestion here would only produce a
        // duplicate sidebar row.
        if let surfaceID = surfaceView.surfaceController?.id,
           HerdrHeuristicIngestionPolicy.shouldIngest(
               isHerdrHosted: HerdrHostedSurfaces.shared.contains(surfaceID),
               isBridgeSurface: HerdrPaneRegistry.shared.isBridgeSurface(surfaceID)
           ) {
            AgentRegistry.shared.handleTitleChange(surfaceID: surfaceID, title: title)
        }

        guard let tab = activeTab else { return }

        if let focusedID = tab.splitTree.focusedLeafID,
           let focusedView = tab.registry.view(for: focusedID),
           focusedView === surfaceView {
            tab.title = title
            window?.title = tab.titleOverride ?? title
            refreshHostingView()
        }
    }

    /// OSC 9;4 progress-report signal (`GHOSTTY_ACTION_PROGRESS_REPORT`,
    /// forwarded as `.ghosttyProgressReport`) — feeds the Herdr layer-2
    /// fallback for every pane, not just the tab's focused surface,
    /// mirroring `handleSetTitleNotification`'s title-heuristic feed
    /// above.
    @objc private func handleProgressReportNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let isActive = notification.userInfo?["active"] as? Bool else { return }
        guard let surfaceID = surfaceView.surfaceController?.id else { return }

        AgentRegistry.shared.handleProgressReport(surfaceID: surfaceID, isActive: isActive)
    }

    /// Resolves an Agents sidebar row click to a surface owned by this
    /// window and focuses it. A no-op in every other window's controller
    /// (its `windowSession` won't resolve the surface), and a no-op for
    /// QuickTerminal-hosted panes, which aren't part of any `windowSession`
    /// (out of scope for v1 — the row is still shown, just not focusable).
    @objc private func handleFocusSurfaceNotification(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        guard let tab = findTab(surfaceID: surfaceID) else { return }

        switchToTab(id: tab.id)
        if let view = tab.registry.view(for: surfaceID) {
            window?.makeFirstResponder(view)
        }
        // Every window's controller observes this notification, but only
        // the one that actually resolves the surface (above) should come
        // to the front — otherwise clicking a sidebar row for a pane in a
        // background window would focus that pane without raising its
        // window, leaving it invisible behind the current one.
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleSetPwdNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let pwd = notification.userInfo?["pwd"] as? String else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        let changed = owningTab.pwd != pwd
        owningTab.pwd = pwd
        requestSave()
        // Any terminal tab's directory can add or drop a repository from
        // the sidebar, not just the active one. Discovery only reruns when
        // the resulting set of seed directories actually differs.
        if changed, isGitChangesSidebarVisible {
            refreshGitSidebar(trigger: .paneDirectoryChanged)
        }
    }

    @objc private func handleGotoTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let rawValue = notification.userInfo?["tab"] as? Int32 else { return }

        switch rawValue {
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            selectNextTab(nil)
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            selectPreviousTab(nil)
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            let lastIndex = (windowSession.activeGroup?.tabs.count ?? 1) - 1
            selectTabByIndex(lastIndex)
        default:
            if rawValue >= 0 {
                selectTabByIndex(Int(rawValue))
            }
        }
    }

    @objc private func handleConfirmClipboardNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let userInfo = notification.userInfo else { return }
        guard let contents = userInfo["contents"] as? String else { return }
        guard let surface = userInfo["surface"] as? ghostty_surface_t else { return }
        guard let requestRaw = userInfo["request"] as? ghostty_clipboard_request_e else { return }
        guard let request = ClipboardRequest.from(requestRaw) else { return }
        let state = userInfo["state"] as? UnsafeMutableRawPointer

        let controller = ClipboardConfirmationController(
            surface: surface,
            contents: contents,
            request: request,
            state: state
        )
        self.clipboardConfirmationController = controller

        guard let parentWindow = window, let sheet = controller.window else {
            // Cannot present confirmation UI; cancel the paste to avoid hanging.
            // Pass empty string with confirmed=true to avoid re-triggering unsafe paste detection.
            "".withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: state, confirmed: true)
            }
            return
        }
        parentWindow.beginSheet(sheet) { [weak self] _ in
            self?.clipboardConfirmationController = nil
        }
    }

    @objc private func handleDesktopNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        let body = notification.userInfo?["body"] as? String ?? ""

        let isActiveAndVisible = owningTab.id == activeTab?.id && (window?.isKeyWindow ?? false)
        guard !isActiveAndVisible else { return }

        let isFirstUnread = owningTab.unreadNotifications == 0
        owningTab.unreadNotifications += 1
        owningTab.lastNotificationTime = Date()

        NotificationManager.shared.sendNotification(title: title, body: body, tabID: owningTab.id)

        if isFirstUnread {
            NotificationManager.shared.bounceDockIcon()
        }
    }

    func applyCurrentGhosttyConfig() {
        guard let config = GhosttyAppController.shared.configManager.config else { return }

        for group in windowSession.groups {
            for tab in group.tabs {
                tab.registry.applyConfig(config)
            }
        }
    }

    // MARK: - Menu Actions

    @objc func jumpToMostRecentUnreadTab() {
        var mostRecentTab: Tab?
        var mostRecentTime: Date?

        for group in windowSession.groups {
            for tab in group.tabs {
                guard tab.unreadNotifications > 0,
                      let time = tab.lastNotificationTime else { continue }
                if mostRecentTime == nil || time > mostRecentTime! {
                    mostRecentTab = tab
                    mostRecentTime = time
                }
            }
        }

        guard let target = mostRecentTab else {
            NSSound.beep()
            return
        }

        switchToTab(id: target.id)
    }

    /// Issue #45 defense in depth (see `NSWindow+CalyxClose.swift`'s
    /// header comment for the full root-cause writeup):
    /// `calyxPerformClose(_:)` closes the Cmd+W hole structurally, but
    /// every OTHER action below still reaches `validateMenuItem`/its
    /// receiver via the SAME key-window-chain-then-main-window-fallback
    /// resolution `-[NSApplication targetForAction:]` performs. Every
    /// selector in this set operates on/moves THIS window's EXISTING
    /// state, so it is disabled outright whenever this window is not
    /// actually key — macOS convention keeps "create something new"
    /// commands (`newTab:`/`newBrowserTab:`/`newGroup:`) enabled
    /// regardless (Safari's Cmd+T still opens a tab in the frontmost
    /// window even while About is key), so those are deliberately
    /// excluded here.
    ///
    /// `SurfaceView.focusSplitLeft/Right/Up/Down(_:)` (Cmd+Option+Arrow)
    /// are NOT covered by this Set. This controller implements no
    /// `focusSplit*` action of its own, so `-[NSApplication
    /// targetForAction:]` never resolves it as their target —
    /// `SurfaceView` implements those selectors directly and sits
    /// earlier in the responder chain whenever a terminal surface is
    /// focused, so resolution always stops there first. `SurfaceView`
    /// gates them itself, via its own `keyWindowGatedActions`/
    /// `isKeyWindowForMenuValidation` (mirroring this Set's shape; see
    /// `SurfaceView.swift`'s "MARK: - Menu Actions" extension).
    private static let keyWindowGatedActions: Set<Selector> = [
        #selector(closeTab(_:)),
        #selector(closeGroup(_:)),
        #selector(toggleFullScreen(_:)),
        #selector(selectNextTab(_:)),
        #selector(selectPreviousTab(_:)),
        #selector(nextGroup(_:)),
        #selector(previousGroup(_:)),
        #selector(jumpToMostRecentUnreadTab),
        #selector(toggleSidebar),
        #selector(toggleCommandPalette),
        #selector(toggleComposeOverlay),
        #selector(toggleMissionMap),
        #selector(findNext(_:)),
        #selector(findPrevious(_:)),
    ]

    /// "Is THIS window's own `NSWindow` actually the key window" for
    /// `keyWindowGatedActions` above. Hook-if-set/else-real-value,
    /// mirroring every other `#if DEBUG` seam in this file.
    private var isKeyWindowForMenuValidation: Bool {
        #if DEBUG
        if let override = _isKeyWindowOverrideForTesting { return override }
        #endif
        return window?.isKeyWindow ?? false
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action,
           Self.keyWindowGatedActions.contains(action),
           !isKeyWindowForMenuValidation {
            return false
        }
        if menuItem.action == #selector(jumpToMostRecentUnreadTab) {
            return windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }
        // When the in-terminal search bar is presented, focus moves to its
        // text field and SurfaceView is no longer in the responder chain, so
        // we expose findNext:/findPrevious: here as a fallback target. The
        // validation gates them to "search bar visible" to mirror the
        // SurfaceView-side check.
        if menuItem.action == #selector(findNext(_:)) || menuItem.action == #selector(findPrevious(_:)) {
            return focusedSurfaceHasVisibleSearchBar
        }
        // Next/Previous Tab — only enabled when the active group has more
        // than one tab to switch between.
        if menuItem.action == #selector(selectNextTab(_:))
            || menuItem.action == #selector(selectPreviousTab(_:)) {
            return (windowSession.activeGroup?.tabs.count ?? 0) > 1
        }
        // Next/Previous Group — only enabled when more than one group exists.
        if menuItem.action == #selector(nextGroup(_:))
            || menuItem.action == #selector(previousGroup(_:)) {
            return windowSession.groups.count > 1
        }
        // Focus Split (4 directions) — only enabled when the active tab has
        // been split (i.e., its SplitTree root is a .split node).
        if menuItem.action == #selector(SurfaceView.focusSplitLeft(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitRight(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitUp(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitDown(_:)) {
            return activeTab?.splitTree.isSplit ?? false
        }
        return true
    }

    private var focusedSurfaceHasVisibleSearchBar: Bool {
        guard let surfaceView = focusedController?.surfaceView else { return false }
        return SurfaceScrollView.enclosing(surfaceView.superview)?.isSearchBarPresented ?? false
    }

    // MARK: - Menu Actions (Group)

    @objc func newGroup(_ sender: Any?) { createNewGroup() }
    @objc func closeGroup(_ sender: Any?) { closeActiveGroup() }
    @objc func nextGroup(_ sender: Any?) { switchToNextGroup() }
    @objc func previousGroup(_ sender: Any?) { switchToPreviousGroup() }

    // MARK: - Menu Actions (Full Screen)

    // Wrapping NSWindow.toggleFullScreen via a custom selector keeps the
    // menu title fixed at "Toggle Full Screen" (AppKit only rewrites the
    // title to Enter/Exit when the direct NSWindow selector is used).
    @objc func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    // MARK: - Menu Actions (Find)

    @objc func performFindAction(_ sender: Any?) {
        focusedController?.performAction("start_search")
    }

    @objc func findNext(_ sender: Any?) {
        // ghostty's `navigate_search:previous` moves toward the bottom of the
        // buffer, which is the conventional Find Next direction.
        focusedController?.performAction("navigate_search:previous")
    }

    @objc func findPrevious(_ sender: Any?) {
        focusedController?.performAction("navigate_search:next")
    }

    @objc func newTab(_ sender: Any?) {
        createNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = activeTab, let group = windowSession.activeGroup else { return }
        closeTab(id: tab.id)
        _ = group // silence warning
    }

    @objc func newBrowserTab(_ sender: Any?) {
        promptAndOpenBrowserTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.nextTab()
        activateCurrentTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.previousTab()
        activateCurrentTab()
    }

    @objc func selectTab1(_ sender: Any?) { selectTabByIndex(0) }
    @objc func selectTab2(_ sender: Any?) { selectTabByIndex(1) }
    @objc func selectTab3(_ sender: Any?) { selectTabByIndex(2) }
    @objc func selectTab4(_ sender: Any?) { selectTabByIndex(3) }
    @objc func selectTab5(_ sender: Any?) { selectTabByIndex(4) }
    @objc func selectTab6(_ sender: Any?) { selectTabByIndex(5) }
    @objc func selectTab7(_ sender: Any?) { selectTabByIndex(6) }
    @objc func selectTab8(_ sender: Any?) { selectTabByIndex(7) }
    @objc func selectTab9(_ sender: Any?) { selectTabByIndex(8) }

    func selectTab(at index: Int) {
        selectTabByIndex(index)
    }

    private func selectTabByIndex(_ index: Int) {
        guard index >= 0 else { return }
        deactivateCurrentTab()
        windowSession.selectTab(at: index)
        activateCurrentTab()
    }

    // MARK: - Session Persistence

    func activateRestoredSession() {
        isRestoring = false
        // Pause all non-active terminal tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.id != windowSession.activeGroup?.activeTabID {
                    if case .terminal = tab.content {
                        tab.registry.pauseAll()
                    }
                }
            }
        }
        activateCurrentTab()
    }

    #if DEBUG
    /// Test seam: overrides `hasAppliedInitialSize`, mirroring
    /// `activateRestoredSession()`'s own reset of `isRestoring` just
    /// above -- but deliberately NOT folded into that method, since
    /// production callers of `activateRestoredSession()` (`AppDelegate
    /// .attachWindow`/`.restoreWindow`, both via
    /// `makeRestoringWindowController`) always want
    /// `hasAppliedInitialSize` to STAY `true` (seeded from `restoring` in
    /// `init`, see that property's own doc comment) once restore
    /// completes; only a TEST fixture that used `restoring: true` purely
    /// to skip `setupTerminalSurface` (no live ghostty surface in this
    /// test host, see `SurfaceLocator.swift`'s header comment), while
    /// wanting to represent a genuinely NEW, non-restored window for
    /// exercising `applyInitialSize`'s first-application behavior, needs
    /// to explicitly opt back out via this seam. DO NOT use from
    /// production code.
    func _setHasAppliedInitialSizeForTesting(_ value: Bool) {
        hasAppliedInitialSize = value
    }
    #endif

    /// Delegates TabSnapshot/TabGroupSnapshot
    /// construction to the tested `Tab.snapshot()`/`TabGroup.snapshot()`
    /// extension chain (SessionSnapshot.swift) instead of duplicating a
    /// second, hand-kept-in-sync builder here. Only the live-window-only
    /// inputs stay local: `frame`/`isFullScreen`
    /// (`trackedFullScreen`/`preFullScreenFrame`), and the live
    /// `browserURL` override from `browserControllers`, threaded through
    /// as the `browserURLOverride` closure the chain already supports.
    /// Diff-tab exclusion and the live-URL-over-configured-URL
    /// precedence are therefore inherited from that chain unchanged.
    func windowSnapshot() -> WindowSnapshot {
        let frame: NSRect
        if trackedFullScreen {
            frame = preFullScreenFrame ?? window?.frame ?? .zero
        } else {
            frame = window?.frame ?? .zero
        }
        let groups = windowSession.groups.map { group in
            group.snapshot(browserURLOverride: { tabID in browserControllers[tabID]?.browserState.url })
        }
        return WindowSnapshot(
            id: windowSession.id,
            frame: frame,
            groups: groups,
            activeGroupID: windowSession.activeGroupID,
            showSidebar: windowSession.showSidebar,
            sidebarWidth: windowSession.sidebarWidth,
            isFullScreen: trackedFullScreen
        )
    }

    private func requestSave() {
        DispatchQueue.main.async {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.requestSave()
            }
        }
    }

    // MARK: - Helpers

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === self.window
    }

    private func findTab(for surfaceView: SurfaceView) -> (Tab, TabGroup)? {
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.registry.id(for: surfaceView) != nil {
                    return (tab, group)
                }
            }
        }
        return nil
    }

    /// Finds the tab (in this window) whose `SurfaceRegistry` owns
    /// `surfaceID`. Used by `handleFocusSurfaceNotification` to resolve an
    /// Agents sidebar row click — each window's controller independently
    /// checks its own `windowSession`, so only the owning window acts.
    private func findTab(surfaceID: UUID) -> Tab? {
        windowSession.groups.tabAndGroup(owningSurface: surfaceID)?.tab
    }

    /// Activates the tab (and, by extension via `switchToTab(id:)`, its
    /// group) containing `surfaceID`, reusing this controller's existing
    /// tab-switch logic rather than reimplementing containment. A no-op
    /// if no tab in this window contains `surfaceID`. Not `private`:
    /// `AppDelegate.focusWindowForExistingSession` calls this directly
    /// so the session browser's "Attach" action for an already-live
    /// surface in a background tab actually shows it, not just the
    /// window with whatever tab happened to already be active.
    func activateTabContaining(surfaceID: UUID) {
        guard let tab = findTab(surfaceID: surfaceID) else { return }
        switchToTab(id: tab.id)
    }

    /// Closes `surfaceID`'s tracked leaf via the same `closeSurfaceAndCleanUp`
    /// path an ordinary ghostty-driven pane close uses (see that method's
    /// own doc comment). The `closeLeafHook` seam
    /// (`HerdrTabCoordinator.handlePaneClosed`, `AppDelegate`'s own
    /// `HerdrNativeTabAttacherLive` wiring) routes here rather than
    /// reimplementing tab/group/window teardown a second time. Not
    /// `private`, mirroring `activateTabContaining(surfaceID:)`'s own
    /// precedent immediately above. A no-op if no tab in THIS window
    /// owns `surfaceID` (mirrors `findTab(surfaceID:)`'s own per-window
    /// containment check, so only the owning window's controller acts
    /// when a caller tries every controller). `killSessions: true` (the
    /// default) matches an ordinary process-driven close
    /// (`handleCloseSurfaceNotification`'s own default) -- the actual
    /// value is provably inert here either way, since a herdr-bridged
    /// surface is never registered in `SessionSurfaceMap` (herdr session
    /// identity must never enter it, see `HerdrHostedSurfaces.swift`'s
    /// header), so both `killSessionIfPersistent`/`detachSessionIfPersistent`
    /// no-op on their own `sessionID != nil` guard regardless.
    func closeHerdrTrackedSurface(_ surfaceID: UUID) {
        guard let (tab, group) = findTabAndGroup(surfaceID: surfaceID) else { return }
        closeSurfaceAndCleanUp(tab: tab, group: group, surfaceID: surfaceID)
    }

    /// Applies a herdr layout-sync ratio mutation to the split identified
    /// unambiguously by `(leafA, leafB, direction)` -- see
    /// `SplitTree.setRatio(firstChildFirstLeafID:secondChildFirstLeafID:
    /// direction:...)`'s own doc comment for why this overload (not the
    /// ambiguous leaf-only one) is required here. The
    /// `ratioMutationHook` seam (`HerdrTabCoordinator.handleLayoutUpdated`)
    /// routes here. Not `private`, same precedent as
    /// `closeHerdrTrackedSurface(_:)` above. A no-op if no tab in THIS
    /// window has `leafA` as a splitTree leaf, if `leafB` isn't a leaf of
    /// that SAME tab, or if this window has no rendered content area yet.
    ///
    /// LOCAL BOUNDS: unlike
    /// `handleDividerDrag` (which has the dragged divider's own local
    /// split rect in hand), a herdr-driven ratio sync has no live drag
    /// gesture to read one from, so this walks `tab.splitTree` from the
    /// window content bounds via `SplitTree.localSplitRect(
    /// firstChildFirstLeafID:secondChildFirstLeafID:direction:bounds:)`
    /// -- the SAME per-split subdivision `SplitContainerView.layoutNode(
    /// _:in:)` performs for real on-screen layout -- to compute the
    /// TARGET split's own local rect, exactly mirroring
    /// `handleDividerDrag`'s own `splitRect` usage. Passing the whole
    /// window content view straight through as `setRatio`'s own
    /// `bounds:` (the prior behavior) is exact only for a top-level
    /// split; for a nested one it inflates `totalSize`, which
    /// undershoots `SplitTree.setRatioForSpecificSplit`'s own geometry
    /// clamp against `minSize` -- see that method's own doc comment, and
    /// `handleDividerDrag`'s "Bug C" comment above for the identical bug
    /// class already fixed once for the divider-drag path. A no-op (in
    /// addition to the guards already documented above) when no such
    /// split currently exists in `tab.splitTree` at all.
    func applyHerdrRatioMutation(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {
        guard let tab = findTab(bySplitLeaf: leafA), tab.splitTree.allLeafIDs().contains(leafB) else { return }
        guard let contentBounds = window?.contentView?.bounds, contentBounds.width > 0, contentBounds.height > 0 else { return }
        guard let localRect = tab.splitTree.localSplitRect(
            firstChildFirstLeafID: leafA, secondChildFirstLeafID: leafB, direction: direction, bounds: contentBounds
        ) else { return }

        tab.splitTree = tab.splitTree.setRatio(
            firstChildFirstLeafID: leafA,
            secondChildFirstLeafID: leafB,
            direction: direction,
            to: ratio,
            bounds: localRect.size,
            minSize: 50
        )

        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
        }
    }

    /// Unlike `findTab(surfaceID:)` (which checks `tab.registry`
    /// membership), this checks `tab.splitTree` leaf membership instead
    /// -- `performSplit`'s Cockpit callers only ever learn a pane id from
    /// `listPanes()`'s own splitTree-leaf enumeration, which can name a
    /// leaf whose registry entry a test double never populated (see
    /// CockpitAppAccessSeamTests.swift), so this must match splitTree,
    /// the same source of truth `listPanes()` itself reads from.
    private func findTab(bySplitLeaf surfaceID: UUID) -> Tab? {
        for group in windowSession.groups {
            for tab in group.tabs where tab.splitTree.allLeafIDs().contains(surfaceID) {
                return tab
            }
        }
        return nil
    }

    /// Whether `surfaceID` is a live pane in THIS window -- i.e. a leaf
    /// in some tab's current `splitTree`. Cockpit's single source of
    /// pane identity (see `CockpitAppAccessing`'s own doc comment):
    /// `LiveCockpitAppAccess.paneExists`/every pane operation resolve
    /// the owning window/tab the same way `findTab(bySplitLeaf:)` does,
    /// so "listed by listPanes" and "operable" are the same membership
    /// test by construction, not two independently-maintained checks.
    func ownsSplitLeaf(_ surfaceID: UUID) -> Bool {
        findTab(bySplitLeaf: surfaceID) != nil
    }

    /// Like `findTab(surfaceID:)`, but also returns the owning group —
    /// needed by `closeDeadPersistentSessionSurface` and
    /// `handleReconnectGiveUp` to remove the tab via
    /// `WindowSession.removeTab(id:fromGroup:)` when a persistent
    /// session's pane closes and empties the tab's split tree.
    private func findTabAndGroup(surfaceID: UUID) -> (Tab, TabGroup)? {
        windowSession.groups.tabAndGroup(owningSurface: surfaceID)
    }

    private var focusedController: GhosttySurfaceController? {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID else { return nil }
        return tab.registry.controller(for: focusedID)
    }

    /// Exposes the focused surface controller for UI testing only.
    var focusedControllerForTesting: GhosttySurfaceController? {
        focusedController
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
        if windowSession.showMissionMap {
            // The map keeps keyboard focus while shown; the terminal gets
            // it back when the map is dismissed.
            if let catcher = missionMapKeyCatcher {
                window?.makeFirstResponder(catcher)
            }
        } else if case .browser = activeTab?.content {
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        } else if case .diff = activeTab?.content {
            // No special focus needed for diff tabs
        } else {
            focusedController?.setFocus(true)
            restoreFocus()
        }
        // A window-agnostic (nil targetSurfaceID) approval request's
        // visibility depends on which window is the current window
        // (`CurrentWindowTracker`) -- only becoming key can ever change
        // that (never resigning).
        (NSApp.delegate as? AppDelegate)?.windowControllerDidBecomeKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
        focusedController?.setFocus(false)
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.windowControllerGeometryChanged(self)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let scale = window.backingScaleFactor
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = self.window else { return }
        let nowVisible = window.occlusionState.contains(.visible)
        let shouldRecreate = nowVisible && wasOccluded
        wasOccluded = !nowVisible
        guard shouldRecreate else { return }
        DispatchQueue.main.async { [weak self] in
            self?.recreateHostingView()
            self?.restoreFocus()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Mark all tabs as closing to prevent notification handler interference
        for group in windowSession.groups {
            for tab in group.tabs {
                closingTabIDs.insert(tab.id)
            }
        }

        // Destroy all surfaces in all tabs. When the app is NOT actually
        // terminating (a red-button close of one of several open
        // windows), each persistent surface must go through the same
        // close policy closeTab already uses (kill semantics, an
        // explicit window close), unregistering SessionSurfaceMap/
        // tab.sessionRefs instead of silently orphaning them. When the
        // app IS terminating, preserve today's behavior exactly: destroy
        // without kill/detach, so tracking state survives into the
        // snapshot for the next launch. `isAppActuallyTerminating`, not
        // the per-window `isClosingForShutdown`, is the discriminator
        // (see each flag's own doc comment for why). `tearDownSurfaces`
        // shares this loop's body with closeTab/closeActiveGroup/
        // closeAllTabsInGroup, and receives `appIsTerminating` straight
        // through (rather than gating the call outside and letting the
        // policy re-derive its own notion of "terminating" from
        // `isClosingForShutdown` inside), so this outer gate and the
        // inner kill decision always read the exact same value.
        let appIsTerminating = isAppActuallyTerminating
        for group in windowSession.groups {
            for tab in group.tabs {
                tearDownSurfaces(in: tab, isTerminating: appIsTerminating)
            }
        }

        browserControllers.removeAll()

        diffTasks.cancelAll()
        diffStates.removeAll()
        reviewStores.removeAll()
        expandTasks.cancelAll()
        childExitedTasks.cancelAll()
        reconnectEstablishGraceTasks.cancelAll()
        // Every later request reads this as "the sidebar is not visible",
        // so nothing re-arms the monitors behind the teardown below.
        isGitChangesTornDown = true
        discoveryTask?.cancel()
        pendingDiscoveryScope = nil
        gitSectionRefreshes.cancelAll()
        let pool = gitChangesMonitorPool
        let pendingMonitorSync = gitMonitorSyncTask
        // Awaited rather than cancelled: a sync cancelled mid-flight can
        // leave a monitor running that `stopAll` has already walked past.
        // It stays the chain's tail so anything queued behind it follows.
        gitMonitorSyncTask = Task {
            await pendingMonitorSync?.value
            await pool.stopAll()
        }
        screenPollTask?.cancel()
        missionMapGitPoller.stop()
        missionMapPopoverHost.hide()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // SplitContainerView handles resize via autoresizingMask + resizeSubviews
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        preFullScreenFrame = window?.frame
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        trackedFullScreen = true
        if !isRestoring {
            requestSave()
        }
        (NSApp.delegate as? AppDelegate)?.windowControllerGeometryChanged(self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Preserve tracked fullscreen state during close sequence so shutdown snapshot records fullscreen.
        guard !isClosingForShutdown else { return }
        trackedFullScreen = false
        preFullScreenFrame = nil
        if !isRestoring {
            requestSave()
        }
        (NSApp.delegate as? AppDelegate)?.windowControllerGeometryChanged(self)
    }

    // MARK: - Git Source Control

    private var isGitChangesSidebarVisible: Bool {
        windowSession.showSidebar
            && windowSession.sidebarMode == .changes
            && !isGitChangesTornDown
    }

    private func setSidebarMode(_ mode: SidebarMode) {
        windowSession.sidebarMode = mode
        if isGitChangesSidebarVisible {
            refreshGitSidebar(trigger: .sidebarShown)
        } else {
            stopGitChangesMonitoring()
        }
    }

    /// The single entry point for every Changes-sidebar refresh. Each
    /// trigger pays only for what its event can have changed; see
    /// `GitSidebarRefreshTrigger`.
    private func refreshGitSidebar(trigger: GitSidebarRefreshTrigger) {
        switch trigger {
        case .sidebarShown:
            runGitDiscovery(scope: .everySection, isUserInitiated: false)
        case .manualRefresh:
            runGitDiscovery(scope: .everySection, isUserInitiated: true)
        case .paneDirectoryChanged, .tabActivated:
            // Which repositories the panes sit in is what decides the
            // sections. Moving inside one, or between tabs that are in the
            // ones already displayed, changes only the highlight.
            let seeds = gitSeedWorkDirs()
            let coverage = GitRepoDiscovery.coverage(
                of: seeds,
                in: windowSession.gitRepoSections,
                standardizer: gitPathStandardizer
            )
            if coverage == gitSeedCoverage {
                updateActiveGitRepo()
            } else {
                runGitDiscovery(scope: .appearedSections, isUserInitiated: false)
            }
        case .monitorEvent(let repoIDs, let kind):
            switch kind {
            case .workingTree:
                for repoID in repoIDs {
                    scheduleRepoRefresh(repoID: repoID, scope: .status)
                }
            case .repositoryMetadata:
                // Ref and index changes can also mean a worktree was added
                // or removed, which only discovery can see.
                runGitDiscovery(scope: .sections(repoIDs), isUserInitiated: false)
            }
        }
    }

    private func runGitDiscovery(scope requestedScope: GitSectionRefreshScope, isUserInitiated: Bool) {
        // The superseded run's sections are still owed a fetch, so its
        // scope carries over rather than being dropped with its task.
        let scope = requestedScope.merged(with: pendingDiscoveryScope ?? GitSectionRefreshScope())
        discoveryTask?.cancel()
        pendingDiscoveryScope = scope

        let seeds = gitSeedWorkDirs()
        // Recorded before the run rather than after it, so a directory
        // change back to the state a still-running discovery superseded is
        // seen as a change and supersedes that discovery in turn.
        gitSeedCoverage = GitRepoDiscovery.coverage(
            of: seeds,
            in: windowSession.gitRepoSections,
            standardizer: gitPathStandardizer
        )
        guard !seeds.isEmpty else {
            // Without a terminal pane there is nowhere to search from, so
            // discovery would only report an absence it cannot verify.
            // Skipping it leaves the sections in place, so file-system
            // events keep the sidebar current.
            applyGitDiscoveryFailure(
                GitRefreshFailureOutcome.resolveDiscovery(
                    current: windowSession.gitChangesState,
                    hasSeedWorkDirs: false,
                    failureMessage: nil
                )
            )
            windowSession.isGitRefreshing = false
            syncGitMonitors()
            refreshHostingView()
            return
        }
        let isInitialLoad = windowSession.gitChangesState.allowsInitialSpinner
        refreshGeneration += 1
        let generation = refreshGeneration
        if isUserInitiated {
            windowSession.isGitRefreshing = true
        }
        if isInitialLoad {
            windowSession.gitChangesState = .loading
        }
        if isUserInitiated || isInitialLoad {
            refreshHostingView()
        }

        discoveryTask = Task { [weak self] in
            guard let self else { return }

            // Only the run that started most recently may clear the
            // progress flag: an earlier run's task keeps running
            // (cooperatively) after being cancelled and would otherwise
            // clear a flag a newer run already set.
            @MainActor func finishRefreshing() {
                guard self.refreshGeneration == generation,
                      self.windowSession.isGitRefreshing else { return }
                self.windowSession.isGitRefreshing = false
                self.refreshHostingView()
            }

            let result = await GitRepoDiscovery.discover(seedWorkDirs: seeds)
            guard !Task.isCancelled else {
                finishRefreshing()
                return
            }

            let sectionIDs = self.applyGitDiscovery(result, scope: scope, seeds: seeds)
            // Recorded against what is now displayed, so the next pane
            // event compares like with like.
            self.gitSeedCoverage = GitRepoDiscovery.coverage(
                of: seeds,
                in: self.windowSession.gitRepoSections,
                standardizer: self.gitPathStandardizer
            )
            if self.refreshGeneration == generation {
                self.pendingDiscoveryScope = nil
            }
            self.refreshHostingView()

            // The monitors have to be watching before the sections are
            // read, or a change made between the read and the stream
            // starting is never reported by anything.
            await self.syncGitMonitors().value
            guard !Task.isCancelled else {
                finishRefreshing()
                return
            }

            // The sections run in parallel, so one large repository cannot
            // hold the rest of the sidebar back.
            await withTaskGroup(of: Void.self) { group in
                for sectionID in sectionIDs {
                    guard let refresh = self.scheduleRepoRefresh(
                        repoID: sectionID,
                        scope: .status(includingLog: self.shouldRefreshLog(repoID: sectionID))
                    ) else { continue }
                    group.addTask { await refresh.value }
                }
            }
            finishRefreshing()
        }
    }

    /// Applies a discovery result and returns the sections to fetch. What
    /// the run could not check keeps its place: only a run that looked
    /// where a section lives, and did not find it, retires it.
    private func applyGitDiscovery(
        _ result: GitRepoDiscoveryResult,
        scope: GitSectionRefreshScope,
        seeds: [String]
    ) -> [String] {
        let sections = GitRepoDiscovery.merge(
            discovered: result.sections,
            keeping: windowSession.gitRepoSections,
            gaps: result.gaps
        )
        guard !sections.isEmpty else {
            applyGitDiscoveryFailure(
                GitRefreshFailureOutcome.resolveDiscovery(
                    current: windowSession.gitChangesState,
                    hasSeedWorkDirs: !seeds.isEmpty,
                    failureMessage: result.failureMessage
                )
            )
            return []
        }

        let knownRepoIDs = Set(windowSession.gitRepoChanges.keys)
        let checkedRepoIDs = Set(result.sections.map(\.id))

        windowSession.applyGitSections(sections)
        // A section appearing for the first time in this window starts
        // from whatever ref filter was last saved for it; one already in
        // `gitRefSelections` keeps what the user has open right now.
        for section in sections where !knownRepoIDs.contains(section.id) {
            windowSession.gitRefSelections[section.id] = GitRefFilterSettings.selection(forRepo: section.id)
        }
        windowSession.gitChangesState = .loaded
        windowSession.gitStaleRefreshMessage = nil
        let containers = GitRepoDiscovery.containingSections(of: sections)
        for section in sections {
            guard let message = result.gaps.message(for: section, containedBy: containers),
                  !checkedRepoIDs.contains(section.id) else { continue }
            windowSession.gitRepoChanges[section.id]?.staleRefreshMessage = message
        }
        windowSession.gitActiveRepoID = currentActiveRepoID(in: sections)
        // Sections start collapsed; the one owning the active pane is the
        // exception, and only until the user collapses it themselves.
        if let activeRepoID = windowSession.gitActiveRepoID,
           !knownRepoIDs.contains(activeRepoID) {
            windowSession.gitExpandedRepoIDs.insert(activeRepoID)
        }
        pruneCommitFiles()

        return scope.sectionsToFetch(
            from: sections,
            checked: checkedRepoIDs,
            known: knownRepoIDs,
            changes: windowSession.gitRepoChanges
        )
    }

    /// Applies a resolved outcome for a run that produced no sections. A
    /// `.keepStale` outcome leaves the sections alone (there is content on
    /// screen worth preserving) and only records the warning message; the
    /// caller syncs the monitors either way.
    private func applyGitDiscoveryFailure(_ outcome: GitRefreshFailureOutcome) {
        switch outcome {
        case .showNotRepository:
            applyEmptyGitSections(state: .notRepository)
        case .showError(let message):
            applyEmptyGitSections(state: .error(message))
        case .keepStale(let message):
            windowSession.gitStaleRefreshMessage = message
            logger.error(
                "Keeping stale git sections: \(message, privacy: .public)"
            )
        }
    }

    private func applyEmptyGitSections(state: GitChangesState) {
        windowSession.applyGitSections([])
        windowSession.gitChangesState = state
        windowSession.gitStaleRefreshMessage = nil
        pruneCommitFiles()
    }

    /// Queues one section's fetch. Status is eager for every section
    /// because the header badge counts it; history is the expensive half
    /// and is fetched only for sections whose commits are on screen.
    @discardableResult
    private func scheduleRepoRefresh(
        repoID: String,
        scope: GitSectionFetchScope
    ) -> Task<Void, Never>? {
        guard gitRepoSection(id: repoID) != nil else { return nil }
        if windowSession.gitChanges(for: repoID).state.showsLoadingWhileFetching {
            windowSession.gitRepoChanges[repoID]?.state = .loading
            // A section only says it is fetching if the transition is
            // drawn, and callers are not required to redraw for it.
            refreshHostingView()
        }
        return gitSectionRefreshes.schedule(repoID: repoID, scope: scope)
    }

    private func performRepoRefresh(repoID: String, scope: GitSectionFetchScope) async {
        guard let descriptor = gitRepoSection(id: repoID) else { return }

        if scope.includesStatus || scope.includesLog {
            await fetchRepoSection(descriptor: descriptor, scope: scope)
        }
        if scope.loadsMoreCommits {
            await appendMoreCommits(descriptor: descriptor)
        }
    }

    private func fetchRepoSection(descriptor: GitRepoDescriptor, scope: GitSectionFetchScope) async {
        let changes = windowSession.gitChanges(for: descriptor.id)
        let isInitialLoad = changes.commits.isEmpty && !changes.isLogLoaded
        // A section grown past 100 commits by load-more keeps its length
        // across refreshes.
        let commitCount = changes.isLogLoaded ? max(100, changes.commits.count) : 100

        do {
            var entries: [GitFileEntry]?
            var commits: [GitCommit]?
            if scope.includesStatus, scope.includesLog {
                async let statusResult = GitService.gitStatus(workDir: descriptor.rootPath)
                commits = try await fetchLog(descriptor: descriptor, maxCount: commitCount)
                entries = try await statusResult
            } else if scope.includesStatus {
                // The ref picker's menu appears on every section's header,
                // not only an expanded one fetching its log, so its
                // `availableRefs` still needs a `refList` here -- run
                // alongside `gitStatus` rather than after it.
                async let statusResult = GitService.gitStatus(workDir: descriptor.rootPath)
                async let refListResult = GitService.refList(location: descriptor.location)
                entries = try await statusResult
                let liveRefs = try await refListResult
                _ = reconcileAvailableRefs(repoID: descriptor.id, liveRefs: liveRefs)
            } else if scope.includesLog {
                commits = try await fetchLog(descriptor: descriptor, maxCount: commitCount)
            }
            guard !Task.isCancelled else { return }
            applyRepoRefresh(
                repoID: descriptor.id,
                entries: entries,
                commits: commits,
                isInitialLoad: isInitialLoad
            )
            refreshHostingView()
        } catch {
            guard !Task.isCancelled else { return }
            applyRepoRefreshFailure(repoID: descriptor.id, error: error)
            refreshHostingView()
        }
    }

    /// Records `liveRefs` as one section's `availableRefs` (feeding the
    /// ref picker's menu) and reconciles a `.refs` selection against them,
    /// writing the reconciled selection back to the session and
    /// `GitRefFilterSettings` if that changes it. Shared by every fetch
    /// that has a `refList` result to record, whether or not that same
    /// fetch also feeds a log. Returns the reconciled selection.
    private func reconcileAvailableRefs(repoID: String, liveRefs: [GitRefInfo]) -> GitRefSelection {
        windowSession.gitRepoChanges[repoID]?.availableRefs = liveRefs

        let liveNames = Set(liveRefs.map(\.fullName))
        let stored = windowSession.gitRefSelections[repoID] ?? .auto
        let selection = stored.reconciled(withLiveRefs: liveNames)
        if selection != stored {
            windowSession.gitRefSelections[repoID] = selection
            GitRefFilterSettings.set(selection, forRepo: repoID)
        }
        return selection
    }

    /// This section's commit log, resolved against its live refs first
    /// rather than against a possibly-stale saved selection: `refList` is
    /// awaited before any log fetch starts, so a `.refs` selection naming
    /// a ref that has since vanished is reconciled before the log fetch
    /// that follows ever sees the stale ref. Invariant on return: the
    /// commits handed back, and `resolvedRefScope` stored alongside them,
    /// both came from the same reconciled ref scope. A `refList` failure
    /// propagates to the caller unchanged, through this method's own throw.
    private func fetchLog(descriptor: GitRepoDescriptor, maxCount: Int) async throws -> [GitCommit] {
        let repoID = descriptor.id
        let liveRefs = try await GitService.refList(location: descriptor.location)
        guard windowSession.gitRepoChanges[repoID] != nil else { return [] }
        let selection = reconcileAvailableRefs(repoID: repoID, liveRefs: liveRefs)

        let resolvedScope = try await GitService.resolvedRefScope(
            location: descriptor.location, selection: selection, liveRefs: liveRefs
        )
        windowSession.gitRepoChanges[repoID]?.resolvedRefScope = resolvedScope
        return try await GitService.commitLog(
            location: descriptor.location,
            resolvedScope: resolvedScope,
            maxCount: maxCount,
            skip: 0
        )
    }

    /// Appends the next page of history, querying the exact ref scope
    /// `fetchLog` last resolved and stored -- not a fresh resolution of
    /// `.auto`/`.all`, which could answer differently page to page. No
    /// scope stored (this section's log has not been fetched yet) means
    /// nothing to page from.
    private func appendMoreCommits(descriptor: GitRepoDescriptor) async {
        let repoID = descriptor.id
        let changes = windowSession.gitChanges(for: repoID)
        guard changes.hasMoreCommits else { return }
        guard let resolvedScope = changes.resolvedRefScope else { return }
        let loadedCount = changes.commits.count

        do {
            let moreCommits = try await GitService.commitLog(
                location: descriptor.location, resolvedScope: resolvedScope, maxCount: GitRepoChanges.commitPageSize, skip: loadedCount
            )
            guard !Task.isCancelled else { return }
            guard windowSession.gitRepoChanges[repoID] != nil else { return }
            if moreCommits.isEmpty {
                windowSession.gitRepoChanges[repoID]?.hasMoreCommits = false
            } else {
                windowSession.gitRepoChanges[repoID]?.commits.append(contentsOf: moreCommits)
                refreshHostingView()
            }
        } catch {
            // Silently ignore load-more errors
        }
    }

    private func applyRepoRefresh(
        repoID: String,
        entries: [GitFileEntry]?,
        commits: [GitCommit]?,
        isInitialLoad: Bool
    ) {
        // A section can vanish while its fetch is in flight; the result
        // must not resurrect the entry `applyGitSections` removed.
        guard var changes = windowSession.gitRepoChanges[repoID] else { return }

        if let entries {
            changes.entries = entries
        }
        if let commits {
            changes.commits = commits
            changes.isLogLoaded = true
            changes.hasMoreCommits = true
            if isInitialLoad {
                changes.expandedCommitIDs = []
            } else {
                changes.expandedCommitIDs.formIntersection(Set(commits.map(\.id)))
            }
        }
        changes.state = .loaded
        changes.staleRefreshMessage = nil
        windowSession.gitRepoChanges[repoID] = changes
        pruneCommitFiles()
    }

    /// Applies a resolved refresh failure to one section. A `.keepStale`
    /// outcome leaves the section's state untouched (there is content on
    /// screen worth preserving) and only records the warning message and
    /// logs the underlying failure.
    private func applyRepoRefreshFailure(repoID: String, error: Error) {
        guard var changes = windowSession.gitRepoChanges[repoID] else { return }

        let isNotARepository: Bool
        if let gitError = error as? GitService.GitError, case .notARepository = gitError {
            isNotARepository = true
        } else {
            isNotARepository = false
        }
        let outcome = GitRefreshFailureOutcome.resolve(
            current: changes.state,
            isNotARepository: isNotARepository,
            message: error.localizedDescription
        )
        switch outcome {
        case .showNotRepository:
            changes.state = .notRepository
            changes.staleRefreshMessage = nil
        case .showError(let message):
            changes.state = .error(message)
            changes.staleRefreshMessage = nil
        case .keepStale(let message):
            changes.staleRefreshMessage = message
            logger.error(
                "Git refresh failed for \(repoID, privacy: .public), keeping stale content: \(message, privacy: .public)"
            )
        }
        windowSession.gitRepoChanges[repoID] = changes

        // A directory that has stopped being a repository is a change in
        // which repositories exist, and discovery is what decides that: it
        // retires the section, and with it the monitor watching a path
        // nothing is left at, or confirms the repository and fetches it
        // again.
        if case .showNotRepository = outcome {
            runGitDiscovery(scope: .sections([repoID]), isUserInitiated: false)
        }
    }

    /// Drops cached commit file lists no section can show. The union
    /// across every section is what matters: worktrees of one repository
    /// see the same commits, so pruning against a single section would
    /// discard the files of a commit expanded in another.
    private func pruneCommitFiles() {
        var visibleCommitIDs: Set<String> = []
        for changes in windowSession.gitRepoChanges.values {
            visibleCommitIDs.formUnion(changes.commits.map(\.id))
        }
        windowSession.commitFiles = windowSession.commitFiles.filter {
            visibleCommitIDs.contains($0.key)
        }
    }

    /// History is fetched for the sections showing it. A collapsed section
    /// having fetched it once is not a reason to keep paying for a
    /// `git log` on every refresh for the rest of the window's life.
    private func shouldRefreshLog(repoID: String) -> Bool {
        windowSession.gitExpandedRepoIDs.contains(repoID)
    }

    private func gitRepoSection(id: String) -> GitRepoDescriptor? {
        windowSession.gitRepoSections.first { $0.id == id }
    }

    /// The section owning the active pane's directory now. The directory is
    /// read here rather than taken from what a discovery run started with,
    /// because a run takes long enough for the user to switch panes while
    /// it is in flight, and the highlight belongs to the pane they are in.
    private func currentActiveRepoID(in sections: [GitRepoDescriptor]) -> String? {
        GitRepoDiscovery.activeRepoID(
            for: gitSeedWorkDirs().first,
            in: sections,
            standardizer: gitPathStandardizer
        )
    }

    private func updateActiveGitRepo() {
        let activeRepoID = currentActiveRepoID(in: windowSession.gitRepoSections)
        guard activeRepoID != windowSession.gitActiveRepoID else { return }
        windowSession.gitActiveRepoID = activeRepoID
        refreshHostingView()
    }

    private func toggleGitRepoSection(repoID: String) {
        if windowSession.gitExpandedRepoIDs.contains(repoID) {
            windowSession.gitExpandedRepoIDs.remove(repoID)
            refreshHostingView()
            return
        }

        // History is fetched when a section is opened, not kept current
        // while it is closed, so opening one asks for it again.
        windowSession.gitExpandedRepoIDs.insert(repoID)
        scheduleRepoRefresh(repoID: repoID, scope: .log)
        refreshHostingView()
    }

    private func retryGitRepoSection(repoID: String) {
        scheduleRepoRefresh(
            repoID: repoID,
            scope: .status(includingLog: shouldRefreshLog(repoID: repoID))
        )
        refreshHostingView()
    }

    /// The ref picker's choice for one section. History fetched under the
    /// old selection is not a valid answer to the new one, so it is
    /// dropped rather than filtered client-side, and a fresh `git log`
    /// under the new selection is scheduled immediately.
    private func setGitRefSelection(repoID: String, selection: GitRefSelection) {
        GitRefFilterSettings.set(selection, forRepo: repoID)
        windowSession.gitRefSelections[repoID] = selection

        guard var changes = windowSession.gitRepoChanges[repoID] else { return }
        changes.commits = []
        changes.isLogLoaded = false
        changes.hasMoreCommits = true
        changes.expandedCommitIDs = []
        changes.resolvedRefScope = nil
        windowSession.gitRepoChanges[repoID] = changes

        refreshHostingView()
        scheduleRepoRefresh(repoID: repoID, scope: .log)
    }

    /// Drives the monitor pool to exactly the displayed sections, or to
    /// nothing while the Changes sidebar is hidden. The returned task is
    /// what a caller waits on to know the streams are running.
    @discardableResult
    private func syncGitMonitors() -> Task<Void, Never> {
        var repositories: [String: GitRepositoryLocation] = [:]
        if isGitChangesSidebarVisible {
            for section in windowSession.gitRepoSections {
                repositories[section.id] = section.location
            }
        }

        let onRefresh: GitChangesMonitorPool.RefreshHandler = { [weak self] repoIDs, kind in
            guard let self, self.isGitChangesSidebarVisible else { return }
            self.refreshGitSidebar(trigger: .monitorEvent(repoIDs: repoIDs, kind: kind))
        }
        let pool = gitChangesMonitorPool
        let previousSync = gitMonitorSyncTask
        let task = Task {
            await previousSync?.value
            await pool.sync(repositories: repositories, onRefresh: onRefresh)
        }
        gitMonitorSyncTask = task
        return task
    }

    /// Called when the Changes sidebar stops being visible: the work it
    /// asked for is abandoned and the pool is driven to the empty set.
    private func stopGitChangesMonitoring() {
        discoveryTask?.cancel()
        pendingDiscoveryScope = nil
        gitSectionRefreshes.cancelAll()
        syncGitMonitors()
    }

    private func buildGitSidebarViewState() -> GitSidebarViewState {
        let sections = windowSession.gitRepoSections.map { descriptor in
            GitRepoSectionViewData(
                descriptor: descriptor,
                changes: windowSession.gitChanges(for: descriptor.id),
                isActive: descriptor.id == windowSession.gitActiveRepoID,
                isExpanded: windowSession.gitExpandedRepoIDs.contains(descriptor.id),
                refSelection: windowSession.gitRefSelections[descriptor.id] ?? .auto
            )
        }
        return GitSidebarViewState(
            phase: windowSession.gitChangesState,
            isRefreshing: windowSession.isGitRefreshing,
            staleRefreshMessage: windowSession.gitStaleRefreshMessage,
            sections: sections,
            commitFiles: windowSession.commitFiles
        )
    }

    private func loadMoreCommits(repoID: String) {
        // A row appearing again while a page is queued or in flight must
        // not add another page.
        guard windowSession.gitChanges(for: repoID).hasMoreCommits,
              !gitSectionRefreshes.isLoadingMoreCommits(repoID: repoID)
        else { return }
        // Queued on the section's own queue rather than run alongside its
        // refresh: the page to fetch is decided by how many commits the
        // list holds, and a refresh replaces that list wholesale.
        scheduleRepoRefresh(repoID: repoID, scope: .moreCommits)
    }

    private func expandCommit(repoID: String, hash: String) {
        guard var changes = windowSession.gitRepoChanges[repoID] else { return }

        if changes.expandedCommitIDs.contains(hash) {
            changes.expandedCommitIDs.remove(hash)
            windowSession.gitRepoChanges[repoID] = changes
            refreshHostingView()
            return
        }

        changes.expandedCommitIDs.insert(hash)
        windowSession.gitRepoChanges[repoID] = changes
        refreshHostingView()

        if windowSession.commitFiles[hash] != nil { return }
        guard let descriptor = gitRepoSection(id: repoID) else { return }

        // Plain subscript store, not `insert(_:task:)`: unlike this
        // file's other `KeyedTaskRegistry`s, `hash` is NOT guaranteed
        // fresh here -- a rapid double-expand of the same not-yet-loaded
        // commit before this Task completes reaches this line twice for
        // the same key (the guard above only checks `commitFiles[hash] !=
        // nil`, not whether a fetch is already in flight). `insert`'s
        // cancel-before-replace would cancel the first fetch's Task,
        // which -- because `GitService.commitFiles` routes through
        // `GitService.run`'s cancellation propagation -- would terminate
        // its underlying git subprocess early, changing today's behavior
        // (both fetches currently run to completion).
        expandTasks[hash] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await GitService.commitFiles(
                    hash: hash, workDir: descriptor.rootPath
                )
                self.windowSession.commitFiles[hash] = files
                self.refreshHostingView()
            } catch {
                // Silently ignore
            }
            self.expandTasks.removeValue(forKey: hash)
        }
    }

    private func handleWorkingFileSelected(repoID: String, entry: GitFileEntry) {
        guard let descriptor = gitRepoSection(id: repoID) else { return }
        let repoRoot = descriptor.rootPath

        let source: DiffSource
        if entry.isStaged {
            source = .staged(path: entry.path, workDir: repoRoot)
        } else if entry.status == .untracked {
            source = .untracked(path: entry.path, workDir: repoRoot)
        } else {
            source = .unstaged(path: entry.path, workDir: repoRoot)
        }

        openDiffTab(source: source)
    }

    private func handleCommitFileSelected(repoID: String, entry: CommitFileEntry) {
        guard let descriptor = gitRepoSection(id: repoID) else { return }

        let source: DiffSource = .commit(
            hash: entry.commitHash, path: entry.path, workDir: descriptor.rootPath
        )
        openDiffTab(source: source)
    }

    private func openDiffTab(source: DiffSource) {
        // Dedup: check if same source already open
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .diff(let existingSource) = tab.content, existingSource == source {
                    switchToTab(id: tab.id)
                    return
                }
            }
        }

        guard let group = windowSession.activeGroup else { return }

        let fileName: String
        switch source {
        case .unstaged(let path, _), .staged(let path, _), .commit(_, let path, _), .untracked(let path, _):
            fileName = (path as NSString).lastPathComponent
        }

        let tab = Tab(title: fileName, content: .diff(source: source))
        deactivateCurrentTab()
        group.addTab(tab)
        group.activeTabID = tab.id

        diffStates[tab.id] = .loading
        let reviewStore = DiffReviewStore()
        reviewStore.onCommentsChanged = { [weak self] in self?.refreshHostingView() }
        reviewStores[tab.id] = reviewStore
        refreshHostingView()

        let tabID = tab.id
        // Plain subscript store, not `insert(_:task:)`: tabID is the id
        // of the `Tab()` just created above, so this key was never
        // registered before -- `insert`'s cancel-before-replace would
        // never actually match anything here, mirroring
        // `reconnectEstablishGraceTasks`' own "fresh key" reasoning at
        // its `insert` call site above. This Task also never self-
        // removes its own entry once done (unlike `expandTasks`'/
        // `childExitedTasks`' Tasks) -- a pre-existing divergence kept
        // as-is here, not something this refactor changes.
        diffTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            do {
                let rawDiff = try await GitService.fileDiff(source: source)
                guard !Task.isCancelled else { return }

                let path: String
                switch source {
                case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
                    path = p
                }
                let parsed = DiffParser.parse(rawDiff, path: path)
                guard !Task.isCancelled else { return }

                // Verify tab still exists
                guard self.windowSession.groups.tabAndGroup(tabID: tabID) != nil else { return }

                self.diffStates[tabID] = .success(parsed)
                self.refreshHostingView()
            } catch {
                guard !Task.isCancelled else { return }
                self.diffStates[tabID] = .error(error.localizedDescription)
                self.refreshHostingView()
            }
        }
    }

    /// `findSeedWorkDirs()` for the Changes sidebar, with the standardizer
    /// trimmed to what it returns: a directory no pane is in any more is
    /// not worth a remembered spelling.
    private func gitSeedWorkDirs() -> [String] {
        let seeds = findSeedWorkDirs()
        gitPathStandardizer.keepOnly(Set(seeds))
        return seeds
    }

    /// Every working directory repository discovery should start from, in
    /// the order that decides which section owns the active pane: the
    /// active terminal tab first, then the rest of its group, then every
    /// other group. Duplicates are dropped and the order is kept.
    private func findSeedWorkDirs() -> [String] {
        var seeds: [String] = []
        var seen: Set<String> = []

        func appendPwd(of tab: Tab) {
            guard case .terminal = tab.content, let pwd = tab.pwd else { return }
            guard seen.insert(pwd).inserted else { return }
            seeds.append(pwd)
        }

        if let tab = activeTab {
            appendPwd(of: tab)
        }
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                appendPwd(of: tab)
            }
        }
        for group in windowSession.groups {
            for tab in group.tabs {
                appendPwd(of: tab)
            }
        }
        return seeds
    }

    // MARK: - AI Agent Tab Detection

    /// Returns true if a terminal tab title indicates it is running one of the
    /// supported AI agents (Claude Code, Codex, OpenCode, Hermes, Grok).
    /// Centralizes the title-substring check used by both compose and review
    /// send paths. Keep the agent list in sync with `IPCConfigResult` axes.
    ///
    /// pi is deliberately absent. Its name is two characters, so a
    /// case-insensitive substring match on it fires for ordinary titles
    /// such as "npm run api" or any path holding "pi", and every one of
    /// those panes would be offered as a send target. A pi pane still
    /// reaches the Agents sidebar through its extension's own events,
    /// which name the kind explicitly instead of guessing from a title.
    private static func isAIAgentTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("claude") ||
        title.localizedCaseInsensitiveContains(AgentEntry.codexKind) ||
        title.localizedCaseInsensitiveContains(AgentEntry.openCodeKind) ||
        title.localizedCaseInsensitiveContains("hermes") ||
        title.localizedCaseInsensitiveContains(AgentEntry.grokKind)
    }

    private func sendReviewToAgent(_ payload: String) -> ReviewSendResult {
        // Find terminal tabs running a supported AI agent.
        let agentTabs = windowSession.groups.flatMap(\.tabs).filter {
            guard case .terminal = $0.content else { return false }
            return Self.isAIAgentTitle($0.title)
        }

        guard !agentTabs.isEmpty else {
            showIPCAlert(title: "No AI Agent", message: "No terminal tabs running Claude Code, Codex, OpenCode, Hermes, or Grok found. Start an AI agent first.")
            return .failed
        }

        // Select target tab
        let targetTab: Tab
        if agentTabs.count == 1 {
            targetTab = agentTabs[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Select AI Agent Tab"
            alert.informativeText = "Choose which AI agent instance to send the review to:"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            for (i, tab) in agentTabs.enumerated() {
                let groupName = windowSession.groups.tabAndGroup(tabID: tab.id)?.group.name ?? ""
                let label = "\(tab.displayTitle) — \(groupName) (#\(i + 1))"
                popup.addItem(withTitle: label)
            }
            alert.accessoryView = popup

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .cancelled }

            let selectedIndex = popup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < agentTabs.count else { return .failed }
            targetTab = agentTabs[selectedIndex]
        }

        // Send review text to terminal PTY via ghostty surface
        guard let focusedID = targetTab.splitTree.focusedLeafID,
              let controller = targetTab.registry.controller(for: focusedID) else {
            showIPCAlert(title: "Send Failed", message: "Could not access terminal surface.")
            return .failed
        }

        controller.sendText(payload)
        // Send Enter twice: first to confirm paste, second to submit
        sendSyntheticReturn(controller: controller, double: true)

        // Switch to the target terminal tab
        switchToTab(id: targetTab.id)

        return .sent
    }

    private func submitDiffReview(tabID: UUID) {
        guard let store = reviewStores[tabID], store.hasUnsubmittedComments else { return }

        // Get file path from tab
        guard let tab = windowSession.groups.tabAndGroup(tabID: tabID)?.tab,
              case .diff(let source) = tab.content else { return }
        let filePath: String
        switch source {
        case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
            filePath = p
        }

        let payload = store.formatForSubmission(filePath: filePath)
        let result = sendReviewToAgent(payload)

        if result == .sent {
            store.clearAll()
            refreshHostingView()
        }
    }

    private func submitAllDiffReviews() {
        // Collect all review stores with comments, paired with their DiffSource
        let entries: [(source: DiffSource, store: DiffReviewStore)] = reviewStores.compactMap { tabID, store in
            guard store.hasUnsubmittedComments else { return nil }
            guard let tab = windowSession.groups.tabAndGroup(tabID: tabID)?.tab,
                  case .diff(let source) = tab.content else { return nil }
            return (source: source, store: store)
        }
        guard !entries.isEmpty else { return }

        let payload = DiffReviewStore.formatAllForSubmission(entries)
        let result = sendReviewToAgent(payload)

        if result == .sent {
            for entry in entries { entry.store.clearAll() }
            refreshHostingView()
        }
    }

    private func discardAllDiffReviews() {
        let storesWithComments = reviewStores.values.filter { $0.hasUnsubmittedComments }
        guard !storesWithComments.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Discard All Review Comments"
        alert.informativeText = "This will discard \(totalReviewCommentCount) comment(s) across \(reviewFileCount) file(s)."
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        for store in storesWithComments { store.clearAll() }
        refreshHostingView()
    }

    private func showIPCAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}
