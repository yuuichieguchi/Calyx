//
//  StdioLSPTransportWriteDeadlineBugSpecTests.swift
//  CalyxTests
//
//  Regression test covering the hardcoded write-deadline bug in
//  `StdioLSPTransport.writeNonBlocking(_:fd:)`. The transport
//  currently uses
//
//      private static let writeDeadlineSeconds: TimeInterval = 3.0
//
//  for ANY write loop draining a single LSP request to the child's
//  stdin. This is fine for small JSON-RPC frames (initialize,
//  hover, didOpen on a small file), but it underestimates two common
//  cases:
//
//    1. A `textDocument/didChange` carrying a multi-megabyte
//       full-content replacement (`TextDocumentContentChangeEvent`
//       with no `range`) — these can be 1-10 MiB for generated files,
//       binary-ish assets routed through the editor, or large
//       refactor previews.
//    2. The child language server is still warming up (rust-analyzer
//       indexing, sourcekit-lsp populating its module map) and
//       drains stdin slowly. A macOS pipe buffer is ~64 KiB, so a
//       1 MiB payload requires ~16 drain cycles; with a server that
//       only services its read loop every ~200 ms during cold start,
//       3 seconds is easily exceeded.
//
//  When the deadline elapses the current code throws
//  `LSPClientError.transportClosed`, the higher layers
//  (`LSPSession` / `LSPService`) interpret that as a dead child and
//  tear the session down — even though the child was perfectly
//  healthy, just slow to drain a big buffer. The user sees the LSP
//  go offline mid-edit.
//
//  FIX SPEC: scale the deadline with `data.count`. Suggested formula
//
//      max(3.0, ceil(Double(data.count) / 32_768.0) * 0.5)
//
//  That preserves the existing 3-second floor for small writes
//  (anything <= 192 KiB still gets 3 s) and grants ~0.5 s per
//  32 KiB chunk for larger payloads — ~16 s for 1 MiB, ~160 s for
//  10 MiB.
//
//  TDD GATE: this test MUST FAIL against the current source. The
//  helper `computeWriteDeadline(payloadSize:)` is intentionally not
//  yet exposed — referencing it from the test produces a compile
//  error, which is the unambiguous RED signal. After the GREEN fix
//  surfaces it as
//
//      internal static func computeWriteDeadline(payloadSize: Int) -> TimeInterval
//
//  and threads the result into `writeNonBlocking`, this test will
//  link and pass.
//
//  Why approach (a) over (b)?
//    (a) exercises the deadline-policy decision DIRECTLY as pure
//        arithmetic — deterministic, fast (<1 ms), no child process,
//        no pipe-buffer timing assumptions.
//    (b) — spawning a non-reading child (`/bin/sh -c 'sleep 30'`) so
//        writes block on a full pipe — would be exposed to CI scheduler
//        jitter (the 3 s vs 16 s boundary becomes flaky on a loaded
//        runner) and would only assert "we waited longer" rather than
//        "the policy is correctly parameterized by payload size". The
//        fix spec explicitly prefers (a) when feasible.
//

import XCTest
@testable import Calyx

@MainActor
final class StdioLSPTransportWriteDeadlineBugSpecTests: XCTestCase {

    // MARK: - Bug: writeDeadline is hardcoded at 3 s regardless of payload size

    /// Given: a small payload (1 KiB) — a typical LSP request frame.
    /// When:  the transport computes the write-loop deadline.
    /// Then:  the deadline is at least the legacy 3-second floor and
    ///        not unreasonably inflated (small frames must not be
    ///        granted minute-long timeouts that would mask a wedged
    ///        child during normal operation).
    ///
    /// Given: a 1 MiB payload — a realistic full-content
    ///        `textDocument/didChange` after a paste of a generated
    ///        file.
    /// When:  the transport computes the deadline.
    /// Then:  the deadline scales up far above 3 seconds so a
    ///        warming-up server has time to drain ~16 pipe-buffer
    ///        cycles without the transport throwing
    ///        `transportClosed`.
    ///
    /// Current code FAILS to compile against this test because
    /// `StdioLSPTransport.computeWriteDeadline(payloadSize:)` does
    /// not exist — the policy is baked into a private static `let`
    /// (`writeDeadlineSeconds: TimeInterval = 3.0`) with no size
    /// parameter. That compile failure IS the RED phase.
    func test_writeDeadline_scalesWithPayloadSize() {
        // --- Small payload: roughly the legacy 3 s floor ---------
        //
        // Per the suggested formula
        //   max(3.0, ceil(1024 / 32_768) * 0.5)
        //     = max(3.0, ceil(0.03125) * 0.5)
        //     = max(3.0, 1 * 0.5) = max(3.0, 0.5) = 3.0
        // so we expect exactly the floor. Allow a small slack window
        // so an equally-valid policy tweak (e.g. floor of 2.5 or
        // 3.5) doesn't trip the test for a non-bug refactor.
        let smallDeadline = StdioLSPTransport.computeWriteDeadline(payloadSize: 1024)
        XCTAssertGreaterThanOrEqual(
            smallDeadline,
            2.5,
            """
            For a small (1 KiB) payload the deadline must remain at \
            or above ~3 s so well-behaved small writes still have \
            the legacy budget. Got \(smallDeadline) s.
            """
        )
        XCTAssertLessThanOrEqual(
            smallDeadline,
            5.0,
            """
            For a small (1 KiB) payload the deadline must NOT be \
            inflated to many seconds — that would let a genuinely \
            wedged child pin the actor's awaiters. The policy \
            should only scale UP for large payloads. Got \
            \(smallDeadline) s.
            """
        )

        // --- 1 MiB payload: must be substantially larger ---------
        //
        // Per the suggested formula
        //   max(3.0, ceil(1_048_576 / 32_768) * 0.5)
        //     = max(3.0, ceil(32) * 0.5)
        //     = max(3.0, 32 * 0.5) = max(3.0, 16.0) = 16.0
        // so we expect ~16 s. We assert >= 10 s to leave headroom
        // for an equally-valid tuning (e.g. 0.4 s per 32 KiB), but
        // a flat 3 s — i.e. the current bug — must fail this
        // assertion outright.
        let oneMiB = 1024 * 1024
        let largeDeadline = StdioLSPTransport.computeWriteDeadline(payloadSize: oneMiB)
        XCTAssertGreaterThanOrEqual(
            largeDeadline,
            10.0,
            """
            For a 1 MiB payload the deadline must scale far above \
            the 3-second floor so a warming-up language server \
            (rust-analyzer / sourcekit-lsp) has time to drain ~16 \
            pipe-buffer cycles (~64 KiB each on macOS) without the \
            transport throwing LSPClientError.transportClosed and \
            tearing the LSP session down mid-edit. Got \
            \(largeDeadline) s — almost certainly the hardcoded \
            3 s floor, which is the bug under test.
            """
        )

        // --- Monotonicity guard ---------------------------------
        //
        // A larger payload must never get a SHORTER budget than a
        // smaller one. This pins the policy direction even if the
        // exact formula evolves.
        XCTAssertGreaterThanOrEqual(
            largeDeadline,
            smallDeadline,
            """
            Write deadline must be monotonically non-decreasing in \
            payload size. 1 KiB -> \(smallDeadline) s, 1 MiB -> \
            \(largeDeadline) s.
            """
        )
    }
}
