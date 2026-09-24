//
//  MCPAppMessageDeliveryRoute.swift
//  Calyx
//
//  Where a consented `ui/message` goes.
//

import Foundation

enum MCPAppMessageDeliveryRoute: Sendable, Equatable {
    case cockpit(surfaceID: UUID)
    case herdr(HerdrPaneRef)
    /// No pane to deliver to: the user can only copy the text.
    case copyOnly

    /// A herdr pane wins: a herdr TUI-attach tab may have no surface ID.
    static func choose(surfaceID: UUID?, herdrRef: HerdrPaneRef?) -> MCPAppMessageDeliveryRoute {
        if let herdrRef { return .herdr(herdrRef) }
        if let surfaceID { return .cockpit(surfaceID: surfaceID) }
        return .copyOnly
    }
}
