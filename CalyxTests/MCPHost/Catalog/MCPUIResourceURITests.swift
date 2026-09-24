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
}
