//
//  SessionRefHostRoundTripTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, contract R1: SessionRef.host already
//  exists as a plain `String?` stored property with no custom
//  Codable/CodingKeys override (see SessionRef.swift), so Swift's
//  synthesized Codable conformance already treats it as additive per
//  this codebase's v6 schema convention (architecture.md section 6: "field
//  additions must land as Optional, and migrate must let old data
//  through nil-tolerant"): a nil host is omitted on encode
//  (encodeIfPresent) and a missing "host" key decodes to nil
//  (decodeIfPresent), exactly like every other v6-additive field this
//  codebase has added before it (see SessionSnapshotV6Tests.swift's own
//  identical v5/v6 backward-compat precedent for `sessionRefs` itself).
//
//  These tests are expected to ALREADY PASS against the current,
//  unmodified codebase (a "may-pass" regression guard per this round's
//  investigation, not new-behavior RED) -- they exist to pin down that
//  the P3-laid groundwork for `host` really does round-trip end to end
//  BEFORE any P5 spawn/restore/reconnect code starts relying on it, and
//  to catch a future regression (e.g. someone adding a custom
//  init(from:)/encode(to:) to SessionRef that forgets `host`).
//
//  Coverage:
//  - A TabSnapshot whose SessionRef carries a non-nil host round-trips
//    that host unchanged through JSONEncoder/JSONDecoder.
//  - A bare SessionRef JSON payload with NO "host" key at all (the shape
//    of every real user's already-persisted v6 sessions.json today,
//    since `host` has only ever been nil so far and nil optionals are
//    omitted on encode) decodes host as nil rather than throwing.
//  - Dictionary.remappingKeys(_:) (the re-keying helper both
//    AppDelegate.restoreTabSurfaces and CalyxWindowController
//    .performReconnect use on the live Tab.sessionRefs, never on a
//    TabSnapshot mid-flight -- see SessionSnapshot.swift's own doc
//    comment) carries a SessionRef's host through a leaf-ID re-key
//    unchanged, since it moves the whole SessionRef value, not its
//    individual fields.
//

import XCTest
@testable import Calyx

final class SessionRefHostRoundTripTests: XCTestCase {

    func test_tabSnapshot_withRemoteSessionRef_hostRoundTripsThroughEncodeDecode() throws {
        let leafID = UUID()
        let sessionRefs: [UUID: SessionRef] = [
            leafID: SessionRef(sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", host: "devbox.example.com", agentSessions: nil),
        ]
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            pwd: "/home/dev/repo",
            splitTree: SplitTree(leafID: leafID),
            sessionRefs: sessionRefs
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded, original, "A TabSnapshot whose SessionRef carries a remote host must round-trip identically")
        XCTAssertEqual(decoded.sessionRefs?[leafID]?.host, "devbox.example.com",
                       "The host string itself must survive the encode/decode round trip unchanged")
    }

    func test_v6SessionRefJSON_withoutHostKey_decodesHostAsNil() throws {
        // Every real user's already-persisted v6 sessions.json today has
        // no "host" key at all inside a sessionRefs entry: host has only
        // ever been nil so far (P3 added the field but nothing wrote a
        // non-nil value into it yet), and a nil Optional is omitted by
        // the synthesized encoder, not written as an explicit "host":null.
        let json = """
        {
            "sessionID": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            "agentSessions": null
        }
        """
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(SessionRef.self, from: data)

        XCTAssertNil(decoded.host,
                     "An existing pre-P5 SessionRef payload with no host key at all must decode host as nil, " +
                     "not throw -- this is the exact upgrade path every current user's sessions.json takes")
        XCTAssertEqual(decoded.sessionID, "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    func test_sessionRefsDictionary_remappingKeys_preservesHostAcrossReKey() {
        let oldLeafID = UUID()
        let newLeafID = UUID()
        let ref = SessionRef(sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", host: "devbox.example.com")
        let original: [UUID: SessionRef] = [oldLeafID: ref]

        let remapped = original.remappingKeys([oldLeafID: newLeafID])

        XCTAssertEqual(remapped[newLeafID], ref,
                       "Re-keying by leaf ID (the same helper AppDelegate.restoreTabSurfaces and " +
                       "CalyxWindowController.performReconnect both use) must carry the whole SessionRef, " +
                       "host included, through unchanged")
        XCTAssertNil(remapped[oldLeafID], "The old key must not remain after re-keying")
    }
}
