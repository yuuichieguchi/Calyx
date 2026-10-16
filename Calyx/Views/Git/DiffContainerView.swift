// DiffContainerView.swift
// Calyx
//
// Toolbar shown above the diff viewer.

import SwiftUI

struct DiffToolbarView: View {
    let source: DiffSource
    var reviewStore: DiffReviewStore?
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var totalReviewCommentCount: Int = 0
    var reviewFileCount: Int = 0
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    /// Number of changes of the loaded diff (0 while loading / on error).
    var changeCount: Int = 0
    var onGoToChange: ((DiffChangeNavigator.Direction) -> Void)?

    @State private var layoutPreference = DiffLayoutSettings.preference
    @State private var hideUnchangedRegions = DiffLayoutSettings.hideUnchangedRegionsEnabled
    @State private var ignoreTrimWhitespace = DiffLayoutSettings.ignoreTrimWhitespace
    @State private var wordWrap = DiffLayoutSettings.wordWrap

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text(filePath)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            switch source {
            case .staged:
                Text("staged")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.2)))
                    .foregroundStyle(.green)
            case .unstaged:
                Text("unstaged")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            case .commit(let hash, _, _):
                Text(String(hash.prefix(7)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .untracked:
                Text("untracked")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.2)))
                    .foregroundStyle(.blue)
            }

            // Review buttons (only shown when comments exist)
            if let store = reviewStore, store.hasUnsubmittedComments {
                Text("\(store.comments.count) comments")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.2)))
                    .foregroundStyle(.blue)
                    .accessibilityIdentifier(AccessibilityID.DiffReview.commentBadge)

                Button("Submit Review") {
                    onSubmitReview?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.DiffReview.submitButton)

                if reviewFileCount >= 2 {
                    Button("Submit All (\(totalReviewCommentCount) in \(reviewFileCount) files)") {
                        onSubmitAllReviews?()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.DiffReview.submitAllButton)
                }

                Button("Discard") {
                    onDiscardReview?()
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.DiffReview.discardButton)

                if reviewFileCount >= 2 {
                    Button("Discard All") {
                        onDiscardAllReviews?()
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityID.DiffReview.discardAllButton)
                }
            }

            changeNavigationButtons

            moreActionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Diff.toolbar)
    }

    /// VS Code's diff editor title Previous / Next Change actions.
    private var changeNavigationButtons: some View {
        HStack(spacing: 4) {
            Button {
                onGoToChange?(.previous)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Go to Previous Change")
            .accessibilityLabel("Go to Previous Change")
            .accessibilityIdentifier(AccessibilityID.Diff.previousChangeButton)
            Button {
                onGoToChange?(.next)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Go to Next Change")
            .accessibilityLabel("Go to Next Change")
            .accessibilityIdentifier(AccessibilityID.Diff.nextChangeButton)
        }
        .buttonStyle(.borderless)
        .disabled(changeCount == 0)
    }

    /// "…" menu: diff layout, collapse unchanged regions, ignore trim
    /// whitespace. Writes go to `DiffLayoutSettings`; the notification
    /// re-reads them so the checkmarks follow the palette / Settings.
    private var moreActionsMenu: some View {
        Menu {
            Menu("Diff View") {
                Picker("Diff View", selection: $layoutPreference) {
                    ForEach(DiffLayoutPreference.allCases, id: \.self) { pref in
                        Text(pref.displayName)
                            .tag(pref)
                            .accessibilityIdentifier(AccessibilityID.Diff.layoutMenuItem(pref))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Toggle("Collapse Unchanged Regions", isOn: $hideUnchangedRegions)
                .accessibilityIdentifier(AccessibilityID.Diff.collapseUnchangedItem)
            Toggle("Ignore Trim Whitespace", isOn: $ignoreTrimWhitespace)
                .accessibilityIdentifier(AccessibilityID.Diff.ignoreTrimWhitespaceItem)
            Toggle("Word Wrap", isOn: $wordWrap)
                .accessibilityIdentifier(AccessibilityID.Diff.wordWrapItem)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.Diff.moreActionsButton)
        .onChange(of: layoutPreference) { _, newValue in
            if DiffLayoutSettings.preference != newValue {
                DiffLayoutSettings.preference = newValue
            }
        }
        .onChange(of: hideUnchangedRegions) { _, newValue in
            if DiffLayoutSettings.hideUnchangedRegionsEnabled != newValue {
                DiffLayoutSettings.hideUnchangedRegionsEnabled = newValue
            }
        }
        .onChange(of: ignoreTrimWhitespace) { _, newValue in
            if DiffLayoutSettings.ignoreTrimWhitespace != newValue {
                DiffLayoutSettings.ignoreTrimWhitespace = newValue
            }
        }
        .onChange(of: wordWrap) { _, newValue in
            if DiffLayoutSettings.wordWrap != newValue {
                DiffLayoutSettings.wordWrap = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diffLayoutSettingChanged)) { _ in
            layoutPreference = DiffLayoutSettings.preference
            hideUnchangedRegions = DiffLayoutSettings.hideUnchangedRegionsEnabled
            ignoreTrimWhitespace = DiffLayoutSettings.ignoreTrimWhitespace
            wordWrap = DiffLayoutSettings.wordWrap
        }
    }

    private var filePath: String {
        switch source {
        case .unstaged(let path, _): path
        case .staged(let path, _): path
        case .commit(_, let path, _): path
        case .untracked(let path, _): path
        }
    }
}

extension DiffLoadState {
    /// Number of changes of a loaded diff; 0 while loading or on error.
    var changeCount: Int {
        if case .success(let diff) = self { return diff.changes.count }
        return 0
    }
}
