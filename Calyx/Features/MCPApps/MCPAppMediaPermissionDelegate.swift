//
//  MCPAppMediaPermissionDelegate.swift
//  Calyx
//
//  Denies every camera and microphone request and never opens a window.
//  JavaScript dialogs never reach this delegate: the view's sandbox has no
//  allow-modals.
//

import Foundation
import WebKit

/// WebKit calls UI delegates on the main thread, so the delegate is
/// main-actor isolated, which also makes it `Sendable`.
@MainActor
final class MCPAppMediaPermissionDelegate: NSObject, WKUIDelegate {

    func decide(type: WKMediaCaptureType) -> WKPermissionDecision {
        switch type {
        case .camera, .microphone, .cameraAndMicrophone:
            return .deny
        @unknown default:
            return .deny
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(decide(type: type))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
