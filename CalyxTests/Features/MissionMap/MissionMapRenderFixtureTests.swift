//
//  MissionMapRenderFixtureTests.swift
//  CalyxTests
//
//  A single end-to-end visual regression fixture: builds a fabricated
//  MissionMapSnapshot (2 bands, 2 rows, an adjacent round trip, a
//  cross-row edge, a cross-band edge, a conflict edge), lays it out with
//  MissionMapLayout, routes it with MissionMapRouter around the card
//  frames and band header obstacles exactly as MissionMapView does,
//  renders the pure MissionMapContentView in its `.flat` style with
//  ImageRenderer, and writes the PNG to CALYX_FIXTURE_OUTPUT_DIR (or a
//  temporary directory) for manual inspection. A second PNG repeats this with two cards dragged. Not a
//  pixel-diff test (Mission Map has no golden image yet) -- it only pins
//  that the whole pipeline produces a non-trivial image.
//

import AppKit
import SwiftUI
import XCTest
@testable import Calyx

@MainActor
final class MissionMapRenderFixtureTests: XCTestCase {

    /// `CALYX_FIXTURE_OUTPUT_DIR` when set, else a fixed directory
    /// under the temporary directory.
    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CALYX_FIXTURE_OUTPUT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("calyx-mission-map-fixtures")
    }
    private var outputPath: String { outputDirectory.appendingPathComponent("mission-map-fixture.png").path }
    private var draggedOutputPath: String {
        outputDirectory.appendingPathComponent("mission-map-fixture-dragged.png").path
    }

    private let viewport = CGSize(width: 1000, height: 700)
    private let cardSize = CGSize(width: 260, height: 150)
    private let spacing: CGFloat = 40
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func card(
        groupID: UUID, groupName: String, title: String, state: AgentState = .working,
        toolLine: String? = nil, children: [MissionMapChildCard] = []
    ) -> MissionMapCard {
        let id = UUID()
        return MissionMapCard(
            id: id, groupID: groupID, groupName: groupName, tabID: UUID(), kindLabel: "Claude Code",
            paneTitle: title, cwdLabel: "~/projects/app", state: state, toolLine: toolLine,
            children: children, unreadCount: 0, approval: nil, git: nil, focusTarget: id
        )
    }

    private struct Fixture {
        let snapshot: MissionMapSnapshot
        let cards: [String: MissionMapCard]
    }

    /// Band A: 4 cards (3 per row at width 1000, so a4 wraps to row 2;
    /// a2 has two subagents and is taller). Band B: 2 cards. Edges: an
    /// adjacent round trip a1<->a2 (a1->a2 carrying three messages sent
    /// 0.4 s apart, so its one line shows three pulse dots), a cross-row
    /// a2->a4, a cross-band a4->b1, and a conflict a1-a3.
    private func makeFixture() -> Fixture {
        let groupA = UUID()
        let groupB = UUID()
        let groups = [
            MissionMapGroup(id: groupA, name: "Band A"),
            MissionMapGroup(id: groupB, name: "Band B"),
        ]
        let a1 = card(groupID: groupA, groupName: "Band A", title: "API server", toolLine: "Edit: main.swift")
        let a2 = card(
            groupID: groupA, groupName: "Band A", title: "Refactor router",
            children: [
                MissionMapChildCard(id: "child-1", agentType: "Explore", state: .working, toolLine: "Grep: route"),
                MissionMapChildCard(id: "child-2", agentType: "Plan", state: .idle, toolLine: nil),
            ]
        )
        let a3 = card(groupID: groupA, groupName: "Band A", title: "Docs", state: .idle, toolLine: "Edit: main.swift")
        let a4 = card(groupID: groupA, groupName: "Band A", title: "Test runner", toolLine: "Bash: swift test")
        let b1 = card(groupID: groupB, groupName: "Band B", title: "Release notes", state: .idle)
        let b2 = card(groupID: groupB, groupName: "Band B", title: "Shell", state: .idle)
        let cards = [a1, a2, a3, a4, b1, b2]

        func message(_ content: String, secondsAgo: TimeInterval = 0) -> IPCMessageEvent {
            IPCMessageEvent(
                id: UUID(), from: UUID(), to: UUID(), content: content,
                sentAt: now.addingTimeInterval(-secondsAgo), isBroadcast: false
            )
        }
        let pings = [message("ping 3"), message("ping 2", secondsAgo: 0.4), message("ping 1", secondsAgo: 0.8)]
        let edges = [
            MissionMapEdge(id: UUID(), from: a1.id, to: a2.id, kind: .ipc(messages: pings)),
            MissionMapEdge(id: UUID(), from: a2.id, to: a1.id, kind: .ipc(messages: [message("pong")])),
            MissionMapEdge(id: UUID(), from: a2.id, to: a4.id, kind: .ipc(messages: [message("cross-row")])),
            MissionMapEdge(id: UUID(), from: a4.id, to: b1.id, kind: .ipc(messages: [message("cross-band")])),
            MissionMapEdge(id: UUID(), from: a1.id, to: a3.id, kind: .conflict(file: "main.swift", fullPath: "/projects/app/main.swift")),
        ]
        return Fixture(
            snapshot: MissionMapSnapshot(cards: cards, edges: edges, groups: groups),
            cards: ["a1": a1, "a2": a2, "a3": a3, "a4": a4, "b1": b1, "b2": b2]
        )
    }

    /// Lays out, applies `offsets`, routes the way MissionMapView does
    /// (obstacles = card frames + band header obstacles), renders `.flat`
    /// and writes the PNG to `path`.
    private func render(_ fixture: Fixture, offsets: [UUID: CGSize], to path: String) throws {
        let snapshot = fixture.snapshot
        let laidOut = MissionMapLayout.layout(
            cards: snapshot.cards, groups: snapshot.groups, in: viewport, cardSize: cardSize, spacing: spacing
        )
        XCTAssertEqual(laidOut.count, snapshot.cards.count)
        let frames = laidOut.reduce(into: [UUID: CGRect]()) { result, entry in
            let offset = offsets[entry.key] ?? .zero
            result[entry.key] = entry.value.offsetBy(dx: offset.width, dy: offset.height)
        }
        let bandOrigins = MissionMapLayout.bandOrigins(
            cards: snapshot.cards, groups: snapshot.groups, in: viewport, cardSize: cardSize, spacing: spacing
        )
        let obstacles = snapshot.cards.compactMap { frames[$0.id] }
            + MissionMapLayout.bandHeaderObstacles(bandOrigins: bandOrigins)
        let requests = snapshot.edges.map { MissionMapRouteRequest(id: $0.id, from: frames[$0.from]!, to: frames[$0.to]!) }
        let bounds = CGRect(origin: .zero, size: viewport)
        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)
        XCTAssertEqual(routes.count, snapshot.edges.count)

        let contentView = MissionMapContentView(
            snapshot: snapshot, frames: frames, routes: routes, now: now,
            bandOrigins: bandOrigins, renderStyle: .flat
        )
        .frame(width: viewport.width, height: viewport.height)

        let renderer = ImageRenderer(content: contentView)
        renderer.proposedSize = ProposedViewSize(width: viewport.width, height: viewport.height)

        guard let cgImage = renderer.cgImage else {
            return XCTFail("ImageRenderer produced no image")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = NSSize(width: viewport.width, height: viewport.height)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Failed to encode PNG")
        }

        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL)
        print("[fixture] wrote \(outputURL.path)")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertGreaterThan(fileSize, 10 * 1024, "Rendered fixture PNG should be larger than 10 KB")
    }

    func test_renderFixture_writesANonTrivialPNG() throws {
        try render(makeFixture(), offsets: [:], to: outputPath)
    }

    /// a4 dragged up and right, under the gap between a2 and a3 and
    /// partially over a2's bottom edge; b2 dragged 30pt down.
    func test_renderFixture_draggedCards_writesANonTrivialPNG() throws {
        let fixture = makeFixture()
        let offsets: [UUID: CGSize] = [
            fixture.cards["a4"]!.id: CGSize(width: 480, height: -60),
            fixture.cards["b2"]!.id: CGSize(width: 0, height: 30),
        ]
        try render(fixture, offsets: offsets, to: draggedOutputPath)
    }
}
