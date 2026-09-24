//
//  MCPHostCoordinatorRenderDecisionTests.swift
//  CalyxTests
//
//  Coverage: the plan's §5 render decision -- the core policy of this
//  whole feature -- factored out as a pure function so it is testable
//  without any upstream connection, view host, or coordinator instance.
//  `MCPHostCoordinator.callProxiedTool` is expected to call exactly this
//  function to decide whether/how to notify the injected
//  `MCPAppViewHosting`.
//
//  Rule (plan §5, verbatim): pane resolved -> Calyx ALWAYS renders,
//  regardless of whether the caller declared the UI extension (Codex
//  CLI's shared core declares the UI extension but Codex CLI itself
//  never renders it; keying the pane-resolved decision off the
//  declaration would silently disable the feature for Codex CLI, so a
//  resolved pane always renders locally instead). Pane not resolved AND
//  the caller declared the UI extension (e.g. Codex Desktop, which
//  renders MCP Apps itself and shares the same config file as Codex
//  CLI) -> Calyx steps aside (`_meta.ui` passed through untouched,
//  nothing rendered locally, avoiding a double-render). Pane not
//  resolved and no declaration (session-less included) -> Calyx renders
//  in an independent panel.
//
//  Assumed API surface:
//    enum MCPRenderDecision: Equatable {
//        case render(surfaceID: UUID?)
//        case stepAside
//    }
//    @MainActor
//    final class MCPHostCoordinator {
//        nonisolated static func renderDecision(surfaceID: UUID?, clientDeclaredUI: Bool) -> MCPRenderDecision
//    }
//

import XCTest
@testable import Calyx

final class MCPHostCoordinatorRenderDecisionTests: XCTestCase {

    func test_paneResolved_declaredUI_stillRendersInThatPane() {
        let surfaceID = UUID()
        let decision = MCPHostCoordinator.renderDecision(surfaceID: surfaceID, clientDeclaredUI: true)
        XCTAssertEqual(decision, .render(surfaceID: surfaceID),
                       "a resolved pane always renders locally, even when the caller also declared the " +
                       "UI extension -- the pane is a terminal and cannot render itself")
    }

    func test_paneResolved_noDeclaration_rendersInThatPane() {
        let surfaceID = UUID()
        let decision = MCPHostCoordinator.renderDecision(surfaceID: surfaceID, clientDeclaredUI: false)
        XCTAssertEqual(decision, .render(surfaceID: surfaceID))
    }

    func test_noPane_declaredUI_stepsAside() {
        let decision = MCPHostCoordinator.renderDecision(surfaceID: nil, clientDeclaredUI: true)
        XCTAssertEqual(decision, .stepAside,
                       "no pane, but the caller already declared it can render the UI itself -- Calyx " +
                       "must not double-render")
    }

    func test_noPane_noDeclaration_rendersInAnIndependentPanel() {
        let decision = MCPHostCoordinator.renderDecision(surfaceID: nil, clientDeclaredUI: false)
        XCTAssertEqual(decision, .render(surfaceID: nil),
                       "no pane and no declaration (including a session-less caller like pi) -- Calyx " +
                       "renders in an independent panel rather than dropping the UI entirely")
    }
}
