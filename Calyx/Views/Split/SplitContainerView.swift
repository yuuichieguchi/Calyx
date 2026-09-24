// SplitContainerView.swift
// Calyx
//
// NSView that recursively renders a SplitTree using SurfaceRegistry lookups.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SplitContainerView")

@MainActor
class SplitContainerView: NSView {

    /// Cache key that uniquely identifies one divider in the current layout.
    ///
    /// `.split` identifies a split node by the leftmost leaves of BOTH
    /// children plus direction, because in a binary tree two distinct splits
    /// cannot share both children's leftmost leaves AND direction. This
    /// avoids the Bug A collision in trees like `V(H(A, C), B)` where the
    /// outer V and the inner H would otherwise both compute
    /// `firstLeafID(first) == A` and clobber each other in a UUID-only cache.
    ///
    /// `.dock` is the divider between a leaf's terminal and its MCP Apps dock.
    private enum DividerKey: Hashable {
        case split(firstChildFirstLeafID: UUID, secondChildFirstLeafID: UUID, direction: SplitDirection)
        case dock(leafID: UUID)
    }

    private var registry: SurfaceRegistry
    private var currentTree: SplitTree = SplitTree()
    private var scrollWrappers: [UUID: SurfaceScrollView] = [:]
    private var activeLeafID: UUID?
    // Keep divider NSView instances alive across layout passes; AppKit's
    // mouse-capture session is bound to the original instance, so tearing
    // them down mid-drag kills subsequent mouseDragged events.
    private var dividerCache: [DividerKey: SplitDividerView] = [:]
    private var dividersUsedThisPass: Set<DividerKey> = []
    /// Fired on every divider drag tick. Carries both the leftmost leaf IDs
    /// of the split's children (required to disambiguate nested
    /// same-direction splits — Bug B) and the split's containing rect in
    /// the container's coordinate space (required so the controller can
    /// pass the LOCAL size to `setRatio` — Bug C).
    var onTargetRatioChange: ((
        _ firstChildFirstLeafID: UUID,
        _ secondChildFirstLeafID: UUID,
        _ targetRatio: Double,
        _ direction: SplitDirection,
        _ splitRect: CGRect
    ) -> Void)?
    /// MCP Apps docks by leaf. A dock shares its leaf's rect with the
    /// terminal wrapper and outlives tab switches (`updateRegistry`).
    private var docks: [UUID: NSView] = [:]
    /// Docks whose leaf left the tree: detached but kept, and put back
    /// when the leaf returns.
    private var parkedDocks: [UUID: NSView] = [:]
    /// The leaf whose dock covers the whole container. Kept while the leaf
    /// is out of the tree; cleared by `setFullscreen(false, ...)` and
    /// `detachDock(fromLeaf:)`.
    private var fullscreenLeafID: UUID?
    /// Dock widths set by dragging a dock divider, by leaf. A leaf without
    /// an entry gets `MCPAppDockLayout.defaultDockWidth`. Kept while the
    /// dock is parked or hidden and across `updateRegistry`; dropped when
    /// the dock is detached or replaced.
    private var dockWidths: [UUID: CGFloat] = [:]
    var onDeferredLayoutComplete: (() -> Void)?
    var onActiveLeafChange: ((UUID) -> Void)?

    private static let minPaneSize: CGFloat = 50

    init(registry: SurfaceRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // MARK: - Update

    func updateRegistry(_ registry: SurfaceRegistry) {
        guard self.registry !== registry else { return }
        self.registry = registry
        currentTree = SplitTree()
        scrollWrappers.removeAll()
        dividerCache.removeAll()
        dividersUsedThisPass.removeAll()
        // Docks stay in `docks`; the next layout puts them back or parks them.
        subviews.forEach { $0.removeFromSuperview() }
        activeLeafID = nil
        needsLayout = true
    }

    func updateLayout(tree: SplitTree) {
        let oldTree = currentTree
        currentTree = tree

        guard oldTree != tree else { return }

        // Don't move surface views into a zero-bounds container —
        // setFrameSize(zero) kills Metal drawable and ghostty stops rendering.
        // resizeSubviews/layout will handle it when we get proper bounds.
        guard bounds.width > 0 && bounds.height > 0 else { return }

        guard tree.root != nil else {
            dividersUsedThisPass.removeAll()
            subviews.forEach { $0.removeFromSuperview() }
            scrollWrappers.removeAll()
            dividerCache.removeAll()
            parkedDocks.merge(docks) { _, new in new }
            docks.removeAll()
            activeLeafID = nil
            applyActiveDimming()
            return
        }

        applyLayout()

        if activeLeafID == nil || scrollWrappers[activeLeafID!] == nil {
            activeLeafID = tree.focusedLeafID
            // A brand new container's (or brand new tab's, after
            // updateRegistry(_:) resets activeLeafID) first-ever active
            // leaf pick — mirrors surfaceDidBecomeActive's own call so the
            // production requestSave() wiring fires for a window/tab's
            // first surface with no later focus/split/tab action required.
            if let id = activeLeafID {
                onActiveLeafChange?(id)
            }
        }
        // Must run AFTER the reseed above, not folded into applyLayout():
        // a brand-new container's first-ever updateLayout(tree:) call
        // reaches this method with activeLeafID still nil, and dimming a
        // multi-pane split against a nil active leaf would flatten every
        // pane to alpha 1.0 instead of the tree's actual focused/dimmed
        // split (see testTwoPaneSplitDimsInactivePane).
        applyActiveDimming()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }
        applyLayout()
        applyActiveDimming()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }

        // Deferred layout: surface views haven't been added yet
        if subviews.isEmpty || subviews.allSatisfy({ !($0 is SplitDividerView) }) {
            applyLayout()
            applyActiveDimming()
            let callback = onDeferredLayoutComplete
            onDeferredLayoutComplete = nil
            callback?()
        }
    }

    /// Shared layout body for all three AppKit entry points above
    /// (`updateLayout(tree:)` — when `tree.root != nil`, `resizeSubviews
    /// (withOldSize:)`, and `layout()`'s deferred-layout branch): lay out
    /// `currentTree` into `bounds`, drop orphaned surfaces, and reap
    /// unused dividers. Centralizing this is not just DRY — it is the fix
    /// for a real, reproducible regression class: before this method
    /// existed, the zoom branch below would need to be duplicated in all
    /// three call sites, and forgetting it in exactly one (`resizeSubviews`,
    /// historically the easiest one to miss) means zoom visibly un-zooms
    /// the instant the window is resized, even though `currentTree
    /// .zoomedLeafID` never actually changed.
    ///
    /// Deliberately does NOT call `applyActiveDimming()` itself, unlike
    /// every other per-pass step here — each of the three call sites
    /// above calls it independently, right after `applyLayout()` returns,
    /// because `updateLayout(tree:)` needs to run its own `activeLeafID`
    /// reseed IN BETWEEN the two (see that call site's own comment);
    /// folding dimming into this method would run it before that reseed
    /// on every first-ever layout pass.
    private func applyLayout() {
        guard let root = currentTree.root else { return }

        dividersUsedThisPass.removeAll()
        restoreParkedDocks()
        if let fullscreenID = fullscreenLeafID, currentTree.allLeafIDs().contains(fullscreenID) {
            // Fullscreen: the leaf's dock covers the container. Wrappers
            // are hidden with their frames left as they are, so leaving
            // fullscreen needs no geometry recovery (a zero frame would
            // also kill the Metal drawable).
            for (_, wrapper) in scrollWrappers {
                wrapper.isHidden = true
            }
            for (id, dock) in docks {
                dock.isHidden = id != fullscreenID
                if id == fullscreenID {
                    dock.frame = bounds
                    if dock.superview !== self { addSubview(dock) }
                }
            }
        } else if let zoomID = currentTree.effectiveZoomedLeafID {
            // Zoomed: lay out ONLY the zoomed leaf, at the container's
            // full bounds, and hide every other wrapper. Hiding the
            // `SurfaceScrollView` WRAPPER (not the `SurfaceView` inside
            // it) matters: wrappers are recreated whenever a leaf is
            // freshly laid out (see the `.leaf` case in `layoutNode`
            // below), so a stale `isHidden` can never leak across a
            // registry swap the way it could if this toggled the
            // long-lived, registry-owned `SurfaceView` instead.
            //
            // Deliberately does NOT zero any non-zoomed wrapper's frame —
            // `updateLayout(tree:)`'s own comment above documents why
            // `setFrameSize(zero)` kills a live Metal drawable; a hidden
            // pane simply keeps whatever frame its last visible layout
            // pass gave it, which is harmless since it isn't drawn.
            //
            // `placeDivider` is never called on this path, so
            // `dividersUsedThisPass` stays empty and `reapUnusedDividers()`
            // below removes every cached divider — they reappear
            // automatically the moment zoom clears and the `else` branch
            // walks the full tree again.
            layoutNode(.leaf(id: zoomID), in: bounds)
            for (id, wrapper) in scrollWrappers {
                wrapper.isHidden = (id != zoomID)
            }
            // Another leaf's dock hides with its terminal; it is not destroyed.
            for (id, dock) in docks where id != zoomID {
                dock.isHidden = true
            }
        } else {
            layoutNode(root, in: bounds)
            for (_, wrapper) in scrollWrappers {
                wrapper.isHidden = false
            }
        }
        removeOrphanedSurfaces()
        parkDocksOutsideTree()
        reapUnusedDividers()
    }

    // MARK: - MCP Apps docks

    /// The terminal cell width in points, from the surface's cell size.
    private func cellWidth(of surfaceView: SurfaceView) -> CGFloat {
        surfaceView.convertFromBacking(surfaceView.cachedCellSize).width
    }

    /// Lays out a leaf that has a dock: terminal on the left, the dock
    /// divider, the dock on the right. The divider is placed after the
    /// wrapper and the dock are in the container, so a newly created
    /// divider sits above both and keeps its whole hit area. A leaf too
    /// narrow for both minimums (no `MCPAppDockLayout.dockWidthRange`)
    /// gives the terminal the whole leaf and hides the dock with its frame
    /// left as it is; no divider is placed, so this pass reaps it. The
    /// stored width is kept, and the dock shows again when the leaf is
    /// wide enough.
    private func layoutDockedLeaf(_ leafID: UUID, wrapper: SurfaceScrollView, dock: NSView, cellWidth: CGFloat, in rect: CGRect) {
        guard let range = MCPAppDockLayout.dockWidthRange(leafWidth: rect.width, cellWidth: cellWidth) else {
            wrapper.frame = rect
            if wrapper.superview !== self {
                addSubview(wrapper)
            }
            dock.isHidden = true
            return
        }
        let dockWidth = dockWidths[leafID] ?? MCPAppDockLayout.defaultDockWidth(leafWidth: rect.width)
        let split = MCPAppDockLayout.split(leafRect: rect, dockWidth: dockWidth, in: range)
        wrapper.frame = split.terminalRect
        dock.frame = split.dockRect
        dock.isHidden = false
        if wrapper.superview !== self {
            addSubview(wrapper)
        }
        if dock.superview !== self {
            addSubview(dock, positioned: .above, relativeTo: wrapper)
        }
        let divider = placeDividerView(
            key: .dock(leafID: leafID), direction: .horizontal, frame: split.dividerRect, containingRect: rect
        )
        // Rebound every pass so the drag uses the leaf's current rect and width range.
        divider.onTargetRatioChange = { [weak self] ratio in
            guard let self else { return }
            let requested = MCPAppDockLayout.dockWidth(forDividerRatio: ratio, leafWidth: rect.width)
            self.dockWidths[leafID] = MCPAppDockLayout.clamp(requested, to: range)
            self.dockPreferredWidthDidChange()
        }
    }

    /// Puts parked docks back when their leaf is in the tree again.
    private func restoreParkedDocks() {
        let leafIDs = Set(currentTree.allLeafIDs())
        for (id, dock) in parkedDocks where leafIDs.contains(id) {
            docks[id] = dock
            parkedDocks.removeValue(forKey: id)
        }
    }

    /// Detaches (but keeps) the docks of leaves that left the tree.
    private func parkDocksOutsideTree() {
        let leafIDs = Set(currentTree.allLeafIDs())
        for (id, dock) in docks where !leafIDs.contains(id) {
            dock.removeFromSuperview()
            parkedDocks[id] = dock
            docks.removeValue(forKey: id)
        }
    }

    /// Lays the tree out again, for dock changes that do not change the tree.
    private func relayoutForDocks() {
        guard bounds.width > 0 && bounds.height > 0, currentTree.root != nil else { return }
        applyLayout()
        applyActiveDimming()
    }

    // MARK: - Active Pane Dimming

    private func applyActiveDimming() {
        let inactiveAlpha: CGFloat = 0.75
        let count = scrollWrappers.count

        if count <= 1 {
            for (_, wrapper) in scrollWrappers where wrapper.surfaceView.alphaValue != 1.0 {
                wrapper.surfaceView.alphaValue = 1.0
            }
            return
        }

        // While zoomed, the zoomed leaf is the effective active pane for
        // dimming purposes, regardless of `activeLeafID` — `activeLeafID`
        // only updates on an explicit focus transition (surfaceDidBecomeActive
        // / updateLayout's reseed), so it can lag behind a just-applied
        // zoom (e.g. zooming a pane that isn't the currently-focused one).
        // Without this, that pane would be visible (per applyLayout's
        // isHidden branch above) but dimmed to 0.75 — a single, fully
        // visible pane that looks wrong.
        let effectiveActive = currentTree.effectiveZoomedLeafID ?? activeLeafID

        guard let active = effectiveActive, scrollWrappers[active] != nil else {
            for (_, wrapper) in scrollWrappers where wrapper.surfaceView.alphaValue != 1.0 {
                wrapper.surfaceView.alphaValue = 1.0
            }
            return
        }

        for (id, wrapper) in scrollWrappers {
            let desired: CGFloat = (id == active) ? 1.0 : inactiveAlpha
            if wrapper.surfaceView.alphaValue != desired {
                wrapper.surfaceView.alphaValue = desired
            }
        }
    }

    // MARK: - Recursive Layout

    private func layoutNode(_ node: SplitNode, in rect: CGRect) {
        switch node {
        case .leaf(let id):
            if let surfaceView = registry.view(for: id) {
                let wrapper: SurfaceScrollView
                if let existing = scrollWrappers[id] {
                    wrapper = existing
                } else {
                    wrapper = SurfaceScrollView(surfaceView: surfaceView)
                    scrollWrappers[id] = wrapper
                }
                surfaceView.focusHost = self
                wrapper.autoresizingMask = []
                if let dock = docks[id] {
                    layoutDockedLeaf(id, wrapper: wrapper, dock: dock, cellWidth: cellWidth(of: surfaceView), in: rect)
                } else {
                    wrapper.frame = rect
                    if wrapper.superview !== self {
                        addSubview(wrapper)
                    }
                }
            }

        case .split(let data):
            let dividerThickness: CGFloat = 1

            switch data.direction {
            case .horizontal:
                let splitX = rect.minX + rect.width * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: max(splitX - rect.minX - dividerThickness / 2, Self.minPaneSize),
                    height: rect.height
                )
                let dividerRect = CGRect(
                    x: firstRect.maxX,
                    y: rect.minY,
                    width: dividerThickness,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: dividerRect.maxX,
                    y: rect.minY,
                    width: max(rect.maxX - dividerRect.maxX, Self.minPaneSize),
                    height: rect.height
                )

                layoutNode(data.first, in: firstRect)
                placeDivider(direction: .horizontal, frame: dividerRect, splitData: data, splitRect: rect)
                layoutNode(data.second, in: secondRect)

            case .vertical:
                let splitY = rect.minY + rect.height * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: max(splitY - rect.minY - dividerThickness / 2, Self.minPaneSize)
                )
                let dividerRect = CGRect(
                    x: rect.minX,
                    y: firstRect.maxY,
                    width: rect.width,
                    height: dividerThickness
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: dividerRect.maxY,
                    width: rect.width,
                    height: max(rect.maxY - dividerRect.maxY, Self.minPaneSize)
                )

                layoutNode(data.first, in: firstRect)
                placeDivider(direction: .vertical, frame: dividerRect, splitData: data, splitRect: rect)
                layoutNode(data.second, in: secondRect)
            }
        }
    }

    private func placeDivider(
        direction: SplitDirection,
        frame: CGRect,
        splitData: SplitData,
        splitRect: CGRect
    ) {
        guard let firstChildID = SplitTree.firstLeafID(of: splitData.first),
              let secondChildID = SplitTree.firstLeafID(of: splitData.second) else { return }

        let divider = placeDividerView(
            key: .split(firstChildFirstLeafID: firstChildID, secondChildFirstLeafID: secondChildID, direction: direction),
            direction: direction,
            frame: frame,
            containingRect: splitRect
        )

        // Rebind the callback every pass so it captures the latest splitData
        // shape (ratio/children may have changed even if the cache key didn't)
        // AND the latest splitRect (resizing the container moves nested splits).
        divider.onTargetRatioChange = { [weak self] targetRatio in
            guard let self else { return }
            self.onTargetRatioChange?(firstChildID, secondChildID, targetRatio, direction, splitRect)
        }
    }

    /// Places the cached divider for `key` (creating it on first use) over
    /// the visible `frame` with the expanded hit area, and marks it used in
    /// this pass. `containingRect` is the rect the divider's drag ratio is
    /// measured across.
    private func placeDividerView(
        key: DividerKey,
        direction: SplitDirection,
        frame: CGRect,
        containingRect: CGRect
    ) -> SplitDividerView {
        // Expand hit area around the visible divider
        let hitExpansion: CGFloat = 3
        let hitFrame: CGRect
        switch direction {
        case .horizontal:
            hitFrame = CGRect(
                x: frame.minX - hitExpansion,
                y: frame.minY,
                width: frame.width + hitExpansion * 2,
                height: frame.height
            )
        case .vertical:
            hitFrame = CGRect(
                x: frame.minX,
                y: frame.minY - hitExpansion,
                width: frame.width,
                height: frame.height + hitExpansion * 2
            )
        }

        let divider: SplitDividerView
        if let existing = dividerCache[key] {
            // Direction is already part of the key, so a cache hit always
            // means the directions match — no need to recheck.
            divider = existing
            divider.frame = hitFrame
            if divider.superview !== self {
                addSubview(divider)
            }
        } else {
            divider = SplitDividerView(direction: direction)
            divider.frame = hitFrame
            dividerCache[key] = divider
            addSubview(divider)
        }

        // Keep the divider in sync with the sub-rect it lives in so drag
        // math is computed relative to that rect, not the whole container
        // (Bug C).
        divider.containingRect = containingRect

        dividersUsedThisPass.insert(key)
        return divider
    }

    private func reapUnusedDividers() {
        for key in Array(dividerCache.keys) where !dividersUsedThisPass.contains(key) {
            dividerCache[key]?.removeFromSuperview()
            dividerCache.removeValue(forKey: key)
        }
        dividersUsedThisPass.removeAll()
    }

    /// Remove orphaned subviews not present in the current tree.
    /// Handles both SurfaceScrollView wrappers and legacy bare SurfaceView subviews.
    private func removeOrphanedSurfaces() {
        let treeIDs = Set(currentTree.allLeafIDs())
        for subview in subviews {
            if let wrapper = subview as? SurfaceScrollView {
                let id = registry.id(for: wrapper.surfaceView)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                    if let id { scrollWrappers.removeValue(forKey: id) }
                }
            } else if let surface = subview as? SurfaceView {
                // Legacy: shouldn't happen, but clean up
                let id = registry.id(for: surface)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                }
            }
        }
        // Also clean wrapper dictionary of IDs no longer in tree
        for id in scrollWrappers.keys where !treeIDs.contains(id) {
            scrollWrappers[id]?.removeFromSuperview()
            scrollWrappers.removeValue(forKey: id)
        }
    }
}

// MARK: - SurfaceFocusHost

extension SplitContainerView: SurfaceFocusHost {
    func surfaceDidBecomeActive(_ surfaceView: SurfaceView) {
        guard let id = registry.id(for: surfaceView) else { return }
        guard activeLeafID != id else { return }
        activeLeafID = id
        applyActiveDimming()
        onActiveLeafChange?(id)
    }
}

// MARK: - MCP Apps dock placement

extension SplitContainerView {
    /// Shows `dockView` to the right of the leaf's terminal. Attaching the
    /// same view again is harmless; a different view replaces the leaf's
    /// dock and starts at the default width.
    func attachDock(_ dockView: NSView, toLeaf leafID: UUID) {
        if let existing = docks[leafID] ?? parkedDocks[leafID], existing !== dockView {
            existing.removeFromSuperview()
            dockWidths.removeValue(forKey: leafID)
        }
        parkedDocks.removeValue(forKey: leafID)
        docks[leafID] = dockView
        relayoutForDocks()
    }

    /// The leaf's attached dock. Nil while the leaf is out of the tree.
    func dockView(forLeaf leafID: UUID) -> NSView? {
        docks[leafID]
    }

    /// Fullscreen hides the terminal wrappers without zeroing their frames
    /// and gives the leaf's dock the whole container.
    func setFullscreen(_ isFullscreen: Bool, forLeaf leafID: UUID) {
        if isFullscreen {
            fullscreenLeafID = leafID
        } else if fullscreenLeafID == leafID {
            fullscreenLeafID = nil
        }
        relayoutForDocks()
    }

    /// Removes the leaf's dock for good (the view it showed was closed).
    func detachDock(fromLeaf leafID: UUID) {
        docks.removeValue(forKey: leafID)?.removeFromSuperview()
        parkedDocks.removeValue(forKey: leafID)
        dockWidths.removeValue(forKey: leafID)
        if fullscreenLeafID == leafID { fullscreenLeafID = nil }
        relayoutForDocks()
    }

    /// A leaf's dock width changed (a dock divider drag): lays the docks
    /// out again.
    func dockPreferredWidthDidChange() {
        relayoutForDocks()
    }
}
