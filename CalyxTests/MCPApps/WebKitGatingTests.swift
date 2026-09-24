//
//  WebKitGatingTests.swift
//  CalyxTests
//
//  Off-window WKWebView tests for the MCP Apps view host's WebKit
//  hardening (plan §6): CSP enforced on the custom-scheme response,
//  WKContentRuleList blocking as defense in depth even when CSP alone
//  would allow something, secure-context primitives available, host and
//  view origins distinct, the bridge only reachable from its isolated
//  WKContentWorld (never the page world), WebRTC removed even in a
//  same-origin child frame, alert() suppressed by the iframe sandbox
//  (never reaching NSAlert), navigation/window.open blocked past the
//  initial load, and camera access always denied.
//
//  NO external network: loopback HTTP listeners started by the test
//  stand in for declared and undeclared origins, and the scheme handler
//  answers only its own view's two URLs.
//
//  Per the plan's own verification section: if any assumption below
//  fails at implementation time, work stops there and is reported --
//  nothing is patched around it or piled on top of it.
//

import Network
import os
import WebKit
import XCTest
@testable import Calyx

// MARK: - Loopback HTTP listener (stands in for a declared external origin)

/// Answers every request with 200 "ok" and `Access-Control-Allow-Origin: *`.
private final class LoopbackHTTPServer: Sendable {
    let listener: NWListener
    let origin: String

    private init(listener: NWListener, origin: String) {
        self.listener = listener
        self.origin = origin
    }

    static func start() async throws -> LoopbackHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let body = "ok"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let claim = { resumed.withLock { alreadyResumed -> Bool in
                    defer { alreadyResumed = true }
                    return !alreadyResumed
                } }
                switch state {
                case .ready:
                    guard claim() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    guard claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        return LoopbackHTTPServer(listener: listener, origin: "http://127.0.0.1:\(port)")
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - Navigation waiter

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(for webView: WKWebView, load url: URL) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private func evaluate(_ webView: WKWebView, _ script: String) async throws -> Any? {
    try await webView.callAsyncJavaScript("return (\(script));", arguments: [:], in: nil, contentWorld: .page)
}

@MainActor
final class WebKitGatingTests: XCTestCase {

    // MARK: - CSP enforcement on the custom-scheme response

    // A CSP source matches only its own scheme (CSP3 §6.7.2.7), so the
    // declared and undeclared endpoints are real loopback HTTP listeners
    // (WKWebView fetches from its network process, out of reach of
    // URLProtocol stubs). CSP and rule list come from the same CSPDomains.
    func test_cspHeader_blocksUndeclaredFetch_allowsDeclaredFetch() async throws {
        let declaredServer = try await LoopbackHTTPServer.start()
        let undeclaredServer = try await LoopbackHTTPServer.start()
        defer {
            declaredServer.stop()
            undeclaredServer.stop()
        }
        let domains = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: [declaredServer.origin], frameDomains: [], baseUriDomains: []
        )
        let policy = MCPAppCSPBuilder.buildPolicy(csp: domains, hostOrigin: "calyx-mcp-host://abc").policy

        let html = """
        <!DOCTYPE html><html><body><script>
        window.results = {};
        fetch('\(declaredServer.origin)/x').then(() => window.results.declared = 'ok').catch(e => window.results.declared = 'blocked');
        fetch('\(undeclaredServer.origin)/x').then(() => window.results.undeclared = 'ok').catch(e => window.results.undeclared = 'blocked');
        </script></body></html>
        """
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(
            html: html, cspPolicy: policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(csp: domains, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: []),
            additionalSchemeHandlers: [:]
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let waiter = NavigationWaiter()
        try await waiter.wait(for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!)

        // Poll briefly for both fetches to settle.
        var declared: String?
        var undeclared: String?
        for _ in 0..<20 {
            declared = try await evaluate(webView, "window.results.declared") as? String
            undeclared = try await evaluate(webView, "window.results.undeclared") as? String
            if declared != nil && undeclared != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(undeclared, "blocked", "connect-src must reject a domain that was never declared")
        XCTAssertEqual(declared, "ok", "connect-src must allow a domain that WAS declared")
    }

    // MARK: - Reference-host script allowances (eval, blob: workers)

    // The ext-apps reference apps (map/CesiumJS, threejs) evaluate strings
    // and start workers from blob: URLs. Both must run under the built
    // policy AND the built rule list, inside the sandboxed view document.
    func test_builtPolicy_allowsEvalAndBlobWorker() async throws {
        let domains = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://*.cesium.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let html = """
        <!DOCTYPE html><html><body><script>
        window.results = {};
        try { window.results.eval = String(eval('1+1')); } catch (e) { window.results.eval = 'error:' + e.message; }
        try {
          const url = URL.createObjectURL(new Blob(['self.postMessage("hi")'], { type: 'application/javascript' }));
          const worker = new Worker(url);
          worker.onmessage = (event) => { window.results.worker = event.data === 'hi' ? 'ok' : 'unexpected'; };
          worker.onerror = (event) => { window.results.worker = 'error:' + event.message; };
        } catch (e) { window.results.worker = 'error:' + e.message; }
        </script></body></html>
        """
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(
            html: html,
            cspPolicy: MCPAppCSPBuilder.buildPolicy(csp: domains, hostOrigin: "calyx-mcp-host://abc").policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(csp: domains, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: []),
            additionalSchemeHandlers: [:]
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try await NavigationWaiter().wait(for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!)

        var evalResult: String?
        var workerResult: String?
        for _ in 0..<40 {
            evalResult = try await evaluate(webView, "window.results.eval") as? String
            workerResult = try await evaluate(webView, "window.results.worker") as? String
            if evalResult != nil && workerResult != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(evalResult, "2", "script-src must carry 'unsafe-eval' like the reference host")
        XCTAssertEqual(workerResult, "ok", "worker-src blob: and the rule list must let a blob: worker start")
    }

    func test_builtPolicy_omittedCSP_stillBlocksUndeclaredFetch() async throws {
        let server = try await LoopbackHTTPServer.start()
        defer { server.stop() }
        let html = """
        <!DOCTYPE html><html><body><script>
        window.result = 'pending';
        fetch('\(server.origin)/x').then(() => window.result = 'ok').catch(e => window.result = 'blocked');
        </script></body></html>
        """
        // The rule list lifts the loopback origin, so only the CSP decides.
        let liftingDomains = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: [server.origin], frameDomains: [], baseUriDomains: []
        )
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(
            html: html,
            cspPolicy: MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: "calyx-mcp-host://abc").policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(
                csp: liftingDomains, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: []
            ),
            additionalSchemeHandlers: [:]
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try await NavigationWaiter().wait(for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!)

        var result: String?
        for _ in 0..<20 {
            result = try await evaluate(webView, "window.result") as? String
            if result != "pending" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(result, "blocked", "connect-src 'self' must still reject an origin that was never declared")
    }

    // MARK: - Content rule list blocks even when CSP alone would allow it

    func test_contentRuleList_blocksFetch_evenWithPermissiveCSP() async throws {
        // The CSP allows the loopback origin, so ONLY the content rule list
        // decides. Both arms run: a list lifting the origin lets the fetch
        // through, a list that does not lift it blocks the same fetch.
        let server = try await LoopbackHTTPServer.start()
        defer { server.stop() }
        let domains = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: [server.origin], frameDomains: [], baseUriDomains: []
        )
        let permissiveCSP = MCPAppCSPBuilder.buildPolicy(csp: domains, hostOrigin: "calyx-mcp-host://abc").policy
        let html = """
        <!DOCTYPE html><html><body><script>
        window.result = 'pending';
        fetch('\(server.origin)/x').then(() => window.result = 'ok').catch(e => window.result = 'blocked');
        </script></body></html>
        """

        func fetchResult(ruleList: String) async throws -> String? {
            let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(
                html: html, cspPolicy: permissiveCSP, contentRuleListJSON: ruleList, additionalSchemeHandlers: [:]
            )
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let waiter = NavigationWaiter()
            try await waiter.wait(for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!)

            var result: String?
            for _ in 0..<20 {
                result = try await evaluate(webView, "window.result") as? String
                if result != "pending" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return result
        }

        let allowed = try await fetchResult(
            ruleList: MCPAppCSPBuilder.contentRuleList(csp: domains, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: [])
        )
        XCTAssertEqual(allowed, "ok", "with the origin lifted in the rule list the fetch succeeds, so the CSP alone allows it")

        let result = try await fetchResult(
            ruleList: MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: [])
        )
        XCTAssertEqual(result, "blocked", "the content rule list must block an undeclared origin even under a permissive CSP")
    }

    // MARK: - The scheme handler answers only its own view's two URLs

    func test_schemeHandler_refusesAnotherViewsDocumentURL() async throws {
        let hostOrigin = "\(MCPAppWebViewFactory.hostScheme)://host-a"
        let viewOrigin = "\(MCPAppWebViewFactory.appScheme)://view-a"
        let document = MCPAppViewDocument(
            html: "<!DOCTYPE html><html><body>view</body></html>",
            viewOrigin: viewOrigin,
            hostOrigin: hostOrigin,
            cspPolicy: MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: hostOrigin).policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: hostOrigin, calyxOrigins: [viewOrigin]),
            contentRuleListIdentifier: MCPAppWebViewFactory.contentRuleListIdentifierPrefix + UUID().uuidString
        )
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(document: document, additionalSchemeHandlers: [:])
        let webView = WKWebView(frame: .zero, configuration: configuration)

        try await NavigationWaiter().wait(for: webView, load: URL(string: "\(hostOrigin)/")!)

        do {
            try await NavigationWaiter().wait(
                for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://view-b/index.html")!
            )
            XCTFail("a second view's document URL must not be served by this view's scheme handler")
        } catch {}
    }

    // MARK: - Secure context primitives

    func test_secureContextPrimitives_available() async throws {
        let webView = try await makeBasicViewWebView()

        let isSecureContext = try await evaluate(webView, "window.isSecureContext") as? Bool
        let hasRandomUUID = try await evaluate(webView, "typeof crypto.randomUUID === 'function'") as? Bool
        let hasSubtle = try await evaluate(webView, "typeof crypto.subtle === 'object' && crypto.subtle !== null") as? Bool

        XCTAssertEqual(isSecureContext, true)
        XCTAssertEqual(hasRandomUUID, true)
        XCTAssertEqual(hasSubtle, true)
    }

    // MARK: - Host and view origins are distinct

    func test_hostAndViewOrigins_areDistinct() async throws {
        let hostConfiguration = MCPAppWebViewFactory.makeHostPageConfiguration(html: "<!DOCTYPE html><html><body></body></html>")
        let hostWebView = WKWebView(frame: .zero, configuration: hostConfiguration)
        let hostWaiter = NavigationWaiter()
        try await hostWaiter.wait(for: hostWebView, load: URL(string: "\(MCPAppWebViewFactory.hostScheme)://xyz/")!)

        let viewWebView = try await makeBasicViewWebView()

        let hostOrigin = try await evaluate(hostWebView, "window.location.origin") as? String
        let viewOrigin = try await evaluate(viewWebView, "window.location.origin") as? String

        XCTAssertNotNil(hostOrigin)
        XCTAssertNotNil(viewOrigin)
        XCTAssertNotEqual(hostOrigin, viewOrigin)
    }

    // MARK: - Bridge only reachable from its isolated content world

    func test_bridgeHandler_undefinedInViewPageWorld() async throws {
        let webView = try await makeBasicViewWebView(withBridge: true)

        let handlerType = try await evaluate(webView, "typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.calyxMcpApp)") as? String

        XCTAssertEqual(handlerType, "undefined",
            "the bridge handler must be registered ONLY in its named isolated WKContentWorld, invisible to the page's own default world")
    }

    // MARK: - Alert suppressed by sandbox, never reaches NSAlert / uiDelegate

    func test_alertCall_returnsWithoutInvokingUIDelegate() async throws {
        let webView = try await makeBasicViewWebView()
        let uiDelegate = RecordingUIDelegate()
        webView.uiDelegate = uiDelegate

        let result = try await evaluate(webView, "(function(){ alert('should be suppressed'); return 'reached'; })()") as? String

        XCTAssertEqual(result, "reached", "alert() inside the sandboxed iframe must return immediately, not block on a panel")
        XCTAssertEqual(uiDelegate.alertPanelCallCount, 0, "the sandbox (no allow-modals) must suppress the alert before it ever reaches the host's uiDelegate")
    }

    // MARK: - Navigation guard: only the initial load is allowed

    func test_navigationGuard_allowsOnlyTheDeclaredInitialURLs() async throws {
        let allowedURL = URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!
        let otherURL = URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/other.html")!
        let guardDelegate = MCPAppNavigationGuard(allowedInitialURLs: [allowedURL])

        let decisionForAllowed = await policyDecision(guardDelegate, url: allowedURL)
        XCTAssertEqual(decisionForAllowed, .allow)

        let decisionForOther = await policyDecision(guardDelegate, url: otherURL)
        XCTAssertEqual(decisionForOther, .cancel, "any URL outside the declared initial set must be cancelled")
    }

    func test_navigationGuard_secondNavigationToTheSameAllowedURL_isCancelled() async throws {
        let allowedURL = URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!
        let guardDelegate = MCPAppNavigationGuard(allowedInitialURLs: [allowedURL])

        _ = await policyDecision(guardDelegate, url: allowedURL)
        let secondDecision = await policyDecision(guardDelegate, url: allowedURL)

        XCTAssertEqual(secondDecision, .cancel, "only the FIRST load may proceed -- a later navigation to the same URL is not a fresh initial load")
    }

    // MARK: - window.open blocked

    func test_windowOpen_neverCreatesANewWebView() async throws {
        let webView = try await makeBasicViewWebView()
        let uiDelegate = RecordingUIDelegate()
        webView.uiDelegate = uiDelegate

        _ = try? await evaluate(webView, "window.open('https://example.com')")

        XCTAssertEqual(uiDelegate.createWebViewCallCount, 0, "window.open must never reach a createWebView call that would actually open something")
    }

    // MARK: - RTCPeerConnection removed, including in a child frame

    func test_rtcPeerConnection_undefinedInMainFrame_andInChildFrame() async throws {
        let webView = try await makeBasicViewWebView()

        let mainFrameType = try await evaluate(webView, "typeof RTCPeerConnection") as? String
        XCTAssertEqual(mainFrameType, "undefined")

        let script = """
        (function() {
          return new Promise((resolve) => {
            const iframe = document.createElement('iframe');
            iframe.src = 'about:blank';
            iframe.onload = () => {
              resolve(typeof iframe.contentWindow.RTCPeerConnection);
            };
            document.body.appendChild(iframe);
          });
        })()
        """
        let childFrameType = try await evaluate(webView, script) as? String
        XCTAssertEqual(childFrameType, "undefined", "the WebRTC removal user script must inject into EVERY frame, including an about:blank child frame")
    }

    // MARK: - Camera and microphone access always denied

    // WKSecurityOrigin/WKFrameInfo cannot be constructed directly in a unit
    // test host; this drives the decision function the same way WebKit
    // itself would (via WKUIDelegate's requestMediaCapturePermissionFor:type:),
    // through the delegate's own decision closure, for every WKMediaCaptureType.
    private func assertMediaCaptureDenied(_ type: WKMediaCaptureType, line: UInt = #line) {
        let delegate = MCPAppMediaPermissionDelegate()
        let decision: WKPermissionDecision? = delegate.decide(type: type)

        XCTAssertEqual(decision, .deny, "type \(type) must be denied", line: line)
    }

    func test_mediaPermission_cameraRequest_isAlwaysDenied() {
        assertMediaCaptureDenied(.camera)
    }

    func test_mediaPermission_microphoneRequest_isAlwaysDenied() {
        assertMediaCaptureDenied(.microphone)
    }

    func test_mediaPermission_cameraAndMicrophoneRequest_isAlwaysDenied() {
        assertMediaCaptureDenied(.cameraAndMicrophone)
    }

    // MARK: - Helpers

    private func makeBasicViewWebView(withBridge: Bool = false) async throws -> WKWebView {
        let policy = MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: "calyx-mcp-host://abc").policy
        let ruleList = MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: "calyx-mcp-host://abc", calyxOrigins: [])
        let html = "<!DOCTYPE html><html><body>view</body></html>"
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(
            html: html, cspPolicy: policy, contentRuleListJSON: ruleList, additionalSchemeHandlers: [:]
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if withBridge {
            MCPAppWebViewFactory.installBridge(
                into: webView, world: .world(name: "calyxMcpAppBridge"), handler: RecordingBridgeHandler()
            )
        }
        let waiter = NavigationWaiter()
        try await waiter.wait(for: webView, load: URL(string: "\(MCPAppWebViewFactory.appScheme)://app.local/index.html")!)
        return webView
    }

    private func policyDecision(_ delegate: MCPAppNavigationGuard, url: URL) async -> WKNavigationActionPolicy {
        await withCheckedContinuation { continuation in
            delegate.decide(forURL: url) { policy in
                continuation.resume(returning: policy)
            }
        }
    }
}

// MARK: - Recording fakes

private final class RecordingUIDelegate: NSObject, WKUIDelegate {
    private(set) var alertPanelCallCount = 0
    private(set) var createWebViewCallCount = 0

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        alertPanelCallCount += 1
        completionHandler()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        createWebViewCallCount += 1
        return nil
    }
}

private final class RecordingBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        replyHandler(["ok": true], nil)
    }
}
