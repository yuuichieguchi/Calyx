//
//  CalyxShellIntegrationEnvironmentTests.swift
//  CalyxTests
//
//  TDD Red phase (P4, command-log shell integration env injection).
//  Mirrors GhosttyResourcesDirEnvironmentTests' real-process-environment
//  save/restore convention (this codebase's established precedent for
//  this exact kind of direct setenv/getenv mutation -- see
//  CalyxShellIntegrationEnvironment.swift's own header for why this
//  follows that shape rather than an injected seam).
//
//  CalyxShellIntegrationEnvironment.apply/remove are no-op stubs this
//  phase: every positive assertion below (a variable WAS set/changed) is
//  therefore expected, and required, to fail. The two "must not clobber"
//  tests each open with a sanity precondition proving the *normal*
//  restore path works, so they too fail for the right reason rather than
//  passing vacuously against a no-op.
//

import XCTest
@testable import Calyx

final class CalyxShellIntegrationEnvironmentTests: XCTestCase {

    private let zdotdirVariableName = "ZDOTDIR"
    private let originalZdotdirVariableName = "CALYX_ZSH_ZDOTDIR"
    private let xdgDataDirsVariableName = "XDG_DATA_DIRS"

    private var originalValues: [String: String?] = [:]
    private var root: URL!

    override func setUp() {
        super.setUp()
        for name in [zdotdirVariableName, originalZdotdirVariableName, xdgDataDirsVariableName] {
            originalValues[name] = ProcessInfo.processInfo.environment[name]
        }
        root = URL(fileURLWithPath: "/opt/calyx-fixture/shell-integration")
    }

    override func tearDown() {
        for (name, value) in originalValues {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        originalValues = [:]
        root = nil
        super.tearDown()
    }

    private func currentValue(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    private var expectedZdotdir: String { root.appendingPathComponent("zsh").path }

    // MARK: - apply(rootDirectory:) — ZDOTDIR

    func test_apply_setsZdotdirToRootZshSubdirectory() {
        unsetenv(zdotdirVariableName)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertEqual(currentValue(zdotdirVariableName), expectedZdotdir,
                       "apply must point ZDOTDIR at <rootDirectory>/zsh")
    }

    func test_apply_withExistingZdotdir_savesOriginalIntoCalyxZshZdotdir() {
        setenv(zdotdirVariableName, "/Users/alice/.config/zsh", 1)
        unsetenv(originalZdotdirVariableName)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertEqual(currentValue(originalZdotdirVariableName), "/Users/alice/.config/zsh",
                       "an existing ZDOTDIR must be preserved into CALYX_ZSH_ZDOTDIR before being overwritten")
        XCTAssertEqual(currentValue(zdotdirVariableName), expectedZdotdir)
    }

    func test_apply_withNoExistingZdotdir_leavesCalyxZshZdotdirUnset() {
        unsetenv(zdotdirVariableName)
        unsetenv(originalZdotdirVariableName)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertNil(
            currentValue(originalZdotdirVariableName),
            "with no original ZDOTDIR, CALYX_ZSH_ZDOTDIR must be ABSENT (not present-and-empty) -- " +
            "the installed .zshenv distinguishes unset (fall back to $HOME) from set-to-empty via " +
            "${CALYX_ZSH_ZDOTDIR+X}, matching ghostty's own GHOSTTY_ZSH_ZDOTDIR chain"
        )
    }

    func test_apply_withZdotdirGenuinelyChangedExternally_overwritesTheStaleCalyxZshZdotdir() {
        // ZDOTDIR now holds a genuinely DIFFERENT external value (not
        // our own installed dir) -- e.g. some other tool re-pointed it
        // between two apply() calls. re-deriving CALYX_ZSH_ZDOTDIR from
        // that current (non-ours) value is correct: it's a real change
        // to preserve, not our own prior effect to avoid re-capturing.
        setenv(zdotdirVariableName, "/Users/alice/.config/zsh-v2", 1)
        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh-stale", 1)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertEqual(currentValue(originalZdotdirVariableName), "/Users/alice/.config/zsh-v2")
    }

    func test_apply_reapplyWhileZdotdirAlreadyOurs_doesNotClobberTheSavedOriginal() {
        // Review finding: a re-`apply()` call (e.g. a second surface
        // launching, or a Settings toggle flip) while ZDOTDIR ALREADY
        // points at our own installed zsh dir (the previous apply()'s
        // own effect) must NOT re-capture that as "the original" --
        // doing so would clobber the correctly-saved true original with
        // our own path, permanently losing it.
        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh", 1)
        setenv(zdotdirVariableName, expectedZdotdir, 1)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertEqual(
            currentValue(originalZdotdirVariableName), "/Users/alice/.config/zsh",
            "apply() must not clobber the saved original when ZDOTDIR already points at our own dir"
        )
        XCTAssertEqual(currentValue(zdotdirVariableName), expectedZdotdir)
    }

    // MARK: - apply(rootDirectory:) — XDG_DATA_DIRS

    func test_apply_withXdgDataDirsUnset_initializesWithRootAndFishDefaults() {
        unsetenv(xdgDataDirsVariableName)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        XCTAssertEqual(currentValue(xdgDataDirsVariableName), "\(root.path):/usr/local/share:/usr/share",
                       "an unset XDG_DATA_DIRS must be initialized to root + fish's own documented defaults")
    }

    func test_apply_withXdgDataDirsSet_appendsRootRatherThanReplacing() {
        setenv(xdgDataDirsVariableName, "/opt/homebrew/share:/usr/local/share", 1)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        let value = currentValue(xdgDataDirsVariableName)
        XCTAssertEqual(
            value, "/opt/homebrew/share:/usr/local/share:\(root.path)",
            "an existing XDG_DATA_DIRS must be preserved with root appended, not overwritten -- ghostty's own " +
            "fish setup does the same append (not replace) so the two coexist"
        )
    }

    func test_apply_reapplyWithoutRemove_doesNotDuplicateRootInXdgDataDirs() {
        // Review finding: a re-`apply()` call (e.g. a second surface
        // launching, or a Settings toggle flip) without an intervening
        // `remove()` must not append root a second time -- ZDOTDIR
        // already got this same re-apply idempotency; XDG_DATA_DIRS is
        // bounded (harmless duplicate PATH-like entry) but should match.
        unsetenv(xdgDataDirsVariableName)

        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)
        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)

        let entries = currentValue(xdgDataDirsVariableName)?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        XCTAssertEqual(
            entries.filter { $0 == root.path }.count, 1,
            "root must occur exactly once in XDG_DATA_DIRS after two apply() calls, found in: \(entries)"
        )
    }

    // MARK: - remove(rootDirectory:) — ZDOTDIR restore

    func test_remove_restoresOriginalZdotdirWhenCurrentValueStillPointsAtOurDir() {
        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh", 1)
        setenv(zdotdirVariableName, expectedZdotdir, 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertEqual(currentValue(zdotdirVariableName), "/Users/alice/.config/zsh",
                       "remove() must restore ZDOTDIR to the saved original when the current value is still ours")
    }

    func test_remove_withNoSavedOriginal_unsetsZdotdirWhenCurrentValueStillPointsAtOurDir() {
        unsetenv(originalZdotdirVariableName)
        setenv(zdotdirVariableName, expectedZdotdir, 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertNil(currentValue(zdotdirVariableName),
                     "with nothing saved to restore, remove() must unset ZDOTDIR entirely (the pre-apply state)")
    }

    func test_remove_doesNotClobberZdotdirChangedBySomeoneElseAfterApply() {
        // Sanity precondition: remove() DOES restore ZDOTDIR in the
        // normal case (current value still points at our own installed
        // dir) -- proven first so the negative assertion below is caused
        // specifically by the deliberate mismatch, not by remove() being
        // a no-op in general (true of today's RED-phase stub either way).
        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh", 1)
        setenv(zdotdirVariableName, expectedZdotdir, 1)
        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)
        XCTAssertEqual(currentValue(zdotdirVariableName), "/Users/alice/.config/zsh",
                       "precondition: remove() must restore ZDOTDIR in the normal (still-ours) case")

        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh", 1)
        setenv(zdotdirVariableName, "/some/other/tools/zdotdir", 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertEqual(currentValue(zdotdirVariableName), "/some/other/tools/zdotdir",
                       "remove() must NOT clobber ZDOTDIR once it no longer points at our own installed dir")
    }

    func test_remove_unconditionallyUnsetsCalyxZshZdotdirEvenWhenZdotdirNoLongerOurs() {
        // Review finding: CALYX_ZSH_ZDOTDIR is purely our own internal
        // bookkeeping variable -- remove() must clear it as part of
        // undoing everything apply() might have set, regardless of
        // whether the ZDOTDIR-restore branch itself even ran.
        setenv(originalZdotdirVariableName, "/Users/alice/.config/zsh", 1)
        setenv(zdotdirVariableName, "/some/other/tools/zdotdir", 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertNil(currentValue(originalZdotdirVariableName),
                     "remove() must unset CALYX_ZSH_ZDOTDIR unconditionally, even when ZDOTDIR no longer " +
                     "points at our own installed dir")
    }

    // MARK: - remove(rootDirectory:) — XDG_DATA_DIRS

    func test_remove_removesRootFromXdgDataDirsWhenPresent() {
        setenv(xdgDataDirsVariableName, "/opt/homebrew/share:\(root.path):/usr/local/share", 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        let value = currentValue(xdgDataDirsVariableName)
        XCTAssertEqual(value, "/opt/homebrew/share:/usr/local/share",
                       "remove() must strip only our own root entry out of XDG_DATA_DIRS, preserving the rest")
    }

    func test_remove_doesNotClobberXdgDataDirsWhenRootAbsent() {
        // Sanity precondition, same shape as the ZDOTDIR mismatch test
        // above.
        setenv(xdgDataDirsVariableName, "/opt/homebrew/share:\(root.path)", 1)
        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)
        XCTAssertEqual(currentValue(xdgDataDirsVariableName), "/opt/homebrew/share",
                       "precondition: remove() must strip root from XDG_DATA_DIRS in the normal case")

        setenv(xdgDataDirsVariableName, "/opt/homebrew/share:/usr/local/share", 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertEqual(currentValue(xdgDataDirsVariableName), "/opt/homebrew/share:/usr/local/share",
                       "remove() must leave XDG_DATA_DIRS untouched when it never contained our root at all")
    }

    func test_remove_whenStrippingRootLeavesExactlyTheFishDefault_unsetsXdgDataDirsEntirely() {
        // Review finding: apply() initializes XDG_DATA_DIRS to
        // "<root>:/usr/local/share:/usr/share" when it was unset --
        // remove() can't know statefully (across process launches)
        // whether a given apply() initialized vs. appended, so it
        // approximates: stripping our root and landing on EXACTLY fish's
        // own default search path is treated as "we must have
        // initialized it" and the variable is unset entirely, restoring
        // the pre-apply (unset) state exactly.
        setenv(xdgDataDirsVariableName, "\(root.path):/usr/local/share:/usr/share", 1)

        CalyxShellIntegrationEnvironment.remove(rootDirectory: root)

        XCTAssertNil(currentValue(xdgDataDirsVariableName),
                     "stripping root and landing on exactly fish's own default search path must unset " +
                     "XDG_DATA_DIRS entirely, not leave it set to that reconstructed default string")
    }
}
