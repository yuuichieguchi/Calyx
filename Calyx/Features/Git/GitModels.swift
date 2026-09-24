// GitModels.swift
// Calyx
//
// Data models for git source control integration.

import Foundation

// TODO: Move `SidebarMode` to a neutral location (e.g. Features/Sidebar/SidebarModels.swift).
// It is used by tabs, git-changes, and the AI-agent status view, so it no longer
// belongs to the git domain — it just lives here for historical reasons.
enum SidebarMode: Sendable {
    case tabs
    case changes
    case agents
}

enum GitChangesState: Sendable, Equatable {
    case notLoaded
    case notRepository
    case loading
    case loaded
    case error(String)

    /// `.notLoaded` is the only state with no content already on screen,
    /// so it is the only one allowed to show `GitChangesView`'s
    /// content-replacing spinner. Every other state keeps whatever is
    /// currently displayed while a refresh runs.
    var allowsInitialSpinner: Bool {
        self == .notLoaded
    }

    /// Whether a fetch starting from this state should move the section to
    /// `.loading`. A section with content on screen keeps showing it while
    /// it refreshes; one showing an error, or nothing yet, has nothing to
    /// keep, and a section already loading says so.
    var showsLoadingWhileFetching: Bool {
        switch self {
        case .notLoaded, .notRepository, .error: true
        case .loading, .loaded: false
        }
    }
}

/// What a failed git refresh should do to `GitChangesState`, decided
/// separately from applying it so the decision itself is testable
/// without a running refresh task.
enum GitRefreshFailureOutcome: Equatable, Sendable {
    case showError(String)
    case showNotRepository
    case keepStale(message: String)

    static func resolve(
        current: GitChangesState,
        isNotARepository: Bool,
        message: String
    ) -> GitRefreshFailureOutcome {
        if isNotARepository {
            return .showNotRepository
        }
        if current == .loaded {
            return .keepStale(message: message)
        }
        return .showError(message)
    }

    /// What a discovery run that produced no sections should do.
    /// `hasSeedWorkDirs` separates "searched every pane's directory and
    /// found no repository" from "had no directory to search": only the
    /// first is evidence that the window is outside a repository, so a
    /// window without a terminal pane keeps the sections it is showing.
    /// `failureMessage` is read only for the outcomes returned when
    /// `isNotARepository` is false, which is exactly when discovery
    /// reported a failure.
    static func resolveDiscovery(
        current: GitChangesState,
        hasSeedWorkDirs: Bool,
        failureMessage: String?
    ) -> GitRefreshFailureOutcome {
        guard hasSeedWorkDirs else {
            return resolve(
                current: current,
                isNotARepository: false,
                message: "No working directory found"
            )
        }
        return resolve(
            current: current,
            isNotARepository: failureMessage == nil,
            message: failureMessage ?? ""
        )
    }
}

// MARK: - Git Status

enum GitFileStatus: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case unmerged = "U"
    case typeChanged = "T"
}

struct GitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(isStaged)-\(status.rawValue)-\(path)" }
    let path: String
    let origPath: String?
    let status: GitFileStatus
    let isStaged: Bool
    let renameScore: Int?
}

// MARK: - Commit Graph

struct GitCommit: Identifiable, Equatable, Sendable {
    let id: String              // full SHA
    let shortHash: String       // first 7 chars
    let message: String         // first line
    let author: String
    let relativeDate: String
    let parentIDs: [String]
    let graphPrefix: String     // git log --graph prefix string
    /// Branches, remote branches, and tags pointing at this commit, from
    /// `%D`. Empty when the log that produced this commit did not ask for
    /// decoration, or the commit has none.
    let refNames: [String]

    init(
        id: String,
        shortHash: String,
        message: String,
        author: String,
        relativeDate: String,
        parentIDs: [String],
        graphPrefix: String,
        refNames: [String] = []
    ) {
        self.id = id
        self.shortHash = shortHash
        self.message = message
        self.author = author
        self.relativeDate = relativeDate
        self.parentIDs = parentIDs
        self.graphPrefix = graphPrefix
        self.refNames = refNames
    }
}

struct CommitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(commitHash)-\(status.rawValue)-\(path)" }
    let commitHash: String
    let path: String
    let origPath: String?
    let status: GitFileStatus
}

// MARK: - Ref Selection

/// What commit history a section's `git log` covers. `.auto` follows
/// `GitService.autoRefs` (HEAD, its upstream, the upstream's remote's
/// default branch), `.all` is every ref the repository has, and `.refs`
/// pins the exact set the user picked, by full ref name.
enum GitRefSelection: Equatable, Sendable, Codable {
    case auto
    case all
    case refs([String])

    /// Drops any saved ref this repository no longer has, keeping the
    /// order the user picked. `.auto` and `.all` are unaffected: neither
    /// names a specific ref that can vanish. A `.refs` selection with no
    /// survivor falls back to `.auto` rather than filtering on nothing.
    func reconciled(withLiveRefs live: Set<String>) -> GitRefSelection {
        switch self {
        case .auto, .all:
            return self
        case .refs(let names):
            let survivors = names.filter(live.contains)
            return survivors.isEmpty ? .auto : .refs(survivors)
        }
    }
}

/// One ref a repository has, as `GitService.refList` classifies it.
struct GitRefInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case localBranch
        case remoteBranch
        case tag
    }

    let fullName: String
    let shortName: String
    let kind: Kind
}

// MARK: - Repository Sections

enum GitRepoKind: Equatable, Sendable {
    case repository
    case worktree
    case submodule
}

/// One Changes-sidebar section. `rootPath` is a standardized absolute
/// work-tree root and doubles as the stable identity across refreshes.
struct GitRepoDescriptor: Identifiable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let kind: GitRepoKind
    /// `nil` when the work tree has a detached HEAD.
    let branch: String?
    let headShortHash: String?
    let location: GitRepositoryLocation

    var id: String { rootPath }
}

/// What an expanded section shows. Separating this from the states that
/// produce it keeps "nothing fetched yet" from looking like "no changes":
/// both would otherwise render as an empty list.
enum GitRepoSectionContent: Equatable, Sendable {
    case loading
    case error(String)
    case notRepository
    case changes
}

/// Per-section Changes state. Every field is scoped to one repository so
/// pruning a vanished section is a single dictionary removal.
struct GitRepoChanges: Equatable, Sendable {
    var state: GitChangesState = .notLoaded
    var entries: [GitFileEntry] = []
    var commits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    /// Distinguishes "history fetched and empty" from "history not fetched".
    var isLogLoaded = false
    var hasMoreCommits = true
    var staleRefreshMessage: String?
    /// Every branch, remote branch, and tag this repository has, as of the
    /// last successful log fetch. Feeds the ref picker's menu contents and
    /// `GitRefSelection.reconciled(withLiveRefs:)`.
    var availableRefs: [GitRefInfo] = []
    /// The ref scope the selection last resolved to, so a load-more page
    /// queries the exact same refs the commits already on screen came
    /// from instead of re-resolving `.auto`/`.all` (and risking a
    /// different answer, e.g. a ref that vanished between pages) on every
    /// page. Same lifetime as `commits`: cleared wherever `commits` is.
    var resolvedRefScope: GitService.GitResolvedRefScope?

    /// The number of changed files. `git status` reports a partially staged
    /// file twice, once staged and once not, so counting entries would count
    /// that file twice.
    var changedFileCount: Int {
        Set(entries.map(\.path)).count
    }

    /// How many rows before the end of the commit list the next page is
    /// requested.
    static let commitPrefetchThreshold = 12

    /// How many commits one load-more page fetches. It must exceed
    /// `commitPrefetchThreshold`: otherwise the trigger index after an
    /// append lands on a row that is already realized, its appearance never
    /// fires again, and paging stalls.
    static let commitPageSize = 50

    /// The index of the commit row whose appearance should request the next
    /// page, or nil when the list is empty. With fewer rows than the
    /// threshold the first row triggers.
    static func commitPrefetchTriggerIndex(
        commitCount: Int,
        threshold: Int = commitPrefetchThreshold
    ) -> Int? {
        guard commitCount > 0 else { return nil }
        return max(commitCount - threshold, 0)
    }

    /// The one mapping from a section's state to what it shows. Every state
    /// is spelled out, so a state added later cannot fall through to an
    /// empty change list. A fetch that has content to keep on screen shows
    /// it while it runs; one that has none shows that it is running.
    var sectionContent: GitRepoSectionContent {
        switch state {
        case .notLoaded:
            .loading
        case .loading:
            entries.isEmpty && commits.isEmpty ? .loading : .changes
        case .error(let message):
            .error(message)
        case .notRepository:
            .notRepository
        case .loaded:
            .changes
        }
    }
}

// MARK: - Fetch Scopes

/// What one section's fetch covers. Requests that arrive while a section is
/// already fetching are merged into the next run rather than replacing it,
/// so a narrow request never discards the work a wider one has in flight.
struct GitSectionFetchScope: Equatable, Sendable {
    var includesStatus = false
    var includesLog = false
    var loadsMoreCommits = false

    static let status = GitSectionFetchScope(includesStatus: true)
    static let statusAndLog = GitSectionFetchScope(includesStatus: true, includesLog: true)
    static let log = GitSectionFetchScope(includesLog: true)
    static let moreCommits = GitSectionFetchScope(loadsMoreCommits: true)

    static func status(includingLog includesLog: Bool) -> GitSectionFetchScope {
        GitSectionFetchScope(includesStatus: true, includesLog: includesLog)
    }

    var isEmpty: Bool {
        !includesStatus && !includesLog && !loadsMoreCommits
    }

    func merged(with other: GitSectionFetchScope) -> GitSectionFetchScope {
        GitSectionFetchScope(
            includesStatus: includesStatus || other.includesStatus,
            includesLog: includesLog || other.includesLog,
            loadsMoreCommits: loadsMoreCommits || other.loadsMoreCommits
        )
    }
}

/// Which sections a discovery run re-fetches once its result is applied.
/// A run that supersedes another inherits its scope, so a background event
/// cannot narrow a refresh the user asked for.
struct GitSectionRefreshScope: Equatable, Sendable {
    /// Every section, for the triggers that mean "show current data".
    var includesEverySection = false
    /// Sections named by the events that asked for the run.
    var repoIDs: Set<String> = []

    /// Sections that appear for the first time are always fetched, so a run
    /// that names nothing still populates what discovery just found.
    static let appearedSections = GitSectionRefreshScope()
    static let everySection = GitSectionRefreshScope(includesEverySection: true)

    static func sections(_ repoIDs: Set<String>) -> GitSectionRefreshScope {
        GitSectionRefreshScope(repoIDs: repoIDs)
    }

    func merged(with other: GitSectionRefreshScope) -> GitSectionRefreshScope {
        GitSectionRefreshScope(
            includesEverySection: includesEverySection || other.includesEverySection,
            repoIDs: repoIDs.union(other.repoIDs)
        )
    }

    func includes(_ repoID: String) -> Bool {
        includesEverySection || repoIDs.contains(repoID)
    }

    /// Which of `sections` a discovery run fetches once its result is
    /// applied. `checkedRepoIDs` are the sections the run confirmed;
    /// a section it could not look at keeps what it has, because its
    /// repository merely failed to answer. `knownRepoIDs` are the sections
    /// that existed before the run, and `changes` their state after it.
    ///
    /// Besides the sections this scope names, a section is fetched when it
    /// has just appeared, when its content is known to be out of date, and
    /// when it has never been fetched at all. Having no content is the
    /// strongest form of content that cannot be trusted, so the first run
    /// that can confirm the repository fetches it, whichever run created
    /// the section.
    func sectionsToFetch(
        from sections: [GitRepoDescriptor],
        checked checkedRepoIDs: Set<String>,
        known knownRepoIDs: Set<String>,
        changes: [String: GitRepoChanges]
    ) -> [String] {
        sections.compactMap { section in
            guard checkedRepoIDs.contains(section.id) else { return nil }
            let isNew = !knownRepoIDs.contains(section.id)
            let current = changes[section.id] ?? GitRepoChanges()
            let hasNoTrustedContent =
                current.state == .notLoaded || current.staleRefreshMessage != nil
            guard includes(section.id) || isNew || hasNoTrustedContent else { return nil }
            return section.id
        }
    }
}

// MARK: - Sidebar Refresh

/// What asked the Changes sidebar to refresh. Each trigger decides on its
/// own whether repository discovery runs and which sections re-fetch, so
/// the cost of a refresh matches the event that caused it.
enum GitSidebarRefreshTrigger: Equatable, Sendable {
    /// The Changes sidebar became visible.
    case sidebarShown
    /// A terminal pane reported a new working directory.
    case paneDirectoryChanged
    /// The refresh button or the Refresh Git Changes command.
    case manualRefresh
    /// A different tab became active, which includes a tab being closed.
    /// Deliberately does not re-fetch what is already on screen: file-system
    /// events keep sections current, and a manual refresh recovers anything
    /// they missed. Discovery runs only when the panes no longer sit in the
    /// same repositories.
    case tabActivated
    /// A file-system event, carrying every section it belongs to. A write to
    /// a Git directory shared by several worktrees belongs to all of them.
    case monitorEvent(repoIDs: Set<String>, kind: GitChangesRefreshKind)
}

// MARK: - Sidebar View State

/// One rendered section: its repository, that repository's Changes state,
/// and where it sits in the sidebar.
struct GitRepoSectionViewData: Identifiable, Equatable, Sendable {
    let descriptor: GitRepoDescriptor
    let changes: GitRepoChanges
    /// The section owning the active pane's working directory.
    let isActive: Bool
    let isExpanded: Bool
    let refSelection: GitRefSelection

    var id: String { descriptor.id }
}

/// Everything `GitChangesView` renders, assembled in one value so the
/// views between the window controller and the sidebar pass it through
/// without knowing its shape.
struct GitSidebarViewState: Equatable, Sendable {
    var phase: GitChangesState = .notLoaded
    var isRefreshing: Bool = false
    var staleRefreshMessage: String?
    var sections: [GitRepoSectionViewData] = []
    var commitFiles: [String: [CommitFileEntry]] = [:]
}

// MARK: - Diff

enum DiffLineType: Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
    case meta
}

struct DiffLine: Equatable, Sendable {
    let type: DiffLineType
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct FileDiff: Equatable, Sendable {
    let path: String
    let lines: [DiffLine]
    let isBinary: Bool
    let isTruncated: Bool
}

enum DiffLoadState: Sendable {
    case loading
    case success(FileDiff)
    case error(String)
}

enum DiffSource: Sendable, Equatable {
    case unstaged(path: String, workDir: String)
    case staged(path: String, workDir: String)
    case commit(hash: String, path: String, workDir: String)
    case untracked(path: String, workDir: String)
}
