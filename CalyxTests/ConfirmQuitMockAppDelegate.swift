//
//  ConfirmQuitMockAppDelegate.swift
//  CalyxTests
//
//  R6-J (r6-fix-spec.md, round-5 review finding G2): shared base for
//  the four near-identical `AppDelegate` test doubles in
//  `SessionCommandPaletteTests` (MockConfirmQuitAppDelegate,
//  ClosingTabIDsSpyAppDelegate) and `CalyxWindowControllerCloseArmsTests`
//  (ConfirmingAppDelegate, ClosingTabIDsWindowCloseSpyAppDelegate), all
//  of which drive a close path under test through to its
//  `.windowShouldClose` arm without a real, blocking `NSAlert.runModal()`.
//  No production change: purely test-infrastructure consolidation.
//

import AppKit
@testable import Calyx

@MainActor
class ConfirmQuitMockAppDelegate: AppDelegate {
    /// Reports `true` unconditionally, driving every close path under
    /// test through to its terminal arm regardless of this test
    /// process's real `windowControllers` (which the fixture's
    /// contrived controller was never added to).
    override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool {
        true
    }

    /// A no-op purely as test-process safety: a confirmed teardown
    /// empties the fixture's window for real, calling `window?.close()`
    /// -> `windowWillClose` -> `AppDelegate.removeWindowController`,
    /// whose real implementation calls `NSApp.terminate(nil)` once its
    /// (private) `windowControllers` list is empty.
    override func removeWindowController(_ controller: CalyxWindowController) {}
}
