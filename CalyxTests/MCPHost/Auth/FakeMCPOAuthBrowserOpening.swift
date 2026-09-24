//
//  FakeMCPOAuthBrowserOpening.swift
//  CalyxTests
//
//  `MCPOAuthBrowserOpening` double (API contract section 14) that
//  records every opened URL and lets a test `await` the next one
//  without sleeping, via a checked continuation.
//

import Foundation
@testable import Calyx

actor FakeMCPOAuthBrowserOpening: MCPOAuthBrowserOpening {
    private var openedURLs: [URL] = []
    private var pendingContinuations: [CheckedContinuation<URL, Never>] = []

    func open(_ url: URL) async {
        if let continuation = pendingContinuations.isEmpty ? nil : pendingContinuations.removeFirst() {
            continuation.resume(returning: url)
        } else {
            openedURLs.append(url)
        }
    }

    /// Suspends until `open(_:)` has been called at least once since the
    /// last call to this method, then returns that URL.
    func nextOpenedURL() async -> URL {
        if !openedURLs.isEmpty {
            return openedURLs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    func openedURLCount() -> Int {
        openedURLs.count
    }
}
