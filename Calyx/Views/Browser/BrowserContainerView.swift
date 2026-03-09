import SwiftUI
import AppKit

struct BrowserContainerView: View {
    let controller: BrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbarView(controller: controller)
            
            if let error = controller.browserState.lastError {
                ErrorBannerView(message: error)
            }
            
            BrowserWebViewRepresentable(browserView: controller.browserView)
        }
    }
}

// MARK: - Toolbar

private struct BrowserToolbarView: View {
    let controller: BrowserTabController

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { controller.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.browserState.canGoBack)
            .accessibilityIdentifier(AccessibilityID.Browser.backButton)

            Button(action: { controller.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.browserState.canGoForward)
            .accessibilityIdentifier(AccessibilityID.Browser.forwardButton)

            Button(action: { controller.reload() }) {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityIdentifier(AccessibilityID.Browser.reloadButton)

            Text(controller.browserState.url.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(AccessibilityID.Browser.urlDisplay)

            if controller.browserState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Browser.toolbar)
    }
}

// MARK: - Error Banner

private struct ErrorBannerView: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.15))
        .accessibilityIdentifier(AccessibilityID.Browser.errorBanner)
    }
}

// MARK: - NSViewRepresentable

private struct BrowserWebViewRepresentable: NSViewRepresentable {
    let browserView: BrowserView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        browserView.frame = container.bounds
        browserView.autoresizingMask = [.width, .height]
        container.addSubview(browserView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if browserView.superview !== nsView {
            browserView.removeFromSuperview()
            browserView.frame = nsView.bounds
            browserView.autoresizingMask = [.width, .height]
            nsView.addSubview(browserView)
        }
    }
}
