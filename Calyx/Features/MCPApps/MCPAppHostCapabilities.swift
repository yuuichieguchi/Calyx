//
//  MCPAppHostCapabilities.swift
//  Calyx
//
//  The `ui/initialize` result pieces that describe Calyx: the negotiated
//  protocol version, `hostInfo`, and `hostCapabilities` in the exact
//  `McpUiHostCapabilities` shape of ext-apps spec.types.ts.
//

import Foundation

enum MCPAppHostCapabilities {
    static let protocolVersion = "2026-01-26"

    /// Calyx never rejects a view's initialize: it always answers with the
    /// version it speaks.
    static func negotiateVersion(requested: String) -> String {
        protocolVersion
    }

    struct Built: Sendable, Equatable {
        let raw: [String: AnyCodable]

        subscript(_ key: String) -> AnyCodable? {
            raw[key]
        }
    }

    /// `sandbox.permissions` grants only clipboardWrite (never camera,
    /// microphone or geolocation). `message` and `updateModelContext`
    /// declare text and image. No `sampling`: Calyx has no model.
    static func build(appliedCSP: MCPAppCSPBuilder.CSPDomains?) -> Built {
        let empty = AnyCodable([String: AnyCodable]())
        let modalities = AnyCodable(["text": empty, "image": empty])
        let csp = appliedCSP ?? MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: [])
        func strings(_ values: [String]) -> AnyCodable { AnyCodable(values.map { AnyCodable($0) }) }
        return Built(raw: [
            "openLinks": empty,
            "downloadFile": empty,
            "serverTools": AnyCodable(["listChanged": AnyCodable(true)]),
            "serverResources": AnyCodable(["listChanged": AnyCodable(true)]),
            "logging": empty,
            "sandbox": AnyCodable([
                "permissions": AnyCodable(["clipboardWrite": empty]),
                "csp": AnyCodable([
                    "connectDomains": strings(csp.connectDomains),
                    "resourceDomains": strings(csp.resourceDomains),
                    "frameDomains": strings(csp.frameDomains),
                    "baseUriDomains": strings(csp.baseUriDomains),
                ]),
            ]),
            "updateModelContext": modalities,
            "message": modalities,
        ])
    }

    /// `McpUiInitializeResult.hostInfo` (required by spec.types.ts).
    static let hostInfo = MCPImplementation(
        name: "Calyx",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        title: nil,
        description: nil,
        websiteUrl: nil
    )

    /// The full `ui/initialize` result.
    static func initializeResult(requestedVersion: String, appliedCSP: MCPAppCSPBuilder.CSPDomains?, hostContext: [String: AnyCodable]) -> [String: AnyCodable] {
        [
            "protocolVersion": AnyCodable(negotiateVersion(requested: requestedVersion)),
            "hostInfo": AnyCodable([
                "name": AnyCodable(hostInfo.name),
                "version": AnyCodable(hostInfo.version),
            ]),
            "hostCapabilities": AnyCodable(build(appliedCSP: appliedCSP).raw),
            "hostContext": AnyCodable(hostContext),
        ]
    }
}
