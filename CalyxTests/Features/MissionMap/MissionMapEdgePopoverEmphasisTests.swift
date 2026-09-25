//
//  MissionMapEdgePopoverEmphasisTests.swift
//  CalyxTests
//
//  Pins MissionMapEdgePopover's new `emphasized: Bool` parameter (it
//  switches the glass to a tinted `.regular.tint(...)` glass when the
//  popover's placement score is > 0, so a bubble forced to overlap a
//  card is still legible). A compile-level pin only: constructing the
//  view with `emphasized: true` must type-check.
//

import SwiftUI
import XCTest
@testable import Calyx

@MainActor
final class MissionMapEdgePopoverEmphasisTests: XCTestCase {

    func test_edgePopover_compilesWithEmphasizedTrue() {
        let edge = MissionMapEdge(
            id: UUID(), from: UUID(), to: UUID(),
            kind: .conflict(file: "main.swift", fullPath: "/projects/app/main.swift")
        )

        _ = MissionMapEdgePopover(edge: edge, emphasized: true)
    }
}
