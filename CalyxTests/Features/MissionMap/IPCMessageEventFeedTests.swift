//
//  IPCMessageEventFeedTests.swift
//  CalyxTests
//
//  Pins IPCMessageEventFeed (@MainActor @Observable), the ring buffer of
//  the most recent Mission Map IPC pulses: capacity 512, FIFO eviction of
//  the OLDEST record once full, insertion order preserved, and reset()
//  clearing everything.
//

import XCTest
@testable import Calyx

@MainActor
final class IPCMessageEventFeedTests: XCTestCase {

    private func makeEvent(content: String, sentAt: Date, isBroadcast: Bool = false) -> IPCMessageEvent {
        IPCMessageEvent(
            id: UUID(), from: UUID(), to: UUID(), content: content, sentAt: sentAt,
            isBroadcast: isBroadcast
        )
    }

    override func tearDown() {
        IPCMessageEventFeed.shared.reset()
        super.tearDown()
    }

    func test_record_appendsInOrder() {
        let feed = IPCMessageEventFeed.shared
        feed.reset()
        let first = makeEvent(content: "first", sentAt: Date())
        let second = makeEvent(content: "second", sentAt: Date().addingTimeInterval(1))

        feed.record(first)
        feed.record(second)

        XCTAssertEqual(feed.events.map(\.content), ["first", "second"])
    }

    /// Recording past `capacity` must drop the OLDEST record, not
    /// the newest, and must never exceed `capacity` entries.
    func test_record_beyondCapacity_dropsOldestFirst() {
        let feed = IPCMessageEventFeed.shared
        feed.reset()
        let base = Date()

        for index in 0..<(IPCMessageEventFeed.capacity + 5) {
            feed.record(makeEvent(content: "msg-\(index)", sentAt: base.addingTimeInterval(Double(index))))
        }

        XCTAssertEqual(feed.events.count, IPCMessageEventFeed.capacity)
        XCTAssertEqual(feed.events.first?.content, "msg-5",
                       "The 5 oldest records (msg-0...msg-4) must have been evicted")
        XCTAssertEqual(feed.events.last?.content, "msg-\(IPCMessageEventFeed.capacity + 4)")
    }

    func test_capacity_is512() {
        XCTAssertEqual(IPCMessageEventFeed.capacity, 512)
    }

    func test_reset_clearsAllEvents() {
        let feed = IPCMessageEventFeed.shared
        feed.reset()
        feed.record(makeEvent(content: "one", sentAt: Date()))
        XCTAssertFalse(feed.events.isEmpty, "Precondition: at least one event recorded")

        feed.reset()

        XCTAssertTrue(feed.events.isEmpty)
    }
}
