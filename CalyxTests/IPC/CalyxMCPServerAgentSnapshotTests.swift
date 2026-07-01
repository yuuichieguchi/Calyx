//
//  CalyxMCPServerAgentSnapshotTests.swift
//  CalyxTests
//
//  TDD Red Phase — tests for CalyxMCPServer.agentSnapshot(now:).
//
//  None of the following types / methods exist yet; this file will produce
//  compile errors (Red phase) until they are implemented:
//
//    • AgentActivityState  — Sendable, Equatable enum { case active, idle, stale }
//    • AgentStatusEntry    — Sendable, Identifiable, Equatable struct with fields:
//                              id: UUID, name: String, role: String,
//                              lastSeen: Date, inboxCount: Int,
//                              isSelf: Bool, state: AgentActivityState
//    • CalyxMCPServer.agentSnapshot(now: Date) async -> [AgentStatusEntry]
//    • CalyxMCPServer._testSetAppPeerID(_ id: UUID)  — test helper
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerAgentSnapshotTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        server = CalyxMCPServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    // ==================== Empty snapshot when not started ====================

    func test_agentSnapshot_returnsEmpty_whenNotStarted() async {
        // Given: server is freshly created and never started; no peers registered

        // When
        let snapshot = await server.agentSnapshot()

        // Then: snapshot must be empty — no peers, no self entry
        XCTAssertTrue(snapshot.isEmpty,
                      "agentSnapshot() should return [] when the server has not been started and no peers are registered")
    }

    // ==================== isSelf flag set for appPeerID ====================

    func test_agentSnapshot_marksAppPeerAsSelf() async {
        // Given: two peers registered in the store; appPeerID is set to peer2's id
        //        via the test helper _testSetAppPeerID(_:)
        let peer1 = await server.store.registerPeer(name: "other-agent", role: "terminal")
        let peer2 = await server.store.registerPeer(name: "app-agent", role: "app")

        // Wire the appPeerID to peer2 through the test helper
        // (implementation of _testSetAppPeerID is NOT part of this PR; its mere
        //  reference here is sufficient to keep this file in the Red phase)
        server._testSetAppPeerID(peer2.id)

        // When
        let snapshot = await server.agentSnapshot()

        // Then: peer2 has isSelf == true; peer1 has isSelf == false
        XCTAssertEqual(snapshot.count, 2,
                       "Both registered peers should appear in the snapshot")

        guard let entry1 = snapshot.first(where: { $0.id == peer1.id }),
              let entry2 = snapshot.first(where: { $0.id == peer2.id }) else {
            XCTFail("Expected entries for both peer1 and peer2")
            return
        }

        XCTAssertFalse(entry1.isSelf,
                       "peer1 is not the app peer; isSelf should be false")
        XCTAssertTrue(entry2.isSelf,
                      "peer2 matches appPeerID; isSelf should be true")
    }

    // ==================== Activity state derived from lastSeen ====================

    func test_agentSnapshot_classifiesByLastSeen() async {
        // Given: two peers; one's lastSeen is set to 40 seconds ago (idle zone)
        let recentPeer  = await server.store.registerPeer(name: "recent-agent", role: "terminal")
        let idlePeer    = await server.store.registerPeer(name: "idle-agent",   role: "terminal")

        let fortySecondsAgo = Date().addingTimeInterval(-40)
        await server.store._testSetPeerLastSeen(peerId: idlePeer.id, date: fortySecondsAgo)

        // When: snapshot taken with an explicit `now` equal to the current moment
        let now = Date()
        let snapshot = await server.agentSnapshot(now: now)

        // Then: idlePeer.state == .idle, recentPeer.state == .active
        XCTAssertEqual(snapshot.count, 2,
                       "Both peers should appear in the snapshot")

        guard let recentEntry = snapshot.first(where: { $0.id == recentPeer.id }),
              let idleEntry   = snapshot.first(where: { $0.id == idlePeer.id  }) else {
            XCTFail("Expected entries for both recentPeer and idlePeer")
            return
        }

        XCTAssertEqual(idleEntry.state, .idle,
                       "Peer whose lastSeen is 40 seconds ago should be classified as .idle")
        XCTAssertEqual(recentEntry.state, .active,
                       "Peer whose lastSeen is within 30 seconds should be classified as .active")
    }
}
