//
//  MCPUIResourceURITests.swift
//  CalyxTests
//
//  Coverage: `MCPUIResourceURI` -- rewriting an upstream `ui://<rest>`
//  resource URI to the exported `ui://<alias>/<rest>` form (plan §4:
//  "再公開時に ui://<alias>/... へ書き換え"), and reversing it on
//  `resources/read`.
//
//  Assumed API surface:
//    enum MCPUIResourceURI {
//        static func export(upstreamURI: String, alias: String) -> String?
//        static func resolve(exportedURI: String) -> (alias: String, upstreamURI: String)?
//    }
//

import XCTest
@testable import Calyx

final class MCPUIResourceURITests: XCTestCase {

    // MARK: - export

    func test_export_prependsAliasAfterScheme() {
        let exported = MCPUIResourceURI.export(upstreamURI: "ui://weather/widget.html", alias: "myserver")
        XCTAssertEqual(exported, "ui://myserver/weather/widget.html")
    }

    func test_export_nonUIScheme_returnsNil() {
        XCTAssertNil(MCPUIResourceURI.export(upstreamURI: "https://example.com/widget.html", alias: "myserver"))
    }

    // MARK: - resolve (reverse)

    func test_resolve_roundTripsExportedURI() {
        let exported = MCPUIResourceURI.export(upstreamURI: "ui://weather/widget.html", alias: "myserver")!
        let resolved = MCPUIResourceURI.resolve(exportedURI: exported)
        XCTAssertEqual(resolved?.alias, "myserver")
        XCTAssertEqual(resolved?.upstreamURI, "ui://weather/widget.html")
    }

    func test_resolve_nonUIScheme_returnsNil() {
        XCTAssertNil(MCPUIResourceURI.resolve(exportedURI: "https://example.com/myserver/widget.html"))
    }

    func test_resolve_missingAliasSegment_returnsNil() {
        // ui://widget.html has no room for an alias segment at all.
        XCTAssertNil(MCPUIResourceURI.resolve(exportedURI: "ui://widget.html"))
    }

    func test_roundTrip_withNestedPathSegments() {
        let exported = MCPUIResourceURI.export(upstreamURI: "ui://weather/nested/deep/widget.html", alias: "srv")!
        XCTAssertEqual(exported, "ui://srv/weather/nested/deep/widget.html")
        let resolved = MCPUIResourceURI.resolve(exportedURI: exported)
        XCTAssertEqual(resolved?.upstreamURI, "ui://weather/nested/deep/widget.html")
        XCTAssertEqual(resolved?.alias, "srv")
    }

    // MARK: - exportingUIMeta (shared by the catalog and proxied results, K62)

    func test_exportingUIMeta_rewritesBothKeys_leavesTheRestUnchanged() {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["resourceUri": AnyCodable("ui://fixture/counter.html"), "prefersBorder": AnyCodable(true)]),
            "ui/resourceUri": AnyCodable("ui://fixture/counter.html"),
            "other": AnyCodable("kept"),
        ]

        let exported = MCPUIResourceURI.exportingUIMeta(meta, alias: "fx")

        XCTAssertEqual(exported, [
            "ui": AnyCodable(["resourceUri": AnyCodable("ui://fx/fixture/counter.html"), "prefersBorder": AnyCodable(true)]),
            "ui/resourceUri": AnyCodable("ui://fx/fixture/counter.html"),
            "other": AnyCodable("kept"),
        ])
    }

    func test_exportingUIMeta_nonUIScheme_unchanged() {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["resourceUri": AnyCodable("https://example.com/w.html")]),
            "ui/resourceUri": AnyCodable("https://example.com/w.html"),
        ]
        XCTAssertEqual(MCPUIResourceURI.exportingUIMeta(meta, alias: "fx"), meta)
    }

    func test_exportingUIMetaInRaw_withoutMeta_addsNothing() {
        let raw: [String: AnyCodable] = ["content": AnyCodable([AnyCodable]())]
        XCTAssertEqual(MCPUIResourceURI.exportingUIMeta(inRaw: raw, alias: "fx"), raw)
    }
}
