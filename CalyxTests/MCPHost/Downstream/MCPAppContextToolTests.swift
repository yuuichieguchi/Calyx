//
//  MCPAppContextToolTests.swift
//  CalyxTests
//
//  Coverage: the pane-scoped `app_context` static tool (plan §1
//  decision on `ui/update-model-context`: "calyx-mcp のペイン単位ツール
//  app_context で、呼んだペインの生きているビューの最新コンテキストを
//  返します"). Pure given an injected `MCPAppModelContextProviding` --
//  no live WKWebView, no network.
//
//  Assumed API surface (uses the shared-contract `MCPAppModelContextEntry`
//  / `MCPAppModelContextProviding` types verbatim):
//    enum MCPAppContextTool {
//        static let name = "app_context"
//        static func result(surfaceID: UUID?, provider: any MCPAppModelContextProviding) -> MCPCallToolResult
//    }
//  `result(...)`'s shape: `raw["content"]` is an array with one JSON-text
//  item per live entry (each entry's `content`/`structuredContent`
//  surfaced verbatim), empty array when there are none.
//

import XCTest
@testable import Calyx

@MainActor
private final class FakeModelContextProvider: MCPAppModelContextProviding {
    var entriesBySurface: [UUID: [MCPAppModelContextEntry]] = [:]

    func modelContexts(forSurface surfaceID: UUID) -> [MCPAppModelContextEntry] {
        entriesBySurface[surfaceID] ?? []
    }
}

@MainActor
final class MCPAppContextToolTests: XCTestCase {

    private func entry(
        viewID: UUID = UUID(), serverDisplayName: String = "Weather", toolName: String = "get_weather",
        structuredContent: AnyCodable? = AnyCodable(["temp": AnyCodable(72)])
    ) -> MCPAppModelContextEntry {
        MCPAppModelContextEntry(
            viewID: viewID, serverDisplayName: serverDisplayName, toolName: toolName,
            content: nil, structuredContent: structuredContent
        )
    }

    func test_result_returnsOnlyTheCallingPanesEntries() {
        let provider = FakeModelContextProvider()
        let callingSurface = UUID()
        let otherSurface = UUID()
        provider.entriesBySurface[callingSurface] = [entry(toolName: "get_weather")]
        provider.entriesBySurface[otherSurface] = [entry(toolName: "get_stock_price")]

        let result = MCPAppContextTool.result(surfaceID: callingSurface, provider: provider)

        let content = result.raw["content"]?.arrayValue
        XCTAssertEqual(content?.count, 1, "must return only the calling pane's own entries, not another pane's")

        let serialized = String(describing: content)
        XCTAssertTrue(serialized.contains("get_weather"), "the calling pane's own entry must be present")
        XCTAssertFalse(serialized.contains("get_stock_price"),
                       "must never leak another pane's tool name into this pane's result")
    }

    func test_result_noLiveViewsForThisPane_emptyResultShape() {
        let provider = FakeModelContextProvider()
        let callingSurface = UUID()
        // No entries registered for callingSurface at all.

        let result = MCPAppContextTool.result(surfaceID: callingSurface, provider: provider)

        XCTAssertEqual(result.raw["content"]?.arrayValue?.count, 0,
                       "no live views for this pane must produce an empty content array, not an error " +
                       "and not a missing key")
        XCTAssertNotEqual(result.raw["isError"]?.boolValue, true,
                          "no content is not an error -- app_context on a pane with nothing to report is " +
                          "normal steady state")
    }

    func test_result_nilSurfaceID_emptyResultShape() {
        // A session-less / pane-less caller (e.g. pi) has no pane to
        // scope entries to at all.
        let provider = FakeModelContextProvider()
        let result = MCPAppContextTool.result(surfaceID: nil, provider: provider)
        XCTAssertEqual(result.raw["content"]?.arrayValue?.count, 0)
    }

    func test_result_multipleLiveViewsForSamePane_allIncluded() {
        let provider = FakeModelContextProvider()
        let callingSurface = UUID()
        provider.entriesBySurface[callingSurface] = [
            entry(toolName: "get_weather"),
            entry(toolName: "get_stock_price"),
        ]

        let result = MCPAppContextTool.result(surfaceID: callingSurface, provider: provider)
        XCTAssertEqual(result.raw["content"]?.arrayValue?.count, 2,
                       "every live view's own latest context for this pane must be included")
    }
}
