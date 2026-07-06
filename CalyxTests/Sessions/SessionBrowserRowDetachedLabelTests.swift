//
//  SessionBrowserRowDetachedLabelTests.swift
//  CalyxTests
//
//  TDD Red phase (session browser badge wording): the session browser's
//  "Orphaned" badge (SessionBrowserRowView, SessionBrowserView.swift) is
//  internal jargon. The state it represents (a running session with no
//  live ghostty surface attached in this process -- no SessionSurfaceMap
//  entry, SessionBrowserRow.isOrphan) is, from the user's perspective,
//  simply "alive but not attached to any tab; Attach reveals it".
//  Renaming the user-visible label to "Detached" names that state
//  without requiring the user to know this codebase's internal
//  vocabulary.
//
//  Scope: user-visible STRING ONLY. `SessionBrowserRow.isOrphan` and
//  every other internal name keep their current spelling this cycle (a
//  follow-up can rename the internal API separately); this file pins
//  only the wording the user actually reads.
//
//  Held-out compile-RED (mirrors SessionPersistenceActorTerminationSaveTests'
//  convention for this codebase): `SessionBrowserRow.orphanBadgeLabel`
//  does not exist yet. This file fails to compile until the Green phase
//  adds it and switches SessionBrowserRowView's inline `Text("Orphaned")`
//  literal (SessionBrowserView.swift) to read this constant instead.
//  That compile failure IS this file's RED evidence: there is no
//  existing test pinning the badge's literal text today (the string
//  lives only in SwiftUI view code -- this codebase's test style is
//  direct-query against logic layers, not SwiftUI snapshot/view
//  inspection, see SessionBrowserModelTests' own header), so a
//  model-level string constant is the smallest seam that makes the
//  wording testable at all.
//
//  Proposed API (SessionBrowserModel.swift addition, on SessionBrowserRow):
//
//    /// User-visible label for the isOrphan badge (SessionBrowserRowView).
//    /// Kept separate from the SwiftUI view so this string is testable
//    /// without a snapshot/view-inspection dependency. Internal name
//    /// (isOrphan) is unchanged this cycle -- only the user-visible
//    /// wording moves from "Orphaned" to "Detached".
//    static let orphanBadgeLabel = "Detached"
//
//  SessionBrowserRowView call-site switch (SessionBrowserView.swift, the
//  `if row.isOrphan { Text("Orphaned") ... }` branch): replace the
//  `"Orphaned"` literal with `SessionBrowserRow.orphanBadgeLabel`.
//

import XCTest
@testable import Calyx

final class SessionBrowserRowDetachedLabelTests: XCTestCase {

    func test_orphanBadgeLabel_isDetached_notOrphaned() {
        XCTAssertEqual(SessionBrowserRow.orphanBadgeLabel, "Detached",
                       "The session browser's isOrphan badge must read the user-facing 'Detached' " +
                       "(alive but not attached to any tab; Attach reveals it), not the internal jargon " +
                       "'Orphaned'")
    }
}
