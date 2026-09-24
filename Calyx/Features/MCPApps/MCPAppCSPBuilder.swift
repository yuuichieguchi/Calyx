//
//  MCPAppCSPBuilder.swift
//  Calyx
//
//  Builds the Content-Security-Policy the view document is served with,
//  and the WKContentRuleList that blocks every load outside the same
//  origins as defense in depth.
//
//  The policy has the directives of the ext-apps reference host
//  (examples/basic-host/serve.ts, `buildCspHeader`), which the reference
//  apps are built against: 'unsafe-eval' and blob: workers (CesiumJS,
//  Three.js) included. An omitted `_meta.ui.csp` is the declared form with
//  every domain list empty, as in the reference. Calyx adds
//  form-action 'none' and frame-ancestors <host page origin>.
//

import Foundation

enum MCPAppCSPBuilder {

    /// `McpUiResourceCsp` (ext-apps spec.types.ts).
    struct CSPDomains: Sendable, Equatable {
        let resourceDomains: [String]
        let connectDomains: [String]
        let frameDomains: [String]
        let baseUriDomains: [String]
    }

    /// Entries that would change the policy's structure or widen it past a
    /// named origin are dropped and reported with the reason. `applied`
    /// holds the entries the policy uses, in the form written into it
    /// (scheme-less entries carry `https://`); it is nil when `csp` is nil.
    static func buildPolicy(
        csp: CSPDomains?,
        hostOrigin: String
    ) -> (policy: String, dropped: [(raw: String, reason: String)], applied: CSPDomains?) {
        // The reference host builds an omitted `csp` with every list empty.
        let declared = csp ?? CSPDomains(resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: [])
        var dropped: [(raw: String, reason: String)] = []
        let resource = accepted(declared.resourceDomains, dropped: &dropped).map(\.text)
        let connect = accepted(declared.connectDomains, dropped: &dropped).map(\.text)
        let frame = accepted(declared.frameDomains, dropped: &dropped).map(\.text)
        let baseURI = accepted(declared.baseUriDomains, dropped: &dropped).map(\.text)

        let directives = [
            directive("default-src", ["'self'", "'unsafe-inline'"]),
            directive("script-src", ["'self'", "'unsafe-inline'", "'unsafe-eval'", "blob:", "data:"] + resource),
            directive("style-src", ["'self'", "'unsafe-inline'", "blob:", "data:"] + resource),
            directive("img-src", ["'self'", "data:", "blob:"] + resource),
            directive("font-src", ["'self'", "data:", "blob:"] + resource),
            directive("media-src", ["'self'", "data:", "blob:"] + resource),
            directive("connect-src", ["'self'"] + connect),
            directive("worker-src", ["'self'", "blob:"] + resource),
            directive("frame-src", frame.isEmpty ? ["'none'"] : frame),
            "object-src 'none'",
            directive("base-uri", baseURI.isEmpty ? ["'none'"] : baseURI),
            "form-action 'none'",
            "frame-ancestors \(hostOrigin)",
        ]
        let applied = csp.map { _ in
            CSPDomains(
                resourceDomains: resource,
                connectDomains: connect,
                frameDomains: frame,
                baseUriDomains: baseURI
            )
        }
        return (directives.joined(separator: "; ") + ";", dropped, applied)
    }

    /// WKContentRuleList JSON: the first rule blocks every URL, later rules
    /// lift the block for the Calyx origins, `data:`, `blob:`, `about:`,
    /// and each declared domain that `buildPolicy` accepts.
    ///
    /// Content rule lists also apply to the custom-scheme documents
    /// themselves, so both Calyx schemes are lifted as a whole. They are
    /// served only by the view's own `MCPAppSchemeHandler`, which answers
    /// the host page and the view document and nothing else.
    static func contentRuleList(csp: CSPDomains?, hostOrigin: String, calyxOrigins: [String]) -> String {
        var filters: [String] = []
        filters.append("^" + escapeRegex(hostOrigin) + "/")
        for origin in calyxOrigins {
            filters.append("^" + escapeRegex(origin) + "/")
        }
        filters.append("^" + escapeRegex(MCPAppWebViewFactory.hostScheme) + ":")
        filters.append("^" + escapeRegex(MCPAppWebViewFactory.appScheme) + ":")
        filters.append("^data:")
        filters.append("^blob:")
        filters.append("^about:")

        if let csp {
            var ignored: [(raw: String, reason: String)] = []
            let sources = accepted(
                csp.resourceDomains + csp.connectDomains + csp.frameDomains,
                dropped: &ignored
            )
            for source in sources {
                filters.append(urlFilter(for: source))
            }
        }

        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
        ]
        var seen: Set<String> = []
        for filter in filters where seen.insert(filter).inserted {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        // Built from string and dictionary literals only, so serialization cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Source validation

    private enum Rejection: String, Error {
        case empty = "empty entry"
        case illegalCharacter = "contains a character that would alter the policy (separator, quote, whitespace or control character)"
        case wildcardAll = "a bare wildcard would allow every origin"
        case schemeOnly = "a scheme without a host would allow every origin with that scheme"
        case insecureScheme = "plain http and ws are allowed only for loopback hosts"
        case unsupportedScheme = "only https, wss, and loopback http or ws are allowed"
        case malformedHost = "the host is not a valid host name"
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// An accepted source. `text` is the value written into the policy;
    /// it always carries an explicit scheme.
    private struct HostSource: Equatable {
        let text: String
        let scheme: String
        let host: String
        let port: String?
        let path: String?
    }

    /// Validates and normalizes each entry. Keeps declared order and drops
    /// duplicates of the normalized value. `dropped` reports the raw entry.
    private static func accepted(_ raws: [String], dropped: inout [(raw: String, reason: String)]) -> [HostSource] {
        var result: [HostSource] = []
        for raw in raws {
            switch validate(raw) {
            case .failure(let rejection):
                dropped.append((raw, rejection.rawValue))
            case .success(let source):
                if !result.contains(source) {
                    result.append(source)
                }
            }
        }
        return result
    }

    /// A scheme-less entry is a host-source that CSP matches against the
    /// document's scheme (CSP3 6.7.2.7), and the view document is served
    /// from a custom scheme. The ext-apps spec declares these fields as
    /// origins, so a scheme-less entry is read as `https://` + the entry.
    private static func validate(_ raw: String) -> Result<HostSource, Rejection> {
        if raw.isEmpty { return .failure(.empty) }
        for scalar in raw.unicodeScalars {
            if scalar.properties.generalCategory == .control
                || scalar.properties.isWhitespace
                || [";", ",", "'", "\"", "`"].contains(Character(scalar)) {
                return .failure(.illegalCharacter)
            }
        }
        if raw == "*" { return .failure(.wildcardAll) }

        let parts = SourceParts(raw)
        let scheme: String
        let text: String
        if let declaredScheme = parts.scheme {
            if parts.host.isEmpty { return .failure(.schemeOnly) }
            scheme = declaredScheme
            text = raw
        } else {
            scheme = "https"
            text = "https://" + raw
        }
        switch scheme {
        case "https", "wss":
            break
        case "http", "ws":
            if !loopbackHosts.contains(parts.host.lowercased()) { return .failure(.insecureScheme) }
        default:
            return .failure(.unsupportedScheme)
        }
        if !isValidHost(parts.host) { return .failure(.malformedHost) }
        return .success(HostSource(text: text, scheme: scheme, host: parts.host, port: parts.port, path: parts.path))
    }

    /// Host names, IPv4 literals, bracketed IPv6 literals, and a single
    /// leading `*.` wildcard label.
    private static func isValidHost(_ host: String) -> Bool {
        var name = Substring(host)
        if name.hasPrefix("[") && name.hasSuffix("]") {
            return name.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        if name.hasPrefix("*.") { name = name.dropFirst(2) }
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// A CSP host-source split into its parts. `scheme` is nil for a bare host.
    private struct SourceParts {
        let scheme: String?
        let host: String
        let port: String?
        let path: String?

        init(_ raw: String) {
            var rest = Substring(raw)
            if let range = rest.range(of: "://") {
                scheme = rest[rest.startIndex..<range.lowerBound].lowercased()
                rest = rest[range.upperBound...]
            } else if let colon = rest.firstIndex(of: ":"), rest[rest.startIndex..<colon].allSatisfy({ $0.isLetter }),
                      rest[rest.index(after: colon)...].isEmpty {
                // "https:" with nothing after the colon.
                scheme = rest[rest.startIndex..<colon].lowercased()
                rest = rest[rest.endIndex...]
            } else {
                scheme = nil
            }

            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[rest.startIndex..<authorityEnd]
            path = authorityEnd < rest.endIndex ? String(rest[authorityEnd...]) : nil

            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                host = String(authority[authority.startIndex...close])
                let afterHost = authority[authority.index(after: close)...]
                port = afterHost.hasPrefix(":") ? String(afterHost.dropFirst()) : nil
            } else if let colon = authority.lastIndex(of: ":") {
                host = String(authority[authority.startIndex..<colon])
                port = String(authority[authority.index(after: colon)...])
            } else {
                host = String(authority)
                port = nil
            }
        }
    }

    // MARK: - Rule list filters

    private static func directive(_ name: String, _ sources: [String]) -> String {
        ([name] + sources).joined(separator: " ")
    }

    /// A url-filter matching the URLs `source` names. A leading `*.` label
    /// becomes an optional group so the bare parent domain matches too.
    private static func urlFilter(for parts: HostSource) -> String {
        var filter = "^" + escapeRegex(parts.scheme) + "://"
        if parts.host.hasPrefix("*.") {
            filter += "([^/:]+\\.)?" + escapeRegex(String(parts.host.dropFirst(2)))
        } else {
            filter += escapeRegex(parts.host)
        }
        if let port = parts.port {
            filter += ":" + escapeRegex(port)
        }
        if let path = parts.path {
            filter += escapeRegex(path)
        } else if parts.port != nil {
            filter += "/"
        } else {
            filter += "[:/]"
        }
        return filter
    }

    private static func escapeRegex(_ text: String) -> String {
        let metacharacters: Set<Character> = [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]
        var escaped = ""
        for character in text {
            if metacharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
