//
//  MCPAppNavigationGuard.swift
//  Calyx
//
//  Lets each declared initial URL load exactly once. Every later
//  navigation, every `window.open` and every download is cancelled.
//

import Foundation
import WebKit

/// WebKit calls navigation delegates on the main thread, so the guard is
/// main-actor isolated, which also makes it `Sendable`.
@MainActor
final class MCPAppNavigationGuard: NSObject, WKNavigationDelegate {

    private var remainingInitialURLs: [URL]

    /// Called for a web view's WebContent process ending.
    var onProcessTerminated: (() -> Void)?
    /// Called when the top-level document finished loading.
    var onDidFinishLoad: (() -> Void)?

    init(allowedInitialURLs: [URL]) {
        self.remainingInitialURLs = allowedInitialURLs
    }

    func decide(forURL url: URL, completion: @escaping (WKNavigationActionPolicy) -> Void) {
        if let index = remainingInitialURLs.firstIndex(of: url) {
            remainingInitialURLs.remove(at: index)
            completion(.allow)
        } else {
            completion(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !navigationAction.shouldPerformDownload, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decide(forURL: url) { decisionHandler($0) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinishLoad?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onProcessTerminated?()
    }
}
