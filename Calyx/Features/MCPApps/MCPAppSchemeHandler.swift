//
//  MCPAppSchemeHandler.swift
//  Calyx
//
//  Serves the two documents one MCP Apps web view ever loads: its host page
//  (`calyx-mcp-host://<id>/`) and its view document
//  (`calyx-mcp-app://<host>/index.html`). Every other URL fails, which is
//  what keeps one view from loading another view's document.
//

import Foundation
import WebKit

@MainActor
final class MCPAppSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The iframe sandbox of the host page, repeated as a CSP `sandbox`
    /// directive on the view document. No allow-modals, allow-popups or
    /// allow-downloads, so dialogs, new windows and downloads never reach
    /// the host.
    nonisolated static let iframeSandbox = "allow-scripts allow-same-origin allow-forms"

    /// Which URL a document answers.
    enum Binding: Equatable {
        /// Only this URL.
        case exact(URL)
        /// The first URL requested with the document's path (`/` for the
        /// host page, `/index.html` for the view), and only that URL after.
        case firstRequested
    }

    struct Served {
        let html: String
        /// The full `Content-Security-Policy` header value, or nil for none.
        let contentSecurityPolicy: String?
        let binding: Binding
    }

    private let hostPage: Served?
    private let viewDocument: Served?
    private var boundHostPageURL: URL?
    private var boundViewURL: URL?

    init(hostPage: Served?, viewDocument: Served?) {
        self.hostPage = hostPage
        self.viewDocument = viewDocument
        if case .exact(let url) = hostPage?.binding { boundHostPageURL = Self.normalized(url) }
        if case .exact(let url) = viewDocument?.binding { boundViewURL = Self.normalized(url) }
    }

    /// `calyx-mcp-app://<host>` plus the view document path.
    nonisolated static func viewDocumentURL(viewOrigin: String) -> URL? {
        URL(string: viewOrigin + "/index.html")
    }

    nonisolated static func hostPageURL(hostOrigin: String) -> URL? {
        URL(string: hostOrigin + "/")
    }

    /// The view document's header: the resource's policy, then a second
    /// policy that sandboxes the document itself, so the sandbox holds even
    /// when the view is loaded top-level.
    nonisolated static func viewContentSecurityPolicy(_ policy: String) -> String {
        policy + ", sandbox \(iframeSandbox)"
    }

    /// A usable view document host (`_meta.ui.domain`): letters, digits,
    /// `-` and `.` only, so it is safe in a URL host and an HTML attribute.
    nonisolated static func isValidViewHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
            return false
        }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// The host page for `viewURL`: no script, one sandboxed iframe.
    nonisolated static func hostPageHTML(viewURL: URL) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\
        html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent}\
        iframe{border:0;display:block;width:100%;height:100%}\
        </style></head><body><iframe sandbox="\(iframeSandbox)" referrerpolicy="no-referrer" \
        src="\(viewURL.absoluteString)"></iframe></body></html>
        """
    }

    /// The host page's own policy: no script, framing only the view origin.
    nonisolated static func hostPageContentSecurityPolicy(viewOrigin: String) -> String {
        "default-src 'none'; style-src 'unsafe-inline'; frame-src \(viewOrigin); frame-ancestors 'none';"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let served = served(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = Data(served.html.utf8)
        var headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
        if let policy = served.contentSecurityPolicy {
            headers["Content-Security-Policy"] = policy
        }
        // Status and header fields are well-formed, so the response always exists.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    // MARK: - Private

    private func served(for url: URL) -> Served? {
        let requested = Self.normalized(url)
        switch url.scheme?.lowercased() {
        case MCPAppWebViewFactory.hostScheme:
            guard let hostPage, Self.matches(requested, path: "/", bound: &boundHostPageURL) else { return nil }
            return hostPage
        case MCPAppWebViewFactory.appScheme:
            guard let viewDocument, Self.matches(requested, path: "/index.html", bound: &boundViewURL) else { return nil }
            return viewDocument
        default:
            return nil
        }
    }

    private static func matches(_ requested: URL, path: String, bound: inout URL?) -> Bool {
        if let bound { return bound == requested }
        guard requested.path == path else { return false }
        bound = requested
        return true
    }

    /// Scheme and host lowercased, query and fragment dropped, empty path as `/`.
    private static func normalized(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        components.port = url.port
        components.path = url.path.isEmpty ? "/" : url.path
        return components.url ?? url
    }
}
