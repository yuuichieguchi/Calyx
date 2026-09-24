//
//  FakeConnectionLookup.swift
//  CalyxTests
//
//  `MCPConnectionLookup` test double (API contract section 10.2 /
//  section 14). Wraps a fixed table of `MCPUpstreamConnecting` doubles
//  keyed by `MCPServerID`; a server id with no entry (e.g. a removed
//  server) resolves to nil, exactly like a real `MCPUpstreamSupervisor`
//  after the server is removed from the registry.
//

import Foundation
@testable import Calyx

struct FakeConnectionLookup: MCPConnectionLookup {
    private let connections: [MCPServerID: any MCPUpstreamConnecting]

    init(_ connections: [MCPServerID: any MCPUpstreamConnecting] = [:]) {
        self.connections = connections
    }

    func connection(forServerID serverID: MCPServerID) async -> (any MCPUpstreamConnecting)? {
        connections[serverID]
    }
}
