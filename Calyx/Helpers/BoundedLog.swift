// BoundedLog.swift
// Calyx
//
// A count-bounded log: keeps at most `capacity` elements, oldest first,
// dropping the oldest on overflow. Shared by `AgentEditedFileLog` and
// `IPCMessageEventFeed`, which both keep a short trail of recent events.

import Foundation

struct BoundedLog<Element> {
    /// The most elements kept. Must be positive.
    let capacity: Int

    /// The kept elements, oldest first.
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedLog capacity must be positive")
        self.capacity = capacity
    }

    /// Appends `element`, dropping the oldest element once past `capacity`.
    mutating func append(_ element: Element) {
        elements.append(element)
        let overflow = elements.count - capacity
        if overflow > 0 {
            elements.removeFirst(overflow)
        }
    }

    mutating func removeAll() {
        elements.removeAll()
    }

    mutating func removeAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
        try elements.removeAll(where: shouldBeRemoved)
    }
}

extension BoundedLog: Sendable where Element: Sendable {}
extension BoundedLog: Equatable where Element: Equatable {}
