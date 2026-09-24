// GitModelsTests.swift
// CalyxTests
//
// Tests for Git data models: GitFileEntry, CommitFileEntry, DiffSource, GitFileStatus,
// GitChangesState, and GitRefreshFailureOutcome.

import Testing
@testable import Calyx

/// A section at `rootPath`. Only the identity matters to the rules tested
/// here, so the rest is filled in with what a plain repository looks like.
private func section(_ rootPath: String) -> GitRepoDescriptor {
    GitRepoDescriptor(
        rootPath: rootPath,
        displayName: rootPath,
        kind: .repository,
        branch: "main",
        headShortHash: "0123456",
        location: GitRepositoryLocation(
            workTree: rootPath,
            gitDirectory: rootPath + "/.git",
            gitCommonDirectory: rootPath + "/.git"
        )
    )
}

struct GitModelsTests {
    @Test func gitFileEntryIDIsDeterministic() {
        let a = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let b = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        #expect(a.id == b.id)
    }

    @Test func gitFileEntryIDDistinguishesStagedState() {
        let staged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let unstaged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        #expect(staged.id != unstaged.id)
    }

    @Test func commitFileEntryIDIsDeterministic() {
        let a = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        let b = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        #expect(a.id == b.id)
    }

    @Test func diffSourceEquality() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/tmp")
        #expect(a != c)
    }

    @Test func allGitFileStatusRawValues() {
        #expect(GitFileStatus.modified.rawValue == "M")
        #expect(GitFileStatus.added.rawValue == "A")
        #expect(GitFileStatus.deleted.rawValue == "D")
        #expect(GitFileStatus.renamed.rawValue == "R")
        #expect(GitFileStatus.copied.rawValue == "C")
        #expect(GitFileStatus.untracked.rawValue == "?")
        #expect(GitFileStatus.unmerged.rawValue == "U")
        #expect(GitFileStatus.typeChanged.rawValue == "T")
    }

    @Test func allowsInitialSpinnerOnlyForNotLoaded() {
        // .notLoaded is the only state with no content to preserve on screen,
        // so it is the only one allowed to show the content-replacing spinner.
        #expect(GitChangesState.notLoaded.allowsInitialSpinner == true)
        #expect(GitChangesState.notRepository.allowsInitialSpinner == false)
        #expect(GitChangesState.loading.allowsInitialSpinner == false)
        #expect(GitChangesState.loaded.allowsInitialSpinner == false)
        #expect(GitChangesState.error("git status failed").allowsInitialSpinner == false)
    }

    @Test func gitChangesStateEquatable() {
        #expect(GitChangesState.notLoaded == GitChangesState.notLoaded)
        #expect(GitChangesState.loaded == GitChangesState.loaded)
        #expect(GitChangesState.notLoaded != GitChangesState.loading)
        #expect(GitChangesState.loading != GitChangesState.loaded)
        #expect(GitChangesState.notRepository != GitChangesState.notLoaded)
        #expect(GitChangesState.error("a") == GitChangesState.error("a"))
        #expect(GitChangesState.error("a") != GitChangesState.error("b"))
    }

    @Test func notARepositoryFailureAlwaysShowsNotRepository() {
        // A "not a repository" failure is a real state change (the user cd'd
        // out of the repo), so it wins over any current state, including one
        // with content already on screen.
        let fromLoaded = GitRefreshFailureOutcome.resolve(
            current: .loaded,
            isNotARepository: true,
            message: "not a git repository"
        )
        #expect(fromLoaded == .showNotRepository)

        let fromNotLoaded = GitRefreshFailureOutcome.resolve(
            current: .notLoaded,
            isNotARepository: true,
            message: "not a git repository"
        )
        #expect(fromNotLoaded == .showNotRepository)
    }

    @Test func ordinaryFailureFromLoadedKeepsStaleContent() {
        let outcome = GitRefreshFailureOutcome.resolve(
            current: .loaded,
            isNotARepository: false,
            message: "git status failed: exit 128"
        )
        #expect(outcome == .keepStale(message: "git status failed: exit 128"))
    }

    @Test func ordinaryFailureFromNonLoadedStatesShowsError() {
        // Every state other than .loaded has no content worth preserving,
        // so an ordinary failure replaces it with the error state.
        let message = "git status failed: exit 128"

        let fromNotLoaded = GitRefreshFailureOutcome.resolve(
            current: .notLoaded,
            isNotARepository: false,
            message: message
        )
        #expect(fromNotLoaded == .showError(message))

        let fromLoading = GitRefreshFailureOutcome.resolve(
            current: .loading,
            isNotARepository: false,
            message: message
        )
        #expect(fromLoading == .showError(message))

        let fromError = GitRefreshFailureOutcome.resolve(
            current: .error("previous error"),
            isNotARepository: false,
            message: message
        )
        #expect(fromError == .showError(message))

        let fromNotRepository = GitRefreshFailureOutcome.resolve(
            current: .notRepository,
            isNotARepository: false,
            message: message
        )
        #expect(fromNotRepository == .showError(message))
    }

    @Test func discoveryWithoutSeedWorkDirsKeepsLoadedSections() {
        // A window with no terminal pane has nowhere to search from, which
        // is not evidence that its repositories are gone.
        let outcome = GitRefreshFailureOutcome.resolveDiscovery(
            current: .loaded,
            hasSeedWorkDirs: false,
            failureMessage: nil
        )
        #expect(outcome == .keepStale(message: "No working directory found"))
    }

    @Test func discoveryWithSeedWorkDirsAndNoRepositoryShowsNotRepository() {
        // The same empty result, but reached by searching real directories,
        // is a real state change: every pane sits outside a repository.
        let fromLoaded = GitRefreshFailureOutcome.resolveDiscovery(
            current: .loaded,
            hasSeedWorkDirs: true,
            failureMessage: nil
        )
        #expect(fromLoaded == .showNotRepository)

        let fromNotLoaded = GitRefreshFailureOutcome.resolveDiscovery(
            current: .notLoaded,
            hasSeedWorkDirs: true,
            failureMessage: nil
        )
        #expect(fromNotLoaded == .showNotRepository)
    }

    @Test func discoveryWithoutSeedWorkDirsAndNothingOnScreenShowsError() {
        let outcome = GitRefreshFailureOutcome.resolveDiscovery(
            current: .notLoaded,
            hasSeedWorkDirs: false,
            failureMessage: nil
        )
        #expect(outcome == .showError("No working directory found"))
    }

    @Test func discoveryFailureFromLoadedKeepsStaleSections() {
        let message = "git rev-parse failed: exit 128"
        let outcome = GitRefreshFailureOutcome.resolveDiscovery(
            current: .loaded,
            hasSeedWorkDirs: true,
            failureMessage: message
        )
        #expect(outcome == .keepStale(message: message))
    }

    @Test func showsLoadingOnlyWhileThereIsNothingToKeepOnScreen() {
        #expect(GitChangesState.notLoaded.showsLoadingWhileFetching == true)
        #expect(GitChangesState.notRepository.showsLoadingWhileFetching == true)
        #expect(GitChangesState.error("git status failed").showsLoadingWhileFetching == true)
        #expect(GitChangesState.loading.showsLoadingWhileFetching == false)
        #expect(GitChangesState.loaded.showsLoadingWhileFetching == false)
    }

    // MARK: - Changed file count

    @Test func changedFileCountCountsAPartiallyStagedFileOnce() {
        // `git status` reports a partially staged file twice, once for the
        // index and once for the work tree.
        let changes = GitRepoChanges(entries: [
            GitFileEntry(path: "a.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil),
            GitFileEntry(path: "a.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil),
            GitFileEntry(path: "b.swift", origPath: nil, status: .added, isStaged: true, renameScore: nil),
            GitFileEntry(path: "c.swift", origPath: nil, status: .untracked, isStaged: false, renameScore: nil),
        ])

        #expect(changes.changedFileCount == 3)
        #expect(GitRepoChanges().changedFileCount == 0)
    }

    // MARK: - Fetch scopes

    @Test func sectionFetchScopeMergeKeepsEveryRequestedHalf() {
        #expect(GitSectionFetchScope.log.merged(with: .status) == .statusAndLog)
        #expect(GitSectionFetchScope.statusAndLog.merged(with: .status) == .statusAndLog)
        #expect(
            GitSectionFetchScope.status.merged(with: .moreCommits)
                == GitSectionFetchScope(includesStatus: true, loadsMoreCommits: true)
        )
        #expect(GitSectionFetchScope().isEmpty)
        #expect(!GitSectionFetchScope.moreCommits.isEmpty)
        #expect(GitSectionFetchScope.status(includingLog: true) == .statusAndLog)
        #expect(GitSectionFetchScope.status(includingLog: false) == .status)
    }

    // MARK: - What a section shows

    @Test func aSectionWithNothingFetchedYetSaysSoInsteadOfShowingAnEmptyList() {
        // An empty change list means "no changes"; a section that has never
        // been fetched has no business claiming that.
        #expect(GitRepoChanges().sectionContent == .loading)
        #expect(GitRepoChanges(state: .loading).sectionContent == .loading)
    }

    @Test func aSectionKeepsShowingItsContentWhileItRefreshes() {
        let entry = GitFileEntry(
            path: "a.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil
        )
        let commit = GitCommit(
            id: "3f5a1c9d2b4e6f8a0c1d3e5f7a9b1c3d5e7f9a1b",
            shortHash: "3f5a1c9",
            message: "base commit",
            author: "Calyx Tests",
            relativeDate: "2 days ago",
            parentIDs: [],
            graphPrefix: "* "
        )

        #expect(GitRepoChanges(state: .loading, entries: [entry]).sectionContent == .changes)
        #expect(GitRepoChanges(state: .loading, commits: [commit]).sectionContent == .changes)
        #expect(GitRepoChanges(state: .loaded).sectionContent == .changes)
    }

    @Test func aSectionThatFailedShowsWhyRatherThanWhatItHad() {
        let entry = GitFileEntry(
            path: "a.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil
        )

        #expect(
            GitRepoChanges(state: .error("git status failed")).sectionContent
                == .error("git status failed")
        )
        #expect(GitRepoChanges(state: .notRepository).sectionContent == .notRepository)
        #expect(
            GitRepoChanges(state: .error("git status failed"), entries: [entry]).sectionContent
                == .error("git status failed")
        )
    }

    // MARK: - Sections a discovery run fetches

    @Test func aSectionThatWasNeverFetchedIsClaimedByTheRunThatConfirmsIt() {
        // A section left behind by a run that was superseded before it could
        // fetch is named by no later scope and is new to none of them, so
        // only its own emptiness can get it fetched.
        let fetched = GitSectionRefreshScope.appearedSections.sectionsToFetch(
            from: [section("/repos/alpha"), section("/repos/beta")],
            checked: ["/repos/alpha", "/repos/beta"],
            known: ["/repos/alpha", "/repos/beta"],
            changes: [
                "/repos/alpha": GitRepoChanges(state: .loaded),
                "/repos/beta": GitRepoChanges(),
            ]
        )

        #expect(fetched == ["/repos/beta"])
    }

    @Test func aSectionAlreadyOnScreenIsNotFetchedByARunThatDidNotAskForIt() {
        // Sections whose content is current stay untouched: that is what
        // keeps switching tabs from re-running git for the whole window.
        let fetched = GitSectionRefreshScope.appearedSections.sectionsToFetch(
            from: [section("/repos/alpha")],
            checked: ["/repos/alpha"],
            known: ["/repos/alpha"],
            changes: ["/repos/alpha": GitRepoChanges(state: .loaded)]
        )

        #expect(fetched.isEmpty)
    }

    @Test func aSectionTheRunCouldNotCheckIsLeftAlone() {
        // Its repository failed to answer, so there is nothing to fetch from
        // and nothing the run knows about it.
        let fetched = GitSectionRefreshScope.everySection.sectionsToFetch(
            from: [section("/repos/alpha")],
            checked: [],
            known: [],
            changes: ["/repos/alpha": GitRepoChanges()]
        )

        #expect(fetched.isEmpty)
    }

    @Test func newStaleAndRequestedSectionsAreFetched() {
        let sections = [
            section("/repos/alpha"), section("/repos/beta"), section("/repos/gamma"),
        ]
        let checked: Set<String> = ["/repos/alpha", "/repos/beta", "/repos/gamma"]
        let changes: [String: GitRepoChanges] = [
            "/repos/alpha": GitRepoChanges(state: .loaded),
            "/repos/beta": GitRepoChanges(state: .loaded, staleRefreshMessage: "git status failed"),
            "/repos/gamma": GitRepoChanges(),
        ]

        let appeared = GitSectionRefreshScope.appearedSections.sectionsToFetch(
            from: sections,
            checked: checked,
            known: ["/repos/beta", "/repos/gamma"],
            changes: changes
        )
        #expect(appeared == ["/repos/alpha", "/repos/beta", "/repos/gamma"])

        let named = GitSectionRefreshScope.sections(["/repos/alpha"]).sectionsToFetch(
            from: sections,
            checked: checked,
            known: checked,
            changes: [
                "/repos/alpha": GitRepoChanges(state: .loaded),
                "/repos/beta": GitRepoChanges(state: .loaded),
                "/repos/gamma": GitRepoChanges(state: .loaded),
            ]
        )
        #expect(named == ["/repos/alpha"])

        let everySection = GitSectionRefreshScope.everySection.sectionsToFetch(
            from: sections,
            checked: checked,
            known: checked,
            changes: [
                "/repos/alpha": GitRepoChanges(state: .loaded),
                "/repos/beta": GitRepoChanges(state: .loaded),
                "/repos/gamma": GitRepoChanges(state: .loaded),
            ]
        )
        #expect(everySection == ["/repos/alpha", "/repos/beta", "/repos/gamma"])
    }

    // MARK: - Commit list prefetching

    @Test func commitPageSizeExceedsThePrefetchThreshold() {
        // An appended page moves the trigger `commitPageSize -
        // commitPrefetchThreshold` rows down. Without a positive gap the
        // trigger lands on a row that is already realized, never appears
        // again, and paging stalls.
        #expect(GitRepoChanges.commitPageSize > GitRepoChanges.commitPrefetchThreshold)
    }

    @Test func commitPrefetchTriggerIndexIsNilForAnEmptyList() {
        #expect(GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 0) == nil)
    }

    @Test func commitPrefetchTriggerIndexClampsToTheFirstRowWhenFewerRowsThanTheThreshold() {
        // With fewer commits loaded than the threshold, the very first row
        // is the only one that can still request the next page in time.
        #expect(
            GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 5, threshold: 12) == 0
        )
    }

    @Test func commitPrefetchTriggerIndexAtExactlyTheThreshold() {
        #expect(
            GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 12, threshold: 12) == 0
        )
    }

    @Test func commitPrefetchTriggerIndexOneRowPastTheThreshold() {
        #expect(
            GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 13, threshold: 12) == 1
        )
    }

    @Test func commitPrefetchTriggerIndexForALargeList() {
        #expect(
            GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 100, threshold: 12) == 88
        )
    }

    @Test func commitPrefetchTriggerIndexWithAThresholdOfOneIsTheLastRow() {
        #expect(
            GitRepoChanges.commitPrefetchTriggerIndex(commitCount: 100, threshold: 1) == 99
        )
    }

    // MARK: - Discovery refresh scope merging

    @Test func discoveryRefreshScopeMergeKeepsTheWiderRequest() {
        // A background event superseding a manual refresh must not narrow
        // it into a run that fetches nothing.
        let merged = GitSectionRefreshScope.sections(["A"]).merged(with: .everySection)
        #expect(merged.includesEverySection)
        #expect(merged.includes("anything"))

        let named = GitSectionRefreshScope.sections(["A"]).merged(with: .sections(["B"]))
        #expect(named.includes("A"))
        #expect(named.includes("B"))
        #expect(!named.includes("C"))
        #expect(!GitSectionRefreshScope.appearedSections.includes("A"))
    }
}
