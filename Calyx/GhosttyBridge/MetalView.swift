// MetalView.swift
// Calyx
//
// Simple CAMetalLayer subclass for the terminal rendering surface.

@preconcurrency import QuartzCore
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MetalView")

// MARK: - GhosttyMetalLayer

/// A CAMetalLayer subclass used as the backing layer for the terminal surface view.
///
/// This layer serves as the render target for ghostty's Metal renderer. The ghostty
/// library creates and manages its own Metal device, command queues, and render
/// pipeline. This layer simply provides the drawable surface.
///
/// In most cases, this class does not need customization beyond what CAMetalLayer
/// provides. It exists primarily as a typed subclass for debugging and to provide
/// a clear extension point if needed.
final class GhosttyMetalLayer: CAMetalLayer {

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        // This initializer is called by Core Animation for presentation layers.
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Allow the layer to present at the display's native refresh rate.
        // ghostty manages its own vsync via CVDisplayLink.
        self.displaySyncEnabled = true

        // Use the default pixel format expected by ghostty.
        self.pixelFormat = .bgra8Unorm

        // Enable EDR for HDR content if available.
        self.wantsExtendedDynamicRangeContent = true

        // Set opaque to false to support background transparency.
        self.isOpaque = false

        // Framebuffer-only is the most efficient mode since we don't need
        // to read back from the drawable.
        self.framebufferOnly = true
    }

    /// Debug helper: log drawable acquisition.
    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        if drawable == nil {
            logger.debug("nextDrawable returned nil - frame will be dropped")
        }
        return drawable
    }
}
