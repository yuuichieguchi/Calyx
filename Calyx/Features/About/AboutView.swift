import SwiftUI

/// Calyx's own About window contents, modeled on Ghostty's
/// `macos/Sources/Features/About/AboutView.swift`: app icon, name,
/// Version/Build/Commit rows, then Docs/GitHub buttons.
///
/// Every row is `if let`-gated on its own `Info.plist` key, so a build
/// missing one (e.g. `CalyxCommit`, injected by project.yml's "Stamp
/// Git Commit" post-build script and therefore absent from any build
/// made outside a git checkout) simply drops that row instead of
/// rendering an empty one.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    static let githubURL = URL(string: "https://github.com/yuuichieguchi/Calyx")
    static let docsURL = URL(string: "https://help.getcalyx.app/")

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["CalyxCommit"] as? String }

    /// Matches the "About This Mac" style backdrop Ghostty's own About
    /// window uses (its `AboutView.VisualEffectBackground`).
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = .behindWindow
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Calyx")
                        .bold()
                        .font(.title)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        PropertyRow(label: "Version", text: version)
                    }
                    if let build {
                        PropertyRow(label: "Build", text: build)
                    }
                    // Mirrors Ghostty: the commit hash doubles as a link
                    // to that exact commit on GitHub.
                    if let commit, !commit.isEmpty,
                       let url = Self.githubURL?.appendingPathComponent("commits").appendingPathComponent(commit) {
                        PropertyRow(label: "Commit", text: commit, url: url)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = Self.docsURL {
                        Button("Docs") { openURL(url) }
                    }
                    if let url = Self.githubURL {
                        Button("GitHub") { openURL(url) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        // 300, not Ghostty's own `minWidth: 256`: Ghostty hosts this view
        // as a plain `contentView` inside a 300pt-wide xib window, so 300
        // is the width its About actually renders at. Calyx has no xib and
        // sizes the window from the hosted view instead
        // (`contentViewController`), so the same 300 has to come from here
        // -- at 256 the PropertyRows' own fixed label/value widths
        // (126 + 125) would overflow the window.
        .frame(minWidth: 300)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }

    /// A right-aligned label next to its monospaced value, optionally
    /// wrapped in a `Link` (the Commit row).
    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            // No `.tint` here: it's a no-op on plain `Text` foreground
            // color, so it never affected this row's rendered color.
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) { textView }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}
