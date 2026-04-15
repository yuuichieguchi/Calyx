// SplitContainerView.swift
// Calyx
//
// NSView that recursively renders a SplitTree using SurfaceRegistry lookups.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SplitContainerView")

@MainActor
class SplitContainerView: NSView {

    private var registry: SurfaceRegistry
    private var currentTree: SplitTree = SplitTree()
    private var scrollWrappers: [UUID: SurfaceScrollView] = [:]
    private var activeLeafID: UUID?
    var onRatioChange: ((UUID, Double, SplitDirection) -> Void)?
    var onDeferredLayoutComplete: (() -> Void)?

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

        removeDividers()
        guard let root = tree.root else {
            subviews.forEach { $0.removeFromSuperview() }
            activeLeafID = nil
            applyActiveDimming()
            return
        }
        layoutNode(root, in: bounds)
        removeOrphanedSurfaces()

        if activeLeafID == nil || scrollWrappers[activeLeafID!] == nil {
            activeLeafID = tree.focusedLeafID
        }
        applyActiveDimming()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard let root = currentTree.root else { return }
        removeDividers()
        layoutNode(root, in: bounds)
        removeOrphanedSurfaces()
        applyActiveDimming()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard let root = currentTree.root else { return }

        // Deferred layout: surface views haven't been added yet
        if subviews.isEmpty || subviews.allSatisfy({ !($0 is SplitDividerView) }) {
            removeDividers()
            layoutNode(root, in: bounds)
            removeOrphanedSurfaces()
            applyActiveDimming()
            let callback = onDeferredLayoutComplete
            onDeferredLayoutComplete = nil
            callback?()
        }
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

        guard let active = activeLeafID, scrollWrappers[active] != nil else {
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
                wrapper.frame = rect
                wrapper.autoresizingMask = []
                if wrapper.superview !== self {
                    addSubview(wrapper)
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
                addDivider(direction: .horizontal, frame: dividerRect, splitData: data)
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
                addDivider(direction: .vertical, frame: dividerRect, splitData: data)
                layoutNode(data.second, in: secondRect)
            }
        }
    }

    private func addDivider(direction: SplitDirection, frame: CGRect, splitData: SplitData) {
        let divider = SplitDividerView(direction: direction)

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

        divider.frame = hitFrame
        divider.onRatioChange = { [weak self] delta in
            guard let self else { return }
            // Find the first leaf ID in the first child to identify which split to resize
            if let firstLeafID = SplitTree.firstLeafID(of: splitData.first) {
                self.onRatioChange?(firstLeafID, delta, direction)
            }
        }
        addSubview(divider)
    }

    private func removeDividers() {
        for subview in subviews where subview is SplitDividerView {
            subview.removeFromSuperview()
        }
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
    }
}
