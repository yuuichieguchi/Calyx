// DiffContainerView.swift
// Calyx
//
// SwiftUI wrapper for the diff viewer with toolbar.

import SwiftUI

struct DiffContainerView: View {
    let source: DiffSource
    let loadState: DiffLoadState

    var body: some View {
        VStack(spacing: 0) {
            DiffToolbarView(source: source)

            switch loadState {
            case .loading:
                VStack {
                    Spacer()
                    ProgressView("Loading diff...")
                    Spacer()
                }
            case .success(let diff):
                DiffViewRepresentable(diff: diff)
                    .accessibilityIdentifier(AccessibilityID.Diff.content)
            case .error(let message):
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Diff.container)
    }
}

struct DiffToolbarView: View {
    let source: DiffSource
    var reviewStore: DiffReviewStore?
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?

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

                Button("Discard") {
                    onDiscardReview?()
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.DiffReview.discardButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.clear), in: .rect)
        .accessibilityIdentifier(AccessibilityID.Diff.toolbar)
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

struct DiffViewRepresentable: NSViewRepresentable {
    let diff: FileDiff
    var reviewStore: DiffReviewStore?

    func makeNSView(context: Context) -> DiffView {
        let view = DiffView(frame: .zero)
        view.reviewStore = reviewStore
        view.display(diff: diff)
        return view
    }

    func updateNSView(_ nsView: DiffView, context: Context) {
        nsView.reviewStore = reviewStore
        // Only re-render if diff changed
        if nsView.currentDiff != diff {
            nsView.display(diff: diff)
        }
    }
}