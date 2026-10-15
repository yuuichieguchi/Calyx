// GitService.swift
// Calyx
//
// Executes git commands and parses output. All methods run off-main-thread.

import Foundation
import os

/// One record of `git worktree list --porcelain`. `path` is the only
/// attribute the porcelain schema guarantees; everything else is optional
/// or a bare flag label.
struct GitWorktreeInfo: Equatable, Sendable {
    let path: String
    let headOID: String?
    /// Full ref name such as `refs/heads/main`. Mutually exclusive with `isDetached`.
    let branchRef: String?
    let isDetached: Bool
    let isBare: Bool
    let isLocked: Bool
    let lockReason: String?
    let isPrunable: Bool
    let prunableReason: String?

    init(
        path: String,
        headOID: String? = nil,
        branchRef: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil
    ) {
        self.path = path
        self.headOID = headOID
        self.branchRef = branchRef
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }
}

/// One submodule of a superproject, as its index records it. The index is
/// the only place git validates the path: `.gitmodules` is a tracked text
/// file whose declarations nothing checks.
struct GitSubmoduleInfo: Equatable, Sendable {
    /// Relative to the superproject's work-tree root.
    let path: String
}

/// What HEAD resolves to. A detached HEAD has no branch, and a HEAD before
/// the first commit names no commit, so both halves can be absent.
struct GitHeadSummary: Equatable, Sendable {
    let branch: String?
    let shortHash: String?
}

enum GitService {
    enum GitError: Error, LocalizedError {
        case notARepository
        case gitNotFound
        case permissionDenied(path: String)
        case commandFailed(exitCode: Int32, stderr: String, command: String)
        case timeout(command: String)
        case diffTooLarge(path: String, size: Int)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                "Not a git repository"
            case .gitNotFound:
                "git not found at /usr/bin/git"
            case .permissionDenied(let path):
                "Permission denied: \(path)"
            case .commandFailed(let exitCode, let stderr, let command):
                "git \(command) failed (exit \(exitCode)): \(stderr)"
            case .timeout(let command):
                "git \(command) timed out"
            case .diffTooLarge(let path, let size):
                "Diff too large for \(path) (\(size) bytes)"
            }
        }
    }

    private static let gitPath = "/usr/bin/git"

    // MARK: - Public API

    static func repoRoot(workDir: String) async throws -> String {
        let output = try await run(args: ["rev-parse", "--show-toplevel"], workDir: workDir)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func repositoryLocation(workDir: String) async throws -> GitRepositoryLocation {
        let output = try await run(
            args: [
                "rev-parse", "--show-toplevel", "--path-format=absolute",
                "--git-dir", "--git-common-dir",
            ],
            workDir: workDir
        )
        let paths = output.split(whereSeparator: \.isNewline).map(String.init)
        guard paths.count == 3 else {
            throw GitError.commandFailed(
                exitCode: -1,
                stderr: "Unexpected git repository metadata",
                command: "rev-parse"
            )
        }
        return GitRepositoryLocation(
            workTree: paths[0],
            gitDirectory: paths[1],
            gitCommonDirectory: paths[2]
        )
    }

    static func isGitRepository(workDir: String) async -> Bool {
        do {
            _ = try await repoRoot(workDir: workDir)
            return true
        } catch {
            return false
        }
    }

    static func gitStatus(workDir: String) async throws -> [GitFileEntry] {
        let output = try await run(args: ["status", "--porcelain=v2", "-z"], workDir: workDir)
        return parseStatus(output)
    }

    /// Every worktree attached to the repository containing `workDir`,
    /// including the main worktree (or the bare repository itself) first.
    static func worktreeList(workDir: String) async throws -> [GitWorktreeInfo] {
        let output = try await run(args: ["worktree", "list", "--porcelain", "-z"], workDir: workDir)
        return parseWorktreeList(output)
    }

    /// Every submodule recorded in the index of the repository rooted at
    /// `repoRoot`, in index order. Whether a submodule's directory is
    /// actually filled in is a separate question this does not answer.
    static func submoduleList(repoRoot: String) async throws -> [GitSubmoduleInfo] {
        let output = try await run(args: ["ls-files", "-z", "--stage"], workDir: repoRoot)
        return parseIndexGitlinks(output)
    }

    /// The gitlinks in `git ls-files -z --stage` output. Each record is
    /// `<mode> <sha> <stage>`, a tab, then the path, NUL-terminated, and
    /// mode 160000 is a gitlink. `-z` leaves the path unquoted, so it can
    /// hold spaces and tabs of its own and only the first tab separates
    /// it from the fields. A path an unresolved merge lists once per
    /// stage is still one submodule. The index of a large repository runs
    /// to hundreds of thousands of entries, so the scan stays on the UTF-8
    /// bytes (0x00 ends a record, 0x09 is the tab) and only the gitlink
    /// paths become Strings.
    static func parseIndexGitlinks(_ output: String) -> [GitSubmoduleInfo] {
        let gitlinkMode = Array("160000 ".utf8)
        var seenPaths: Set<String> = []
        var submodules: [GitSubmoduleInfo] = []
        for record in output.utf8.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.starts(with: gitlinkMode),
                  let tabIndex = record.firstIndex(of: 0x09) else { continue }
            let path = String(decoding: record[record.index(after: tabIndex)...], as: UTF8.self)
            guard seenPaths.insert(path).inserted else { continue }
            submodules.append(GitSubmoduleInfo(path: path))
        }
        return submodules
    }

    /// The branch and abbreviated commit HEAD points at. The two queries
    /// are independent, so they run concurrently.
    static func headSummary(workDir: String) async throws -> GitHeadSummary {
        async let branch = runReportingNoAnswerAsNil(
            args: ["symbolic-ref", "--short", "-q", "HEAD"], workDir: workDir
        )
        // `-q --verify` is what makes an unborn HEAD exit 1 instead of the
        // 128 a plain `rev-parse --short HEAD` returns, which a corrupt
        // repository returns as well.
        async let shortHash = runReportingNoAnswerAsNil(
            args: ["rev-parse", "--short", "-q", "--verify", "HEAD"], workDir: workDir
        )
        return try await GitHeadSummary(branch: branch, shortHash: shortHash)
    }

    /// The work tree of the superproject this repository is a submodule
    /// of, or `nil` when it is not one. A repository that is nobody's
    /// submodule answers with no output and exit 0.
    static func superprojectWorkTree(workDir: String) async throws -> String? {
        let output = try await run(
            args: ["rev-parse", "--show-superproject-working-tree"], workDir: workDir
        )
        let workTree = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return workTree.isEmpty ? nil : workTree
    }

    /// Runs a query whose `-q` turns "there is no such thing to report"
    /// into a silent exit 1, and reports that answer as nil. Detached HEAD
    /// and unborn HEAD reach their callers this way, so exit 1 here is a
    /// value rather than a failure. Every other exit code still throws.
    private static func runReportingNoAnswerAsNil(
        args: [String],
        workDir: String
    ) async throws -> String? {
        do {
            let output = try await run(args: args, workDir: workDir)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.commandFailed(let exitCode, _, _) where exitCode == 1 {
            return nil
        }
    }

    /// A ref scope already resolved to concrete git-log arguments -- no
    /// further `autoRefs`/`refList` resolution needed. `.all` is kept
    /// distinct from an explicit ref list rather than being expanded to
    /// one, so it still becomes the `--all` flag.
    enum GitResolvedRefScope: Equatable, Sendable {
        case all
        case refs([String])
    }

    /// Resolves `selection` against `liveRefs`, a `refList` result the
    /// caller already has in hand -- so a caller that fetched it for some
    /// other reason (populating the ref picker, say) never pays for a
    /// second `for-each-ref` just to resolve `.auto` or `.all`. `liveRefs`
    /// is also what an `.auto` selection's synthesized upstream and base
    /// refs are validated against: `%(upstream)` and a remote's
    /// `<remote>/HEAD` symref both answer from config alone, so either can
    /// still name a ref `git fetch --prune` (or a remote's renamed default
    /// branch) has since deleted.
    static func resolvedRefScope(
        location: GitRepositoryLocation,
        selection: GitRefSelection,
        liveRefs: [GitRefInfo]
    ) async throws -> GitResolvedRefScope {
        switch selection {
        case .auto:
            return .refs(try await autoRefs(location: location, liveRefs: liveRefs))
        case .all:
            // Zero refs is not always "unborn": a detached HEAD with its
            // branch deleted still has real history at HEAD, just no ref
            // naming it, and `--all` on a repository with no refs at all
            // exits nonzero rather than answering that history. `autoRefs`
            // already answers the right thing for both zero-ref shapes
            // (`["HEAD"]` for detached, `[]` for actually unborn).
            guard !liveRefs.isEmpty else {
                return .refs(try await autoRefs(location: location, liveRefs: liveRefs))
            }
            return .all
        case .refs(let names):
            return .refs(names.filter(isSafeRefArgument))
        }
    }

    /// Commit history for an already-resolved repository and ref scope --
    /// no `autoRefs`/`refList` resolution happens here at all, so a caller
    /// that already resolved `selection` (via `resolvedRefScope`) never
    /// triggers it a second time.
    static func commitLog(
        location: GitRepositoryLocation,
        resolvedScope: GitResolvedRefScope,
        maxCount: Int,
        skip: Int
    ) async throws -> [GitCommit] {
        var refArgs: [String]
        switch resolvedScope {
        case .all:
            refArgs = ["--all"]
        case .refs(let names):
            refArgs = names
            // A ref name that also names a path in the work tree (a branch
            // called "docs", say, next to a "docs" directory) is ambiguous
            // to `git log` unless something marks where revisions end and
            // paths begin; `--all` needs no such marker, since it can never
            // be mistaken for a path.
            if !refArgs.isEmpty {
                refArgs.append("--")
            }
        }
        guard !refArgs.isEmpty else { return [] }

        let format = "%x1f%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%P%x1f%D%x1e"
        let args = ["log", "--graph", "--format=\(format)",
                    "--max-count=\(maxCount)", "--skip=\(skip)"] + refArgs

        let output = try await run(args: args, workDir: location.workTree)
        return parseCommitLog(output)
    }

    /// Commit history for an already-resolved repository, scoped by
    /// `selection`, skipping the `rev-parse` that
    /// `commitLog(workDir:selection:maxCount:skip:)` needs to resolve it.
    /// `.auto` and `.all` each need `liveRefs` to resolve (see
    /// `resolvedRefScope`), fetched here with exactly one `refList` call;
    /// `.refs` needs no such fetch and gets none. A caller that already
    /// has `liveRefs` for some other reason should call
    /// `resolvedRefScope`/`commitLog(resolvedScope:)` directly instead of
    /// this method, to avoid fetching them twice.
    static func commitLog(
        location: GitRepositoryLocation,
        selection: GitRefSelection,
        maxCount: Int,
        skip: Int
    ) async throws -> [GitCommit] {
        let resolvedScope: GitResolvedRefScope
        switch selection {
        case .auto, .all:
            let liveRefs = try await refList(location: location)
            resolvedScope = try await resolvedRefScope(location: location, selection: selection, liveRefs: liveRefs)
        case .refs(let names):
            resolvedScope = .refs(names.filter(isSafeRefArgument))
        }
        return try await commitLog(location: location, resolvedScope: resolvedScope, maxCount: maxCount, skip: skip)
    }

    static func commitLog(
        workDir: String,
        selection: GitRefSelection,
        maxCount: Int,
        skip: Int
    ) async throws -> [GitCommit] {
        let location = try await repositoryLocation(workDir: workDir)
        return try await commitLog(location: location, selection: selection, maxCount: maxCount, skip: skip)
    }

    /// The VSCode-equivalent "Auto" starting point for a repository's
    /// history: HEAD, its upstream, and the upstream's remote's default
    /// branch, each added only once and only when it names a ref the
    /// earlier ones did not already name. An unborn HEAD names nothing to
    /// log from, so it yields no refs at all rather than falling back to
    /// something else. Fetches its own `refList` to validate the upstream
    /// and base against (see the `liveRefs` overload for a caller that
    /// already has one).
    static func autoRefs(location: GitRepositoryLocation) async throws -> [String] {
        // Started together rather than one after the other: `refList` is
        // needed only in the `.normal` case below, but it costs nothing to
        // have its answer ready in parallel with `headSummary`'s rather
        // than waiting on it afterward.
        async let headResult = autoRefsHead(location: location)
        async let liveRefsResult = refList(location: location)
        switch try await headResult {
        case .unborn:
            return []
        case .detached:
            return ["HEAD"]
        case .normal(let branch):
            return try await autoRefs(branch: branch, location: location, liveRefs: liveRefsResult)
        }
    }

    /// `autoRefs`, validated against `liveRefs` -- a `refList` result the
    /// caller already has -- instead of fetching its own. HEAD's own
    /// branch ref needs no such validation: it comes from `headSummary`,
    /// which resolves it via `symbolic-ref`/`rev-parse --verify`, so by
    /// the time this is reached (past the unborn/detached cases) it is
    /// already known to exist.
    static func autoRefs(location: GitRepositoryLocation, liveRefs: [GitRefInfo]) async throws -> [String] {
        switch try await autoRefsHead(location: location) {
        case .unborn:
            return []
        case .detached:
            return ["HEAD"]
        case .normal(let branch):
            return try await autoRefs(branch: branch, location: location, liveRefs: liveRefs)
        }
    }

    /// What HEAD is, for the two `autoRefs` overloads above to share the
    /// unborn/detached handling that precedes needing `liveRefs` at all.
    private enum AutoRefsHead {
        case unborn
        case detached
        case normal(branch: String)
    }

    private static func autoRefsHead(location: GitRepositoryLocation) async throws -> AutoRefsHead {
        let head = try await headSummary(workDir: location.workTree)
        guard let branch = head.branch else {
            // No branch name: detached HEAD, with exactly one thing to log
            // from and no upstream or base to add to it.
            return .detached
        }
        guard head.shortHash != nil else {
            // A branch name but no commit yet: unborn, with nothing to
            // log from at all.
            return .unborn
        }
        return .normal(branch: branch)
    }

    /// The upstream/base resolution shared by both `autoRefs` overloads,
    /// once HEAD is known to be a normal branch with a commit.
    private static func autoRefs(
        branch: String,
        location: GitRepositoryLocation,
        liveRefs: [GitRefInfo]
    ) async throws -> [String] {
        var refs: [String] = ["refs/heads/\(branch)"]
        let liveNames = Set(liveRefs.map(\.fullName))

        // `%(upstream)` and `%(upstream:remotename)` in one call rather than
        // two: the remote name is what the base ref below is keyed on, and
        // deriving it by parsing `refs/remotes/<remote>/...` back out of the
        // upstream ref (as a second `for-each-ref` would otherwise require)
        // is exactly what this atom already answers directly.
        let upstreamInfo = try await runReportingNoAnswerAsNil(
            args: [
                "for-each-ref", "--format=%(upstream)\u{01}%(upstream:remotename)",
                "refs/heads/\(branch)",
            ],
            workDir: location.workTree
        )
        let upstreamFields = (upstreamInfo ?? "").components(separatedBy: "\u{01}")
        let upstreamRef = upstreamFields.first.flatMap { $0.isEmpty ? nil : $0 }
        let upstreamRemote = upstreamFields.count > 1 ? upstreamFields[1] : ""
        if let upstreamRef, liveNames.contains(upstreamRef), !refs.contains(upstreamRef) {
            refs.append(upstreamRef)
        }

        let remote = upstreamRemote.isEmpty ? "origin" : upstreamRemote
        let base = try await runReportingNoAnswerAsNil(
            args: ["symbolic-ref", "-q", "refs/remotes/\(remote)/HEAD"],
            workDir: location.workTree
        )
        if let base, !base.isEmpty, liveNames.contains(base), !refs.contains(base) {
            refs.append(base)
        }

        return refs
    }

    /// Every local branch, remote branch, and tag the repository has, for
    /// the ref picker's menu. `%(symref)` is non-empty only for a symbolic
    /// ref such as `refs/remotes/origin/HEAD`, which names a branch rather
    /// than being one, so those are excluded.
    static func refList(location: GitRepositoryLocation) async throws -> [GitRefInfo] {
        // `for-each-ref`'s format engine has no `%x01`-style hex-escape
        // atom the way `log --format` does; a literal control character
        // in the argument itself is what actually reaches it, since
        // `Process.arguments` bypasses the shell entirely. `for-each-ref`
        // appends a newline after every record on its own.
        let format = "%(refname)\u{01}%(refname:short)\u{01}%(symref)"
        let output = try await run(
            args: ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes", "refs/tags"],
            workDir: location.workTree
        )
        guard !output.isEmpty else { return [] }

        var refs: [GitRefInfo] = []
        for record in output.components(separatedBy: "\n") {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.components(separatedBy: "\u{01}")
            guard fields.count >= 3 else { continue }
            let fullName = fields[0]
            let shortName = fields[1]
            guard fields[2].isEmpty else { continue }

            let kind: GitRefInfo.Kind
            if fullName.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if fullName.hasPrefix("refs/remotes/") {
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                continue
            }
            refs.append(GitRefInfo(fullName: fullName, shortName: shortName, kind: kind))
        }
        return refs
    }

    /// Whether `ref` is safe to hand to `git log` as a positional revision
    /// argument. Only `HEAD` and a fully-qualified ref name are allowed --
    /// nothing that could be mistaken for an option (a leading `-`) and
    /// nothing carrying whitespace or control characters a shell-adjacent
    /// consumer might mis-split.
    static func isSafeRefArgument(_ ref: String) -> Bool {
        guard ref == "HEAD" || ref.hasPrefix("refs/") else { return false }
        guard !ref.hasPrefix("-") else { return false }
        return !ref.unicodeScalars.contains { $0 == " " || CharacterSet.controlCharacters.contains($0) }
    }

    static func commitFiles(hash: String, workDir: String) async throws -> [CommitFileEntry] {
        guard isValidRef(hash) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "diff-tree")
        }

        // Check if root commit (no parents)
        let parentCheck = try? await run(args: ["rev-parse", "\(hash)^"], workDir: workDir)
        let isRoot = parentCheck == nil

        var args: [String]
        if isRoot {
            args = ["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", hash]
        } else {
            args = ["diff-tree", "--no-commit-id", "-r", "--name-status", "-z", hash]
        }

        let output = try await run(args: args, workDir: workDir)
        return parseCommitFiles(output, commitHash: hash)
    }

    /// git arguments for a full-context diff of one file (the whole file is a
    /// single hunk, so both sides can be reconstructed). nil for untracked
    /// files, whose diff is synthesized from the file content.
    static func fileDiffArguments(for source: DiffSource) -> [String]? {
        let fullContext = "-U2147483647"
        switch source {
        case .unstaged(let path, _):
            return ["diff", fullContext, "--", path]
        case .staged(let path, _):
            return ["diff", "--cached", fullContext, "--", path]
        case .commit(let hash, let path, _):
            return ["show", "--format=", "--patch", fullContext, hash, "--", path]
        case .untracked:
            return nil
        }
    }

    static func fileDiff(source: DiffSource) async throws -> String {
        switch source {
        case .untracked(let path, let workDir):
            return try await untrackedFileDiff(path: path, workDir: workDir)
        case .commit(let hash, _, let workDir):
            guard isValidRef(hash) else {
                throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "show")
            }
            return try await runFileDiff(source: source, workDir: workDir)
        case .unstaged(_, let workDir), .staged(_, let workDir):
            return try await runFileDiff(source: source, workDir: workDir)
        }
    }

    private static func runFileDiff(source: DiffSource, workDir: String) async throws -> String {
        guard let args = fileDiffArguments(for: source) else {
            preconditionFailure("fileDiffArguments returns arguments for every tracked source")
        }
        return try await run(args: args, workDir: workDir)
    }

    /// Synthesize a unified diff for an untracked file by reading its content.
    private static func untrackedFileDiff(path: String, workDir: String) async throws -> String {
        let fullPath = (workDir as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: fullPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GitError.commandFailed(exitCode: -1, stderr: "Cannot read file: \(path)", command: "diff")
        }

        // Binary check: look for null bytes in first 8KB
        let checkSize = min(data.count, 8192)
        if data.prefix(checkSize).contains(0) {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        let lines = content.components(separatedBy: "\n")
        // Remove trailing empty element from split if file ends with newline
        let effectiveLines = lines.last == "" ? Array(lines.dropLast()) : lines
        let lineCount = effectiveLines.count

        var result = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        result += "@@ -0,0 +1,\(lineCount) @@\n"
        for line in effectiveLines {
            result += "+\(line)\n"
        }
        return result
    }

    // MARK: - Worktree Tasks

    /// The `branch.<name>.<key>` config key that marks a branch as a
    /// Calyx worktree task and records the branch it merges back into.
    static let worktreeTaskBaseConfigKey = "calyxbase"

    /// Whether `branch` is a valid new branch name:
    /// `git check-ref-format refs/heads/<branch>` (not `--branch`, which
    /// expands `@{-1}`). Empty names and names starting with `-` (which
    /// `check-ref-format` accepts as a path component but `git branch`
    /// / `worktree add -b` reject) are refused before calling git. A
    /// rejected name is a value here, not a failure.
    static func checkRefFormat(branch: String, workDir: String) async -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return false }
        do {
            _ = try await run(args: ["check-ref-format", "refs/heads/" + branch], workDir: workDir)
            return true
        } catch {
            return false
        }
    }

    /// Whether `refs/heads/<branch>` exists
    /// (`git rev-parse -q --verify`, which exits 1 when it does not).
    static func localBranchExists(_ branch: String, workDir: String) async throws -> Bool {
        try await runReportingNoAnswerAsNil(
            args: ["rev-parse", "-q", "--verify", "refs/heads/" + branch], workDir: workDir
        ) != nil
    }

    /// Whether a merge is in progress in the worktree at `workDir`
    /// (`git rev-parse -q --verify MERGE_HEAD`, exit 1 when absent).
    static func hasMergeInProgress(workDir: String) async throws -> Bool {
        try await runReportingNoAnswerAsNil(
            args: ["rev-parse", "-q", "--verify", "MERGE_HEAD"], workDir: workDir
        ) != nil
    }

    /// `git worktree add -b <newBranch> <path> refs/heads/<base>`. `base`
    /// is a local branch name; the full ref keeps a tag of the same name
    /// (which git's revision lookup prefers) from being the start point.
    static func worktreeAdd(path: String, newBranch: String, base: String, workDir: String) async throws {
        _ = try await runMutating(args: ["worktree", "add", "-b", newBranch, path, "refs/heads/" + base], workDir: workDir)
    }

    /// `git config branch.<branch>.<key> <value>`.
    static func setBranchConfig(branch: String, key: String, value: String, workDir: String) async throws {
        _ = try await runMutating(args: ["config", "branch.\(branch).\(key)", value], workDir: workDir)
    }

    /// `git config --get branch.<branch>.<key>`, or nil when unset
    /// (`config --get` exits 1 for a missing key).
    static func getBranchConfig(branch: String, key: String, workDir: String) async throws -> String? {
        try await runReportingNoAnswerAsNil(args: ["config", "--get", "branch.\(branch).\(key)"], workDir: workDir)
    }

    /// Whether `git status` reports nothing. Untracked files count as
    /// dirty: `worktree remove` refuses them too.
    static func isWorkingTreeClean(workDir: String) async throws -> Bool {
        try await gitStatus(workDir: workDir).isEmpty
    }

    /// `git merge --no-ff --no-edit refs/heads/<branch>` into the branch
    /// checked out at `workDir`.
    static func merge(branch: String, workDir: String) async throws {
        // The full ref: a tag named like the branch would otherwise win
        // git's revision lookup.
        _ = try await runMutating(args: ["merge", "--no-ff", "--no-edit", "refs/heads/" + branch], workDir: workDir)
    }

    /// `git merge --abort`. Best-effort cleanup after a failed merge: when
    /// no merge is in progress git exits non-zero, which is the expected
    /// no-op, so errors are ignored by design.
    static func mergeAbort(workDir: String) async {
        _ = try? await runMutating(args: ["merge", "--abort"], workDir: workDir)
    }

    /// `git worktree remove [--force] <path>`.
    static func worktreeRemove(path: String, force: Bool, workDir: String) async throws {
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + [path]
        _ = try await runMutating(args: args, workDir: workDir)
    }

    /// `git branch -d|-D <branch>`.
    static func branchDelete(branch: String, force: Bool, workDir: String) async throws {
        _ = try await runMutating(args: ["branch", force ? "-D" : "-d", branch], workDir: workDir)
    }

    // MARK: - Process Execution

    /// PATH for spawned git processes. Includes `/opt/homebrew/bin` so
    /// Homebrew-installed helpers (git-lfs, hook tools) resolve on Apple
    /// Silicon.
    static let gitProcessPATH = "/usr/bin:/usr/local/bin:/opt/homebrew/bin"

    /// Every read-only entry point above (`repoRoot`, `gitStatus`,
    /// `commitLog`, `commitFiles`, `fileDiff`) drives this with a
    /// read-only git subcommand (`status`, `log`, `diff-tree`, `diff`,
    /// `show`, `rev-parse`). Write operations go through `runMutating`
    /// instead, never through here, so
    /// propagating cancellation straight to the subprocess (rather than
    /// the structural-shield treatment `SessionDaemonClient.kill(id:)`
    /// needs for its WRITE op) is safe.
    private static func run(args: [String], workDir: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw GitError.gitNotFound
        }

        let cancellationBridge = ProcessCancellationBridge()
        // Mirrors SystemCommandRunner
        // .runInternal -- withTaskCancellationHandler makes
        // a caller's Task cancellation SIGTERM the spawned `git`
        // process promptly instead of leaving it running until it
        // exits naturally or the unrelated 10s watchdog eventually
        // trips.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: gitPath)
                    process.arguments = args
                    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                    process.environment = [
                        "LC_ALL": "C",
                        "GIT_PAGER": "cat",
                        "GIT_TERMINAL_PROMPT": "0",
                        "GIT_OPTIONAL_LOCKS": "0",
                        "PATH": gitProcessPATH,
                        "HOME": NSHomeDirectory(),
                    ]

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    if cancellationBridge.register(process) {
                        // Already cancelled by the time this process
                        // launched; `cancel()` found nothing registered
                        // yet, so terminate it here instead, through the
                        // same terminate-once lock rather than a second,
                        // unsynchronized `process.terminate()` call site.
                        cancellationBridge.terminate()
                    }

                    var didTimeout = false
                    let timeoutItem = DispatchWorkItem {
                        didTimeout = true
                        cancellationBridge.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

                    // Read both pipes concurrently to avoid deadlock
                    let stdoutBox = OSAllocatedUnfairLock(initialState: Data())
                    let stderrBox = OSAllocatedUnfairLock(initialState: Data())
                    let readGroup = DispatchGroup()
                    readGroup.enter()
                    DispatchQueue.global().async {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        stdoutBox.withLock { $0 = data }
                        readGroup.leave()
                    }
                    readGroup.enter()
                    DispatchQueue.global().async {
                        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        stderrBox.withLock { $0 = data }
                        readGroup.leave()
                    }
                    readGroup.wait()
                    let stdoutData = stdoutBox.withLock { $0 }
                    let stderrData = stderrBox.withLock { $0 }

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()

                    if didTimeout {
                        let cmd = args.first ?? "unknown"
                        continuation.resume(throwing: GitError.timeout(command: cmd))
                        return
                    }

                    let exitCode = process.terminationStatus
                    if exitCode != 0 {
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        let cmd = args.first ?? "unknown"

                        if stderr.contains("not a git repository") {
                            continuation.resume(throwing: GitError.notARepository)
                            return
                        }
                        if stderr.contains("Permission denied") {
                            continuation.resume(throwing: GitError.permissionDenied(path: workDir))
                            return
                        }

                        continuation.resume(throwing: GitError.commandFailed(exitCode: exitCode, stderr: stderr, command: cmd))
                        return
                    }

                    let result = String(data: stdoutData, encoding: .utf8) ?? ""
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationBridge.cancel()
        }
    }

    /// The write path: runs a git subcommand that changes the repository
    /// (`worktree add`, `merge`, `branch -d`, `config`, ...). Same
    /// environment, pipes and exit-code mapping as `run`, but with two
    /// deliberate differences:
    ///
    /// - Task cancellation is NOT propagated to the subprocess. SIGTERM
    ///   in the middle of a merge or a worktree removal would leave the
    ///   repository half-written (a stray MERGE_HEAD, a worktree directory
    ///   without its admin entry), which is worse than letting the
    ///   command finish. A cancelled caller simply receives the result.
    /// - The watchdog is `timeoutSeconds` (60 s by default) rather than
    ///   10 s: checking out a large worktree legitimately takes longer
    ///   than any read query. The watchdog still terminates a hung git
    ///   so the caller is not blocked forever.
    static func runMutating(
        args: [String],
        workDir: String,
        timeoutSeconds: Int = 60
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw GitError.gitNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                process.environment = [
                    "LC_ALL": "C",
                    "GIT_PAGER": "cat",
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_OPTIONAL_LOCKS": "0",
                    "PATH": gitProcessPATH,
                    "HOME": NSHomeDirectory(),
                ]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let didTimeout = OSAllocatedUnfairLock(initialState: false)
                let timeoutItem = DispatchWorkItem {
                    didTimeout.withLock { $0 = true }
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem
                )

                let stdoutBox = OSAllocatedUnfairLock(initialState: Data())
                let stderrBox = OSAllocatedUnfairLock(initialState: Data())
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global().async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    stdoutBox.withLock { $0 = data }
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrBox.withLock { $0 = data }
                    readGroup.leave()
                }
                readGroup.wait()
                let stdoutData = stdoutBox.withLock { $0 }
                let stderrData = stderrBox.withLock { $0 }

                process.waitUntilExit()
                timeoutItem.cancel()

                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()

                let cmd = args.first ?? "unknown"
                if didTimeout.withLock({ $0 }) {
                    continuation.resume(throwing: GitError.timeout(command: cmd))
                    return
                }

                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    if stderr.contains("not a git repository") {
                        continuation.resume(throwing: GitError.notARepository)
                        return
                    }
                    if stderr.contains("Permission denied") {
                        continuation.resume(throwing: GitError.permissionDenied(path: workDir))
                        return
                    }
                    continuation.resume(throwing: GitError.commandFailed(exitCode: exitCode, stderr: stderr, command: cmd))
                    return
                }

                continuation.resume(returning: String(data: stdoutData, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Parsers

    static func parseStatus(_ output: String) -> [GitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [GitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0

        while i < parts.count {
            let part = String(parts[i])
            guard !part.isEmpty else { i += 1; continue }

            let firstChar = part.first!

            if firstChar == "?" {
                let path = String(part.dropFirst(2))
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .untracked, isStaged: false, renameScore: nil
                ))
                i += 1
            } else if firstChar == "!" {
                i += 1
            } else if firstChar == "1" {
                let fields = part.split(separator: " ", maxSplits: 8)
                guard fields.count >= 9 else { i += 1; continue }
                let xy = String(fields[1])
                let path = String(fields[8])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                if xChar != "." {
                    if let status = mapStatusChar(xChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: true, renameScore: nil
                        ))
                    }
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
                i += 1
            } else if firstChar == "2" {
                let fields = part.split(separator: " ", maxSplits: 9)
                guard fields.count >= 10 else { i += 1; continue }
                let xy = String(fields[1])
                let scoreField = String(fields[8])
                let path = String(fields[9])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                let scoreChar = scoreField.first ?? "R"
                let score = Int(scoreField.dropFirst())

                var origPath: String? = nil
                if i + 1 < parts.count {
                    origPath = String(parts[i + 1])
                    i += 2
                } else {
                    i += 1
                }

                if xChar != "." {
                    let status: GitFileStatus = scoreChar == "C" ? .copied : .renamed
                    entries.append(GitFileEntry(
                        path: path, origPath: origPath,
                        status: status, isStaged: true, renameScore: score
                    ))
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: origPath,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
            } else if firstChar == "u" {
                let fields = part.split(separator: " ", maxSplits: 10)
                guard fields.count >= 11 else { i += 1; continue }
                let path = String(fields[10])
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .unmerged, isStaged: false, renameScore: nil
                ))
                i += 1
            } else {
                i += 1
            }
        }

        return entries
    }

    /// Maps `git worktree list --porcelain -z` output onto records. Each
    /// NUL-terminated element carries one attribute, label and value split
    /// by a single space, and an empty element ends a record. Lock and
    /// prune reasons are raw strings that may contain spaces and newlines.
    static func parseWorktreeList(_ output: String) -> [GitWorktreeInfo] {
        var infos: [GitWorktreeInfo] = []
        var record = WorktreeRecord()
        var isRecordOpen = false

        for element in output.split(separator: "\0", omittingEmptySubsequences: false) {
            guard !element.isEmpty else {
                if isRecordOpen {
                    if let info = record.info { infos.append(info) }
                    record = WorktreeRecord()
                    isRecordOpen = false
                }
                continue
            }

            let fields = element.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let label = String(fields[0])
            let value = fields.count > 1 ? String(fields[1]) : nil

            guard isRecordOpen else {
                isRecordOpen = true
                // `worktree` opens every record; anything else means this
                // record is not one the schema describes, so it is dropped
                // by leaving `path` unset.
                if label == "worktree" { record.path = value }
                continue
            }
            guard record.path != nil else { continue }

            switch label {
            case "HEAD": record.headOID = value
            case "branch": record.branchRef = value
            case "detached": record.isDetached = true
            case "bare": record.isBare = true
            case "locked":
                record.isLocked = true
                record.lockReason = value
            case "prunable":
                record.isPrunable = true
                record.prunableReason = value
            default: break
            }
        }

        if isRecordOpen, let info = record.info {
            infos.append(info)
        }
        return infos
    }

    private struct WorktreeRecord {
        var path: String?
        var headOID: String?
        var branchRef: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        var info: GitWorktreeInfo? {
            guard let path else { return nil }
            return GitWorktreeInfo(
                path: path,
                headOID: headOID,
                branchRef: branchRef,
                isDetached: isDetached,
                isBare: isBare,
                isLocked: isLocked,
                lockReason: lockReason,
                isPrunable: isPrunable,
                prunableReason: prunableReason
            )
        }
    }

    static func parseCommitLog(_ output: String) -> [GitCommit] {
        guard !output.isEmpty else { return [] }

        var commits: [GitCommit] = []
        let lines = output.components(separatedBy: "\n")
        var accumulatedGraphPrefix = ""
        var accumulatedData = ""

        for line in lines {
            var graphPart = ""
            var dataPart = ""
            var foundData = false

            for char in line {
                if !foundData {
                    if char == "\u{1F}" || char == "\u{1E}" {
                        foundData = true
                        dataPart.append(char)
                    } else if "|*/\\ -_.".contains(char) {
                        graphPart.append(char)
                    } else {
                        graphPart.append(char)
                    }
                } else {
                    dataPart.append(char)
                }
            }

            accumulatedData += dataPart
            if accumulatedGraphPrefix.isEmpty || graphPart.contains("*") {
                accumulatedGraphPrefix = graphPart
            }

            if accumulatedData.contains("\u{1E}") {
                let records = accumulatedData.components(separatedBy: "\u{1E}")
                for record in records {
                    let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let fields = trimmed.components(separatedBy: "\u{1F}")
                    // Fields: ["", hash, shortHash, message, author, relativeDate, parents, decoration]
                    // First field is empty because record starts with \x1f
                    guard fields.count >= 6 else { continue }
                    let hash = fields[1]
                    let shortHash = fields[2]
                    let message = fields[3]
                    let author = fields[4]
                    let relativeDate = fields[5]
                    let parentIDsStr = fields.count > 6 ? fields[6] : ""
                    let parentIDs = parentIDsStr.isEmpty ? [] : parentIDsStr.split(separator: " ").map(String.init)
                    let decoration = fields.count > 7 ? fields[7] : ""
                    let refNames = parseRefNames(decoration)

                    commits.append(GitCommit(
                        id: hash,
                        shortHash: shortHash,
                        message: message,
                        author: author,
                        relativeDate: relativeDate,
                        parentIDs: parentIDs,
                        graphPrefix: accumulatedGraphPrefix,
                        refNames: refNames
                    ))
                }
                accumulatedData = ""
                accumulatedGraphPrefix = ""
            }
        }

        return commits
    }

    /// `%D`'s decoration string into the names it lists: a comma-and-space
    /// separated list where the current branch is spelled `HEAD -> name`
    /// (arrow stripped down to the branch name), a tag is spelled `tag:
    /// name` (prefix stripped), and a bare `HEAD` (detached) is kept as-is.
    static func parseRefNames(_ decoration: String) -> [String] {
        guard !decoration.isEmpty else { return [] }

        var seenNames: Set<String> = []
        var names: [String] = []
        for entry in decoration.components(separatedBy: ", ") {
            let name: String
            if entry.hasPrefix("HEAD -> ") {
                name = String(entry.dropFirst("HEAD -> ".count))
            } else if entry.hasPrefix("tag: ") {
                name = String(entry.dropFirst("tag: ".count))
            } else {
                name = entry
            }
            // A remote's `<remote>/HEAD` names its default-branch pointer,
            // not a ref a user picks -- `refList` excludes that same symref
            // from the ref picker's menu for the same reason. A bare "HEAD"
            // (detached) is a real answer and is not excluded by this.
            guard name == "HEAD" || !name.hasSuffix("/HEAD") else { continue }
            // `HEAD -> main` and a `tag: main` both display as "main"; showing
            // it twice would tell the user nothing a single badge doesn't.
            guard seenNames.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    static func parseCommitFiles(_ output: String, commitHash: String) -> [CommitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [CommitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < parts.count {
            let part = parts[i]
            guard !part.isEmpty else { i += 1; continue }

            let statusChar = part.first!

            switch statusChar {
            case "M", "A", "D", "T":
                if i + 1 < parts.count {
                    let path = parts[i + 1]
                    if let status = GitFileStatus(rawValue: String(statusChar)) {
                        entries.append(CommitFileEntry(
                            commitHash: commitHash, path: path,
                            origPath: nil, status: status
                        ))
                    }
                    i += 2
                } else {
                    i += 1
                }
            case "R", "C":
                if i + 2 < parts.count {
                    let origPath = parts[i + 1]
                    let newPath = parts[i + 2]
                    let status: GitFileStatus = statusChar == "R" ? .renamed : .copied
                    entries.append(CommitFileEntry(
                        commitHash: commitHash, path: newPath,
                        origPath: origPath, status: status
                    ))
                    i += 3
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }

        return entries
    }

    private static func isValidRef(_ ref: String) -> Bool {
        let pattern = /^[0-9a-fA-F]{4,40}$/
        return ref.wholeMatch(of: pattern) != nil
    }

    private static func mapStatusChar(_ char: Character) -> GitFileStatus? {
        switch char {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: nil
        }
    }
}
