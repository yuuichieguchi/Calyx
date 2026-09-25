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
    private var popoverOutputPath: String {
        outputDirectory.appendingPathComponent("mission-map-fixture-popover.png").path
    }

    private let viewport = CGSize(width: 1000, height: 700)
    private let cardSize = CGSize(width: 260, height: 150)
    private let spacing: CGFloat = 40
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The shared fixture (see `MissionMapFixture`), as of `now`.
    private func makeFixture() -> MissionMapFixture {
        MissionMapFixture.make(now: now)
    }

    /// Lays out, applies `offsets`, routes the way MissionMapView does
    /// (obstacles = card frames + band header obstacles), renders `.flat`
    /// and writes the PNG to `path`.
    private func render(
        _ fixture: MissionMapFixture, offsets: [UUID: CGSize], to path: String,
        selectedEdgeID: UUID? = nil, popoverOverlayEnabled: Bool = false
    ) throws {
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
            bandOrigins: bandOrigins, selectedEdgeID: selectedEdgeID,
            popoverOverlayEnabled: popoverOverlayEnabled, renderStyle: .flat
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

    /// Selects the adjacent round-trip edge (a1->a2, the fixture's first
    /// edge) and enables the popover overlay layer. This is a
    /// compile/pipeline pin, not a rendering assertion: the base fixture
    /// already exceeds 10 KB regardless of whether the popover is drawn
    /// (flat-style glass can render nearly invisibly), so this test only
    /// confirms the new `selectedEdgeID` / `popoverOverlayEnabled`
    /// parameters exist and the pipeline still produces a non-trivial
    /// PNG -- it cannot by itself distinguish "popover drawn" from "not
    /// drawn".
    func test_renderFixture_selectedEdgePopover_writesANonTrivialPNG() throws {
        let fixture = makeFixture()
        let edgeID = fixture.snapshot.edges[0].id

        try render(
            fixture, offsets: [:], to: popoverOutputPath,
            selectedEdgeID: edgeID, popoverOverlayEnabled: true
        )
    }
}
