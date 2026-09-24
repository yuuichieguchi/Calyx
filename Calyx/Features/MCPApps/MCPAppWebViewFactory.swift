//
//  MCPAppWebViewFactory.swift
//  Calyx
//
//  WKWebView configurations for MCP Apps views. A view web view loads the
//  host page (`calyx-mcp-host://<id>/`, no script, one sandboxed iframe),
//  and the iframe loads the view document
//  (`calyx-mcp-app://<host>/index.html`) with its Content-Security-Policy
//  header. Both are served by `MCPAppSchemeHandler`. Each view gets its
//  own non-persistent data store and its own compiled WKContentRuleList.
//  The bridge lives in a named WKContentWorld, invisible to the page.
//

import Foundation
import WebKit

@MainActor
enum MCPAppWebViewFactory {
    nonisolated static let appScheme = "calyx-mcp-app"
    nonisolated static let hostScheme = "calyx-mcp-host"

    /// The script message handler name, registered only in the bridge world.
    nonisolated static let bridgeHandlerName = "calyxMcpApp"

    /// Every per-view content rule list identifier starts with this, so
    /// `sweepStaleContentRuleLists()` can find lists a previous run left behind.
    nonisolated static let contentRuleListIdentifierPrefix = "com.calyx.mcpApps.view."

    static func makeHostPageConfiguration(html: String) -> WKWebViewConfiguration {
        let configuration = baseConfiguration()
        let handler = MCPAppSchemeHandler(
            hostPage: .init(html: html, contentSecurityPolicy: nil, binding: .firstRequested),
            viewDocument: nil
        )
        configuration.setURLSchemeHandler(handler, forURLScheme: hostScheme)
        return configuration
    }

    /// Serves `html` as the view document at the first
    /// `calyx-mcp-app://<host>/index.html` loaded, and nothing else.
    static func makeViewConfiguration(
        html: String,
        cspPolicy: String,
        contentRuleListJSON: String,
        additionalSchemeHandlers: [String: any WKURLSchemeHandler]
    ) async throws -> WKWebViewConfiguration {
        let handler = MCPAppSchemeHandler(
            hostPage: nil,
            viewDocument: .init(
                html: html,
                contentSecurityPolicy: MCPAppSchemeHandler.viewContentSecurityPolicy(cspPolicy),
                binding: .firstRequested
            )
        )
        return try await makeConfiguration(
            handler: handler,
            contentRuleListJSON: contentRuleListJSON,
            contentRuleListIdentifier: contentRuleListIdentifierPrefix + UUID().uuidString,
            additionalSchemeHandlers: additionalSchemeHandlers
        )
    }

    /// The configuration a mounted view uses: the host page at
    /// `document.hostOrigin` framing the view document at
    /// `document.viewOrigin`, each answered at exactly that URL.
    static func makeViewConfiguration(
        document: MCPAppViewDocument,
        additionalSchemeHandlers: [String: any WKURLSchemeHandler]
    ) async throws -> WKWebViewConfiguration {
        guard let hostPageURL = MCPAppSchemeHandler.hostPageURL(hostOrigin: document.hostOrigin),
              let viewURL = MCPAppSchemeHandler.viewDocumentURL(viewOrigin: document.viewOrigin) else {
            throw MCPAppWebViewFactoryError.invalidOrigin
        }
        let handler = MCPAppSchemeHandler(
            hostPage: .init(
                html: MCPAppSchemeHandler.hostPageHTML(viewURL: viewURL),
                contentSecurityPolicy: MCPAppSchemeHandler.hostPageContentSecurityPolicy(viewOrigin: document.viewOrigin),
                binding: .exact(hostPageURL)
            ),
            viewDocument: .init(
                html: document.html,
                contentSecurityPolicy: MCPAppSchemeHandler.viewContentSecurityPolicy(document.cspPolicy),
                binding: .exact(viewURL)
            )
        )
        return try await makeConfiguration(
            handler: handler,
            contentRuleListJSON: document.contentRuleListJSON,
            contentRuleListIdentifier: document.contentRuleListIdentifier,
            additionalSchemeHandlers: additionalSchemeHandlers
        )
    }

    /// Installs the bridge script and `handler` in `world` only. The script
    /// runs in the host page, accepts a message only when `event.source` is
    /// the view iframe's window and `event.origin` is the view origin, and
    /// replies with `postMessage(reply, viewOrigin)`.
    static func installBridge(into webView: WKWebView, world: WKContentWorld, handler: any WKScriptMessageHandlerWithReply) {
        let controller = webView.configuration.userContentController
        controller.addScriptMessageHandler(handler, contentWorld: world, name: bridgeHandlerName)
        controller.addUserScript(WKUserScript(
            source: bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))
    }

    /// Removes the bridge handler, every user script, and every content
    /// rule list from `webView`.
    static func removeBridgeAndContent(from webView: WKWebView, world: WKContentWorld) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: bridgeHandlerName, contentWorld: world)
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
    }

    static func removeContentRuleList(identifier: String) async throws {
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
    }

    /// Removes every per-view content rule list still in the store. Called
    /// once at startup, before any view exists.
    static func sweepStaleContentRuleLists() async throws {
        let store: WKContentRuleListStore = .default()
        let identifiers = await store.availableIdentifiers() ?? []
        for identifier in identifiers where identifier.hasPrefix(contentRuleListIdentifierPrefix) {
            try await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    /// Posts `json` (one serialized JSON-RPC message) to the view from the
    /// bridge world. Returns false when the host page has no iframe.
    static func postToView(_ webView: WKWebView, json: String, world: WKContentWorld) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return globalThis.__calyxMcpAppBridge.post(message);",
            arguments: ["message": json],
            in: nil,
            contentWorld: world
        )
        return (result as? Bool) == true
    }

    // MARK: - Private

    private static func makeConfiguration(
        handler: MCPAppSchemeHandler,
        contentRuleListJSON: String,
        contentRuleListIdentifier: String,
        additionalSchemeHandlers: [String: any WKURLSchemeHandler]
    ) async throws -> WKWebViewConfiguration {
        let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: contentRuleListIdentifier,
            encodedContentRuleList: contentRuleListJSON
        )

        let configuration = baseConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: hostScheme)
        configuration.setURLSchemeHandler(handler, forURLScheme: appScheme)
        for (scheme, schemeHandler) in additionalSchemeHandlers {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)
        }
        if let ruleList {
            configuration.userContentController.add(ruleList)
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: webRTCRemovalScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        return configuration
    }

    private static func baseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    /// Deletes the WebRTC constructors in every frame, and again on any
    /// same-origin child window read through `contentWindow`.
    private static let webRTCRemovalScript = """
    (() => {
      const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
        'RTCSessionDescription', 'RTCIceCandidate', 'RTCRtpSender', 'RTCRtpReceiver',
        'RTCRtpTransceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport',
        'RTCCertificate', 'RTCTrackEvent', 'RTCDataChannelEvent', 'RTCPeerConnectionIceEvent',
        'RTCPeerConnectionIceErrorEvent', 'RTCError', 'RTCErrorEvent', 'RTCDTMFSender',
        'RTCDTMFToneChangeEvent', 'RTCRtpScriptTransform', 'RTCEncodedAudioFrame',
        'RTCEncodedVideoFrame'];
      const scrub = (w) => {
        try { for (const n of names) { try { delete w[n]; } catch (e) {} } } catch (e) {}
        return w;
      };
      scrub(window);
      const elements = [globalThis.HTMLIFrameElement, globalThis.HTMLFrameElement, globalThis.HTMLObjectElement];
      for (const element of elements) {
        if (!element) continue;
        const proto = element.prototype;
        const desc = Object.getOwnPropertyDescriptor(proto, 'contentWindow');
        if (!desc || !desc.get) continue;
        Object.defineProperty(proto, 'contentWindow', {
          configurable: false,
          enumerable: desc.enumerable,
          get() { const w = desc.get.call(this); return w ? scrub(w) : w; }
        });
      }
    })();
    """

    private static let bridgeScript = """
    (() => {
      const frame = () => document.querySelector('iframe');
      const originOf = (f) => { const u = new URL(f.src); return u.protocol + '//' + u.host; };
      window.addEventListener('message', (event) => {
        const f = frame();
        if (!f || event.source !== f.contentWindow) return;
        const origin = originOf(f);
        if (event.origin !== origin) return;
        let text;
        try { text = JSON.stringify(event.data); } catch (e) { return; }
        if (typeof text !== 'string') return;
        window.webkit.messageHandlers.\(bridgeHandlerName).postMessage(text).then((reply) => {
          if (typeof reply !== 'string' || frame() !== f) return;
          f.contentWindow.postMessage(JSON.parse(reply), origin);
        }, () => {});
      });
      globalThis.__calyxMcpAppBridge = {
        post(text) {
          const f = frame();
          if (!f || !f.contentWindow) return false;
          f.contentWindow.postMessage(JSON.parse(text), originOf(f));
          return true;
        }
      };
    })();
    """
}

enum MCPAppWebViewFactoryError: Error, Equatable {
    /// A document origin did not form a URL.
    case invalidOrigin
    /// The store dropped the view before its web view was built.
    case viewRemoved
}
