// SurfaceRegistry.swift
// Calyx
//
// Mutable UUID→SurfaceView mapping. Controller layer for managing surface lifecycle.

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SurfaceRegistry")

@MainActor
final class SurfaceRegistry {

    enum EntryState: Equatable, Sendable {
        case creating
        case attached
        case detaching
        case destroyed
    }

    struct RegistryEntry {
        let view: SurfaceView
        let controller: GhosttySurfaceController
        var state: EntryState
        var isDragging: Bool = false
    }

    private var entries: [UUID: RegistryEntry] = [:]

    /// Store `destroySurface(_:)` orphans a torn-down surface's running
    /// commands into (gated on `sessionSurfaceMap`, see that property's
    /// doc comment). Defaults to the shared singleton; tests inject an
    /// isolated instance so assertions don't leak state across cases --
    /// same rationale as `CalyxMCPServer.agentRegistry`.
    var commandLogStore: CommandLogStore = .shared

    /// Session-surface map `destroySurface(_:)` consults to gate command
    /// orphaning: a surface still tracked here (a persistent-session
    /// pane) keeps its commands `.running` -- the daemon-side session
    /// survives the pane's teardown, and a later reconnect resumes it
    /// (see `CalyxWindowController`'s reconnect path, which
    /// `remapSurface`s the same records onto the fresh surfaceID).
    /// Defaults to the shared singleton; tests inject an isolated
    /// instance.
    var sessionSurfaceMap: SessionSurfaceMap = .shared

    /// Store `destroySurface(_:)` expires any still-pending Cockpit
    /// approval request targeting a torn-down surface into (see
    /// `ApprovalInboxStore.expireForSurface(_:)`) -- without this, such
    /// a request's banner would stay invisible forever (no window owns a
    /// destroyed surface) while its MCP caller waits out the full
    /// timeout for a decision nobody can ever make. Defaults to the
    /// shared singleton; tests inject an isolated instance, same
    /// rationale as `commandLogStore`/`sessionSurfaceMap` above.
    var approvalInboxStore: ApprovalInboxStore = .shared

    /// Memory `destroySurface(_:)` clears the destroyed surface's own
    /// pane-scoped Always-Allow entries out of (see
    /// `AgentHookApprovalMemory.clearPaneEntries(surfaceID:)`), so
    /// pane-scoped memory never outlives the pane it was recorded for.
    /// Cross-scoped memory (not keyed by surfaceID) is untouched by this
    /// call. Defaults to the shared singleton; tests inject an isolated
    /// instance, same rationale as `approvalInboxStore` above.
    var agentHookApprovalMemory: AgentHookApprovalMemory = .shared

    #if DEBUG
    /// Test-only storage for injected `SurfaceView` fixtures. Populated
    /// via `_testInsert(view:id:)` and consulted as a fallback by
    /// `view(for:)` / `id(for:)` when the main `entries` dictionary does
    /// not contain the queried key. Inert in Release because
    /// `_testViewsByID` is never populated outside test hosts — the
    /// `#if DEBUG` gate is preserved so this storage is only compiled in
    /// when the `DEBUG` compilation condition is set. DO NOT use from
    /// production code.
    private var _testViewsByID: [UUID: SurfaceView] = [:]
    #endif

    var count: Int { entries.count }

    /// P4 round-6 fix (R6-D, r6-fix-spec.md): also includes
    /// `_testInsert`-only entries under `#if DEBUG`. `closeTab`/
    /// `closeAllTabsInGroup`/`closeActiveGroup`, and (as of round 6)
    /// `CalyxWindowController.windowWillClose`, iterate `allIDs` to
    /// decide which surfaces to run kill/detach close-policy handling on
    /// before destroying them. A `_testInsert`-only fixture (this
    /// codebase's established no-live-ghostty-surface test pattern; see
    /// `SessionReconnectGiveUpTests`/`SessionCommandPaletteTests`) used
    /// to be invisible to that iteration, which made `windowWillClose`'s
    /// per-surface close-policy behavior untestable without an unsafe
    /// live ghostty surface (see `AppDelegateAttachWindowTests`'s header
    /// comment on why that hangs the XCTest process). No pre-existing
    /// test combines `_testInsert` with any `allIDs`-iterating call site
    /// (verified by inspection), so this is additive: it does not change
    /// the value `allIDs` returns for a registry that never called
    /// `_testInsert`. Inert in Release, matching `_testViewsByID` itself.
    var allIDs: [UUID] {
        #if DEBUG
        Array(entries.keys) + Array(_testViewsByID.keys)
        #else
        Array(entries.keys)
        #endif
    }

    // MARK: - Surface Lifecycle

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s) -> UUID? {
        let surfaceView = SurfaceView(frame: .zero)
        surfaceView.wantsLayer = true
        _ = surfaceView.layer

        var mutableConfig = config
        mutableConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        mutableConfig.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(surfaceView).toOpaque()
        )

        guard let controller = GhosttySurfaceController(app: app, baseConfig: mutableConfig, view: surfaceView) else {
            logger.error("Failed to create surface controller")
            return nil
        }

        surfaceView.surfaceController = controller
        let id = controller.id

        entries[id] = RegistryEntry(
            view: surfaceView,
            controller: controller,
            state: .attached
        )
        SurfaceLocator.shared.register(id: id, controller: controller)
        SurfaceLocator.shared.registerView(id: id, view: surfaceView)

        logger.info("Surface created and registered: \(id)")
        return id
    }

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?) -> UUID? {
        if let pwd {
            return pwd.withCString { cStr in
                var mutableConfig = config
                mutableConfig.working_directory = cStr
                return createSurface(app: app, config: mutableConfig)
            }
        }
        return createSurface(app: app, config: config)
    }

    /// Persistent-session variant: sets `config.command` (in addition to
    /// `pwd`) so the surface's child process is a `calyx-session attach`
    /// invocation (see `SessionCommandSynthesizer`) instead of the
    /// user's plain shell. Setting a non-empty `command` also makes
    /// ghostty force `wait-after-command` on internally (embedded.zig's
    /// `Surface.init`), independent of anything this config sets, so a
    /// persistent-session pane never auto-closes when the attach
    /// process disconnects — `SessionReconnectCoordinator` decides
    /// whether to reconnect or close instead. `command`'s C string only
    /// needs to stay alive for the duration of `ghostty_surface_new`
    /// inside `createSurface(app:config:)` (verified against
    /// embedded.zig: the command slice is copied into the surface's own
    /// config before `Options.command` goes out of scope), matching the
    /// `pwd`-only variant's `withCString` nesting above.
    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?, command: String?) -> UUID? {
        guard let command else {
            return createSurface(app: app, config: config, pwd: pwd)
        }
        return command.withCString { cmdCStr in
            var mutableConfig = config
            mutableConfig.command = cmdCStr
            guard let pwd else {
                return createSurface(app: app, config: mutableConfig)
            }
            return pwd.withCString { pwdCStr in
                mutableConfig.working_directory = pwdCStr
                return createSurface(app: app, config: mutableConfig)
            }
        }
    }

    func destroySurface(_ id: UUID) {
        guard var entry = entries[id] else {
            #if DEBUG
            // Symmetric with `contains(_:)`'s injected-ID fallback
            // (review finding): a `_testInsert`-only entry has no live
            // ghostty surface to tear down, but it must still be
            // dropped from test-only storage so `contains(_:)` (and
            // `view(for:)`/`id(for:)`) correctly stop resolving it
            // afterward, matching what destroying a real entry does.
            _testViewsByID.removeValue(forKey: id)
            #endif
            // No live entry to defer/already-destroyed-check against --
            // the command-log orphan gating below doesn't depend on one
            // (see its own comment on `orphanCommandsIfNotPersistent`).
            // Safe even for an `id` this particular registry never owned
            // (e.g. a stale/foreign call): each surfaceID is owned by
            // exactly one Tab's SurfaceRegistry for its whole lifetime,
            // so `commandLogStore.markOrphaned(surfaceID:)` here is a
            // no-op for any id genuinely foreign to CommandLogStore too.
            orphanCommandsIfNotPersistent(surfaceID: id)
            approvalInboxStore.expireForSurface(id)
            agentHookApprovalMemory.clearPaneEntries(surfaceID: id)
            // P3 review (F4): symmetric with the main destroy path below
            // -- unregisterView + the .calyxSurfaceDestroyed post must
            // ALSO run here so SurfacePropertyStore prunes a
            // _testInsert-only surface's recorded title/cwd on destroy,
            // not just a real registry entry's. Safe unconditionally
            // (not #if DEBUG): both are no-ops for an id neither
            // SurfaceLocator nor any observer has ever seen.
            SurfaceLocator.shared.unregisterView(id: id)
            NotificationCenter.default.post(
                name: .calyxSurfaceDestroyed,
                object: nil,
                userInfo: ["surfaceID": id]
            )
            return
        }
        guard entry.state != .destroyed else { return }

        if entry.isDragging {
            entry.state = .detaching
            entries[id] = entry
            logger.info("Surface destroy deferred (dragging): \(id)")
            return
        }

        entry.state = .destroyed
        entries[id] = entry

        entry.controller.setOcclusion(true)
        entry.view.removeFromSuperview()
        entry.controller.requestClose()

        entries.removeValue(forKey: id)
        SurfaceLocator.shared.unregister(id: id)
        SurfaceLocator.shared.unregisterView(id: id)
        logger.info("Surface destroyed: \(id)")

        orphanCommandsIfNotPersistent(surfaceID: id)
        approvalInboxStore.expireForSurface(id)
        agentHookApprovalMemory.clearPaneEntries(surfaceID: id)

        NotificationCenter.default.post(
            name: .calyxSurfaceDestroyed,
            object: nil,
            userInfo: ["surfaceID": id]
        )
    }

    /// Orphans `id`'s running commands UNLESS it's still tracked in
    /// `sessionSurfaceMap` (a persistent-session pane, whose daemon-side
    /// session survives this pane's teardown -- see `sessionSurfaceMap`'s
    /// own doc comment). `CalyxWindowController.performReconnect` calls
    /// `CommandLogStore.shared.remapSurface(old:new:)` (and
    /// `SessionSurfaceMap.shared.replaceSurface`) BEFORE tearing down the
    /// old surface, so by the time a persistent-session pane's own
    /// reconnect reaches here, its records have already moved off `id`
    /// entirely and this is a no-op either way.
    private func orphanCommandsIfNotPersistent(surfaceID id: UUID) {
        guard sessionSurfaceMap.sessionID(for: id) == nil else { return }
        commandLogStore.markOrphaned(surfaceID: id)
    }

    func completeDragAndDestroyIfNeeded(_ id: UUID) {
        guard var entry = entries[id] else { return }
        entry.isDragging = false
        entries[id] = entry

        if entry.state == .detaching {
            destroySurface(id)
        }
    }

    // MARK: - Lookup

    func view(for id: UUID) -> SurfaceView? {
        if let v = entries[id]?.view { return v }
        #if DEBUG
        return _testViewsByID[id]
        #else
        return nil
        #endif
    }

    func controller(for id: UUID) -> GhosttySurfaceController? {
        entries[id]?.controller
    }

    func state(for id: UUID) -> EntryState? {
        entries[id]?.state
    }

    func id(for surfaceView: SurfaceView) -> UUID? {
        if let match = entries.first(where: { $0.value.view === surfaceView })?.key {
            return match
        }
        #if DEBUG
        return _testViewsByID.first(where: { $0.value === surfaceView })?.key
        #else
        return nil
        #endif
    }

    // MARK: - Tab Lifecycle

    func pauseAll() {
        for id in allIDs {
            entries[id]?.controller.setFocus(false)
            entries[id]?.view.resetFocusState()
        }
    }

    func resumeAll() {
        for id in allIDs {
            entries[id]?.controller.refresh()
            entries[id]?.view.needsDisplay = true
        }
    }

    func contains(_ id: UUID) -> Bool {
        if entries[id] != nil { return true }
        #if DEBUG
        return _testViewsByID[id] != nil
        #else
        return false
        #endif
    }

    func applyConfig(_ config: ghostty_config_t) {
        for id in allIDs {
            guard let entry = entries[id] else { continue }
            entry.controller.updateConfig(config)
            entry.controller.refresh()
            entry.view.needsDisplay = true
        }
    }

    #if DEBUG
    /// Test-only: inject a `SurfaceView` with a fixed UUID, bypassing the
    /// ghostty FFI surface-creation path. `view(for:)`, `id(for:)`, and
    /// `contains(_:)` will all resolve the injected view — the latter
    /// added for `SessionReconnectGiveUpTests`/`SessionCommandPaletteTests`,
    /// which need `findTab(surfaceID:)`/`findTabAndGroup(surfaceID:)`
    /// (both gated on `contains(_:)`) to find a `_testInsert`-only tab
    /// without a live ghostty app. `destroySurface(_:)` is ALSO extended
    /// to remove an injected entry (review finding: it used to leave
    /// `_testViewsByID` untouched, so `contains(_:)` kept reporting
    /// `true` for an ID that had just been torn down — an asymmetry
    /// with the production-entry path, where `destroySurface` always
    /// makes `contains` flip to `false`). `allIDs` remains deliberately
    /// NOT extended to see injected entries: no test needs iteration
    /// over test-only entries. DO NOT use from production code.
    func _testInsert(view: SurfaceView, id: UUID) {
        _testViewsByID[id] = view
        SurfaceLocator.shared.registerView(id: id, view: view)
    }
    #endif
}
