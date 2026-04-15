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

    var allIDs: [UUID] { Array(entries.keys) }

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

    func destroySurface(_ id: UUID) {
        guard var entry = entries[id] else { return }
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
        logger.info("Surface destroyed: \(id)")
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
        entries[id] != nil
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
    /// ghostty FFI surface-creation path. Both `view(for:)` and
    /// `id(for:)` will resolve the injected view. DO NOT call from
    /// production code.
    func _testInsert(view: SurfaceView, id: UUID) {
        _testViewsByID[id] = view
    }
    #endif
}
