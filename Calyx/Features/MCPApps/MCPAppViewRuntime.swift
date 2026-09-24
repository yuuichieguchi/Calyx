//
//  MCPAppViewRuntime.swift
//  Calyx
//
//  The seam between MCPAppHostStore and the WebKit layer. The store
//  reaches a view's web view only through this protocol.
//

import Foundation

@MainActor
protocol MCPAppViewTeardownRequesting: AnyObject {
    /// Sends `ui/resource-teardown` and waits up to 2 seconds for the reply.
    func requestTeardown(viewID: UUID) async
}

@MainActor
protocol MCPAppViewRuntime: MCPAppViewTeardownRequesting {
    /// Builds the view's web view and bridge from a validated document and
    /// starts loading it. Load completion, `initialized` and process
    /// termination come back to the store as `viewDidLoadDocument`,
    /// `viewDidInitialize` and `viewProcessDidTerminate`.
    func mount(viewID: UUID, document: MCPAppViewDocument) async throws
    /// Sends a host-originated JSON-RPC message to the view. Returns the
    /// view's response for a request, nil for a notification.
    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage?
    /// Releases the web view, handler, user scripts and rule list. Waiting
    /// for the teardown reply is `requestTeardown`'s job.
    func unmount(viewID: UUID)
}

/// The validated input of `mount`: the resource's HTML and the policies
/// built for it.
struct MCPAppViewDocument: Sendable, Equatable {
    let html: String
    /// `calyx-mcp-app://<host>`
    let viewOrigin: String
    /// `calyx-mcp-host://<random>`
    let hostOrigin: String
    let cspPolicy: String
    let contentRuleListJSON: String
    let contentRuleListIdentifier: String
}
