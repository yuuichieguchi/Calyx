//
//  SessionBrowserRowAttachButtonLabelTests.swift
//  CalyxTests
//
//  TDD Red phase (user-reported, same round as the attach-as-tab routing
//  fix, and completes that fix's scope): SessionBrowserView.swift's row
//  button is a literal, unconditional `Button("Attach") { model.attach(row) }`
//  (SessionBrowserView.swift ~191) -- for a row that is ALREADY attached
//  here (`row.isAttachedHere == true`), a clickable "Attach" button is
//  meaningless: the action it actually performs (via
//  `SessionAttachRoutingPolicy`'s `.focusExistingSurface` routing, this
//  same round's other fix) is revealing/focusing the already-live pane,
//  not attaching a second time.
//
//  Mirrors `SessionBrowserRowDetachedLabelTests`'/`orphanBadgeLabel`'s own
//  precedent exactly: a model-level string derived from row state, kept
//  separate from the SwiftUI view so it's testable without a snapshot/
//  view-inspection dependency (this codebase's established style, see
//  SessionBrowserModelTests' own header). The eventual view-layer change
//  (`Button(row.attachButtonLabel) { model.attach(row) }`) is the same
//  one-line swap the badge got and is NOT this file's concern.
//
//  Label text is a TEAM DECISION, not an implementer choice: exactly
//  "Show" when attached, unchanged "Attach" otherwise.
//
//  No held-out/compile-RED file needed: `SessionBrowserRow.attachButtonLabel`
//  already exists (see SessionBrowserModel.swift) as a RED-phase stub
//  that always returns "Attach" regardless of `isAttachedHere` -- i.e.
//  today's actual defect, preserved verbatim. The isAttachedHere==true
//  row below is this file's genuine RED evidence; the isAttachedHere==false
//  row is a sanity/regression companion (passes both before and after
//  the fix, same convention as AppDelegateAttachWindowTests' own
//  regression companion).
//

import XCTest
@testable import Calyx

final class SessionBrowserRowAttachButtonLabelTests: XCTestCase {

    private func makeRow(isAttachedHere: Bool) -> SessionBrowserRow {
        let info = SessionInfo(
            id: "test-session", name: nil, cwd: nil, state: .running,
            createdAtMs: 0, attachedClients: isAttachedHere ? 1 : 0, pid: 0, meta: [:]
        )
        return SessionBrowserRow(info: info, isOrphan: !isAttachedHere, isAttachedHere: isAttachedHere)
    }

    func test_attachButtonLabel_whenAttachedHere_isShow() {
        let row = makeRow(isAttachedHere: true)

        XCTAssertEqual(row.attachButtonLabel, "Show",
                       "An already-attached row's button must read a focus verb (\"Show\"), not \"Attach\" " +
                       "-- clicking it reveals the already-live pane, it never attaches a second time")
    }

    /// Sanity/regression companion: passes already (the RED-phase stub
    /// always returns "Attach"). Included so a future regression that
    /// over-broadens the label (e.g. always "Show") would be caught here.
    func test_attachButtonLabel_whenNotAttachedHere_isAttach() {
        let row = makeRow(isAttachedHere: false)

        XCTAssertEqual(row.attachButtonLabel, "Attach",
                       "A not-yet-attached (orphaned/detached) row's button must keep reading \"Attach\"")
    }
}
