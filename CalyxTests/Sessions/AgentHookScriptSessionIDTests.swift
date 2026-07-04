//
//  AgentHookScriptSessionIDTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookScript.scriptBody's calyx-session
//  awareness: a persistent-session pane's identity survives ghostty
//  surface re-creation (reconnect), while its CALYX_SURFACE_ID does
//  not — so the hook must send whichever is stable, preferring
//  CALYX_SESSION_ID over CALYX_SURFACE_ID when both are set.
//
//  Coverage:
//  - scriptBody references CALYX_SESSION_ID at all
//  - The value posted in the X-Calyx-Surface-ID header uses the
//    standard POSIX sh fallback expression `${CALYX_SESSION_ID:-
//    $CALYX_SURFACE_ID}`, so a persistent-session pane's calyx-session
//    ID is preferred whenever it is set, falling back to the existing
//    CALYX_SURFACE_ID otherwise
//  - Fix round (review, item 5): the guard must fail-open (exit 0)
//    only when BOTH CALYX_SURFACE_ID and CALYX_SESSION_ID are unset —
//    not just CALYX_SURFACE_ID as before. A real /bin/sh execution test
//    (AgentHookScriptSessionIDPipelineTests) proves this end to end
//    with only CALYX_SESSION_ID set.
//

import XCTest
@testable import Calyx

final class AgentHookScriptSessionIDTests: XCTestCase {

    func test_scriptBody_referencesCalyxSessionID() {
        XCTAssertTrue(AgentHookScript.scriptBody.contains("CALYX_SESSION_ID"),
                     "scriptBody must reference CALYX_SESSION_ID so a persistent-session pane's stable " +
                     "identity can be forwarded instead of its surface ID")
    }

    func test_scriptBody_headerValue_prefersSessionIDOverSurfaceIDViaShFallback() {
        XCTAssertTrue(
            AgentHookScript.scriptBody.contains("${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}"),
            "The value sent in the X-Calyx-Surface-ID header must be the standard POSIX sh fallback " +
            "expression `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}`, preferring CALYX_SESSION_ID (stable " +
            "across reconnect) over CALYX_SURFACE_ID (not stable across reconnect) whenever it is set"
        )
    }

    // Fix round (review, item 5): replaces the original contract's
    // "guard only checks CALYX_SURFACE_ID" test. The corrected guard
    // must fail-open only when NEITHER variable is set, so that a
    // future call site which sets CALYX_SESSION_ID without
    // CALYX_SURFACE_ID (not possible today, but the guard must not
    // silently rely on that invariant holding forever) still gets its
    // event forwarded. See AgentHookScriptSessionIDPipelineTests for
    // the real end-to-end proof via an actual /bin/sh execution.
    func test_scriptBody_guardExitsOnlyWhenBothSurfaceIDAndSessionIDAreUnset() {
        let body = AgentHookScript.scriptBody
        XCTAssertTrue(
            body.contains("[ -z \"$CALYX_SURFACE_ID\" ]") && body.contains("[ -z \"$CALYX_SESSION_ID\" ]"),
            "The guard must test both CALYX_SURFACE_ID and CALYX_SESSION_ID for emptiness, not just " +
            "CALYX_SURFACE_ID as before"
        )
        XCTAssertTrue(body.contains("exit 0"), "The fail-open exit-0 contract must be preserved")
    }
}
