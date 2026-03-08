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
        subviews.forEach { $0.removeFromSuperview() }
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

        subviews.forEach { $0.removeFromSuperview() }
        guard let root = tree.root else { return }
        layoutNode(root, in: bounds)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard let root = currentTree.root else { return }

        subviews.forEach { $0.removeFromSuperview() }
        layoutNode(root, in: bounds)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard let root = currentTree.root else { return }

        // Deferred layout: surface views haven't been added yet
        if subviews.isEmpty {
            layoutNode(root, in: bounds)
            let callback = onDeferredLayoutComplete
            onDeferredLayoutComplete = nil
            callback?()
        }
    }

    // MARK: - Recursive Layout

    private func layoutNode(_ node: SplitNode, in rect: CGRect) {
        switch node {
        case .leaf(let id):
            if let surfaceView = registry.view(for: id) {
                surfaceView.frame = rect
                surfaceView.autoresizingMask = []
                if surfaceView.superview !== self {
                    addSubview(surfaceView)
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
}
