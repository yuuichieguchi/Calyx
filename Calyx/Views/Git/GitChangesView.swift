// GitChangesView.swift
// Calyx
//
// SwiftUI sidebar content for git changes display.

import SwiftUI

struct GitChangesView: View {
    let gitChangesState: GitChangesState
    let gitEntries: [GitFileEntry]
    let gitCommits: [GitCommit]
    let expandedCommitIDs: Set<String>
    let commitFiles: [String: [CommitFileEntry]]

    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefresh: (() -> Void)?
    var onLoadMore: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer()
                Button(action: { onRefresh?() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Git.refreshButton)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            switch gitChangesState {
            case .notLoaded, .loading:
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            case .notRepository:
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Not a git repository")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { onRefresh?() }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        workingChangesSection
                        commitGraphSection
                    }
                }
            }
        }
        .frame(minWidth: 180)
        .accessibilityIdentifier(AccessibilityID.Git.changesContainer)
    }

    // MARK: - Working Changes

    @ViewBuilder
    private var workingChangesSection: some View {
        let staged = gitEntries.filter { $0.isStaged }
        let unstaged = gitEntries.filter { !$0.isStaged && $0.status != .untracked }
        let untracked = gitEntries.filter { $0.status == .untracked }

        if !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !staged.isEmpty {
                    DisclosureGroup {
                        ForEach(staged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Staged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(staged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.stagedSection)
                }

                if !unstaged.isEmpty {
                    DisclosureGroup {
                        ForEach(unstaged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Unstaged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(unstaged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.unstagedSection)
                }

                if !untracked.isEmpty {
                    DisclosureGroup {
                        ForEach(untracked) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Untracked")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(untracked.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.untrackedSection)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Commit Graph

    @ViewBuilder
    private var commitGraphSection: some View {
        if !gitCommits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Commits")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier(AccessibilityID.Git.commitsSection)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(gitCommits) { commit in
                        CommitRowView(
                            commit: commit,
                            isExpanded: expandedCommitIDs.contains(commit.id),
                            files: commitFiles[commit.id] ?? [],
                            onTap: { onExpandCommit?(commit.id) },
                            onFileSelected: { file in onCommitFileSelected?(file) }
                        )
                        .accessibilityIdentifier(AccessibilityID.Git.commitRow(commit.shortHash))
                    }

                    Color.clear
                        .frame(height: 1)
                        .onAppear { onLoadMore?() }
                }
            }
        }
    }
}

// MARK: - Git File Row

private struct GitFileRow: View {
    let entry: GitFileEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.status.rawValue)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(fileName)
                .font(.caption)
                .lineLimit(1)

            if let dir = directory {
                Text(dir)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.Git.fileEntry(entry.path))
    }

    private var fileName: String {
        (entry.path as NSString).lastPathComponent
    }

    private var directory: String? {
        let dir = (entry.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    private var statusColor: Color {
        switch entry.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .copied: .blue
        case .untracked: .gray
        case .unmerged: .purple
        case .typeChanged: .yellow
        }
    }
}

// MARK: - Commit Row

private struct CommitRowView: View {
    let commit: GitCommit
    let isExpanded: Bool
    let files: [CommitFileEntry]
    var onTap: (() -> Void)?
    var onFileSelected: ((CommitFileEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { onTap?() }) {
                HStack(alignment: .top, spacing: 4) {
                    GraphPrefixView(prefix: commit.graphPrefix)
                        .frame(width: graphWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(commit.shortHash)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(commit.message)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Text(commit.author)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(commit.relativeDate)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(files) { file in
                    CommitFileRow(file: file)
                        .onTapGesture { onFileSelected?(file) }
                }
            }
        }
    }

    private var graphWidth: CGFloat {
        max(CGFloat(commit.graphPrefix.count) * 8, 16)
    }
}

private struct GraphPrefixView: View {
    let prefix: String

    var body: some View {
        Text(AttributedString(CommitGraphRenderer.attributedString(from: CommitGraphRenderer.parse(prefix))))
    }
}

private struct CommitFileRow: View {
    let file: CommitFileEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text((file.path as NSString).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.Git.fileEntry(file.path))
    }

    private var statusColor: Color {
        switch file.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .untracked: .gray
        case .unmerged: .purple
        case .typeChanged: .yellow
        }
    }
}
