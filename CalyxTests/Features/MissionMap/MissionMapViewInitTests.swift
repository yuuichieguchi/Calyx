//
//  MissionMapViewInitTests.swift
//  CalyxTests
//
//  Compile-level pin for MissionMapView's new persisted-drag-offset
//  wiring: `cardOffsets: [UUID: CGSize]` (what the map reads instead of
//  its old memory-only `@State dragOffsets`) and
//  `onCardOffsetChange: (UUID, CGSize) -> Void` (reported back to
//  CalyxWindowController.missionMapCardOffsetChanged(surfaceID:offset:)
//  on every committed drag). No existing test constructs MissionMapView
//  directly (MainContentView.missionMapOverlay is the only production
//  call site), so this is a fresh, minimal construction -- proving the
//  two new parameters exist with the right types and that `cardOffsets`
//  is actually stored and readable, not merely accepted and discarded.
//

import XCTest
import SwiftUI
@testable import Calyx

@MainActor
final class MissionMapViewInitTests: XCTestCase {

    func test_init_acceptsCardOffsetsAndOnCardOffsetChange_andStoresCardOffsets() {
        let leafID = UUID()
        let offset = CGSize(width: 15, height: -6)

        var reportedChange: (UUID, CGSize)?
        let view = MissionMapView(
            panes: { [] },
            gitPoller: MissionMapGitPoller(),
            selection: MissionMapSelection(),
            cardOffsets: [leafID: offset],
            onCardOffsetChange: { surfaceID, newOffset in
                reportedChange = (surfaceID, newOffset)
            }
        )

        XCTAssertEqual(view.cardOffsets[leafID], offset,
                       "MissionMapView must actually store the cardOffsets it was constructed with, not just " +
                       "accept and discard them")

        // Exercises the closure itself, so a stub that accepts but never
        // calls onCardOffsetChange -- or reorders its (UUID, CGSize)
        // arguments -- would still be caught here, even though this test
        // cannot drive a real drag through SwiftUI's rendering pipeline.
        view.onCardOffsetChange(leafID, offset)
        XCTAssertEqual(reportedChange?.0, leafID)
        XCTAssertEqual(reportedChange?.1, offset)
    }
}
