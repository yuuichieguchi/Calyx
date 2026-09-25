// AgentStatusView.swift
// Calyx
//
// Sidebar view that displays AI agent panes and their lifecycle state,
// sourced live from `AgentRegistry.shared`.

import AppKit
import SwiftUI

struct AgentStatusView: View {
    /// The rows block's rendered height, published by the
    /// `.onGeometryChange` modifier on the rows block in `content`.
    /// Read by `content` to give `monitoringDisabledPlaceholder` the
    /// viewport space left over below the rows to center itself in.
    /// Measured from the rendered view rather than derived from
    /// `entries.count` and a row-height constant, which would silently
    /// drift the moment row height, spacing, or padding change.
    @State private var rowsHeight: CGFloat = 0

    /// SurfaceIDs of parent rows currently disclosing their children.
    /// View-local, never persisted into `WindowSession` /
    /// `SessionSnapshot`: a child's own existence is never persisted
    /// either (`SubagentRegistry` holds it only as long as the CLI
    /// keeps reporting it), so there is nothing durable to key a
    /// persisted disclosure state to. Keyed by surfaceID rather than,
    /// say, row position, so a row's disclosure state stays with it
    /// when `sortedEntries` reorders rows on a state change.
    @State private var expandedParents: Set<UUID> = []

    /// Resolves the pane's own recorded title (`SurfacePropertyStore
    /// .title(for:)`, threaded down from `CalyxWindowController`), passed
    /// down to each `AgentRowView` for its primary label. Required, not
    /// defaulted: a host that forgets to wire this fails to build rather
    /// than silently rendering every row "N/A".
    var paneTitle: (UUID) -> String?
    /// Resolves the pane's own recorded cwd (`SurfacePropertyStore
    /// .cwd(for:)`, threaded down from `CalyxWindowController`), passed
    /// down to each `AgentRowView` for its cwd line. Required, not
    /// defaulted: a host that forgets to wire this fails to build rather
    /// than silently rendering every row's cwd line "N/A".
    var paneCwd: (UUID) -> String?

    var body: some View {
        content
            // Tracks how many windows currently have this view mounted
            // (Agents sidebar mode + sidebar visible) via
            // `AgentRegistry.agentsSidebarVisibleCount`, so
            // `CalyxWindowController`'s screen-classification poll can
            // gate on "visible in any window" rather than each window's
            // own local sidebar state -- see that property's doc comment.
            // This view has no part in the herdr connection: that is a
            // function of herdr's own presence
            // (`HerdrSessionPresence`), never of a view appearing.
            .onAppear {
                AgentRegistry.shared.incrementAgentsSidebarVisible()
            }
            .onDisappear { AgentRegistry.shared.decrementAgentsSidebarVisible() }
    }

    private var content: some View {
        Group {
            // Observes AgentRegistry.isServerRunning rather than
            // CalyxMCPServer.isRunning: CalyxMCPServer is a plain
            // @MainActor class, not @Observable, so a view reading its
            // isRunning directly would never get a re-render signal when
            // the server starts/stops. Also reads hasExternalEntries
            // (registering the @Observable dependency on externalEntries
            // too) so a herdr row appearing/disappearing while the IPC
            // server is stopped re-renders this gate on its own -- see
            // AgentSidebarGate.decide's doc comment. Both are captured
            // once here and reused below for
            // AgentSidebarGate.showsMonitoringDisabledBanner, decide's
            // companion -- see that function's own doc comment.
            let isServerRunning = AgentRegistry.shared.isServerRunning
            let hasExternal = AgentRegistry.shared.hasExternalEntries
            // Resolved once here and reused in both branches below: a
            // server-start failure must render its own banner whether
            // or not herdr rows keep the sidebar in the rows branch --
            // see AgentSidebarGate.showsServerIssuesBanner's own doc
            // comment.
            let serverIssues = AgentRegistry.shared.serverIssues
            let showsServerIssuesBanner = AgentSidebarGate.showsServerIssuesBanner(isServerRunning: isServerRunning, serverIssues: serverIssues)
            if !AgentSidebarGate.decide(isServerRunning: isServerRunning, hasExternal: hasExternal) {
                if showsServerIssuesBanner {
                    agentServerIssuesBanner(serverIssues)
                } else {
                    disabledPlaceholder
                }
            } else {
                let entries = AgentRegistry.shared.sortedEntries
                let integrationIssues = AgentRegistry.shared.integrationIssues
                VStack(spacing: 0) {
                    if showsServerIssuesBanner {
                        agentServerIssuesBanner(serverIssues)
                    }
                    if !integrationIssues.isEmpty {
                        hooksIssuesBanner(integrationIssues)
                    }
                    if entries.isEmpty {
                        emptyPlaceholder
                    } else {
                        // Wrapped in a GeometryReader purely to measure the
                        // viewport height for monitoringDisabledPlaceholder's
                        // centering below -- layout-neutral for the rows
                        // themselves, since ScrollView accepts whatever size
                        // is proposed and fills it exactly as it filled its
                        // parent before this was added. The per-row
                        // TimelineViews inside are likewise layout-transparent
                        // and each stops firing automatically while the
                        // sidebar isn't visible, so none of them costs
                        // anything while hidden.
                        GeometryReader { viewport in
                            ScrollView {
                                // A single VStack, not bare ScrollView
                                // siblings, so the scroll content's total
                                // height is exactly rowsHeight plus the
                                // placeholder block's own height -- no
                                // implicit, unmeasured inter-sibling
                                // spacing to throw off the minHeight math
                                // below.
                                VStack(spacing: 0) {
                                    // Keyed by surfaceID so a click on a
                                    // .external row (whose own
                                    // surfaceID is never a resolvable
                                    // SurfaceRegistry id) still resolves
                                    // a child's focus target through the
                                    // parent's own focusSurfaceID --
                                    // the same resolution AgentRowView
                                    // itself performs for the parent row.
                                    let entriesByID = Dictionary(
                                        entries.map { ($0.surfaceID, $0) }, uniquingKeysWith: { _, latest in latest }
                                    )
                                    VStack(spacing: 4) {
                                        ForEach(AgentSidebarRows.build(
                                            entries: entries,
                                            children: { AgentRegistry.shared.subagentRegistry.children(of: $0) },
                                            expanded: expandedParents
                                        )) { row in
                                            // Anchored to this row's own tickAnchor so the tick fires
                                            // exactly when the row's elapsed-time label would change;
                                            // any other phase leaves the label frozen one second short
                                            // of the true value for part of every second. Wraps the
                                            // whole row, not just its label Text, since
                                            // AgentSubRowView.helpText also depends on `now` and must
                                            // stay live while hovered.
                                            TimelineView(.periodic(from: row.tickAnchor, by: 1)) { context in
                                                switch row {
                                                case .parent(let entry, let childCount, let isExpanded):
                                                    AgentRowView(
                                                        entry: entry, now: context.date, paneTitle: paneTitle, paneCwd: paneCwd,
                                                        childCount: childCount, isExpanded: isExpanded,
                                                        onToggleExpanded: { toggleExpanded(entry.surfaceID) }
                                                    )
                                                case .child(let child):
                                                    // AgentSidebarRows.build only ever emits a .child
                                                    // row immediately after its own parent's .parent
                                                    // row, and that parent came from this same
                                                    // `entries` array, so this lookup always succeeds
                                                    // in practice -- the `if let` degrades to omitting
                                                    // the row rather than trapping should that ever
                                                    // not hold.
                                                    if let parent = entriesByID[child.parentSurfaceID] {
                                                        AgentSubRowView(
                                                            child: child, now: context.date,
                                                            focusTarget: AgentRowFocusTarget.resolve(
                                                                source: parent.source, surfaceID: parent.surfaceID, focusSurfaceID: parent.focusSurfaceID
                                                            )
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .onGeometryChange(for: CGFloat.self) { proxy in
                                        proxy.size.height
                                    } action: { height in
                                        rowsHeight = height
                                    }

                                    if AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: isServerRunning, hasExternal: hasExternal, serverIssues: serverIssues) && rowsHeight > 0 {
                                        monitoringDisabledPlaceholder(
                                            minHeight: max(0, (viewport.size.height - rowsHeight).rounded(.down) - 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Disclosure

    private func toggleExpanded(_ surfaceID: UUID) {
        if expandedParents.contains(surfaceID) {
            expandedParents.remove(surfaceID)
        } else {
            expandedParents.insert(surfaceID)
        }
    }

    // MARK: - Hooks Issues Banner

    /// Persistent warning banner surfacing agent integration failures
    /// (`AgentRegistry.integrationIssues`, the union of `configIssues`
    /// and `hooksIssues`, set by `IPCActivationCoordinator` and by
    /// `AppDelegate`'s launch-time hooks re-sync), so a symlink/
    /// permissions failure that used to degrade the sidebar silently
    /// (only a one-shot alert at enable time) is visible for as long as
    /// it remains unresolved.
    /// Rendered as plain, quiet text -- no icon, no background --
    /// matching `disabledPlaceholder` / `emptyPlaceholder` below rather
    /// than a designed warning box, so nothing opaque paints over
    /// `MainContentView`'s single root glass sheet showing through the
    /// sidebar.
    private func hooksIssuesBanner(_ issues: [String]) -> some View {
        issuesBanner(
            title: "Some agent integrations failed to install",
            issues: issues,
            accessibilityID: AccessibilityID.Sidebar.agentHooksIssuesBanner
        )
    }

    /// Shown instead of `disabledPlaceholder` when `AgentRegistry
    /// .serverIssues` is standing -- the setting is still ON, but the
    /// last enable attempt's server-start step itself failed (token
    /// generation or `CalyxMCPServer.start`), so telling the user to
    /// "Enable AI Agent IPC" would contradict the Settings switch, which
    /// already reads ON. See `AgentSidebarGate.showsServerIssuesBanner`.
    private func agentServerIssuesBanner(_ issues: [String]) -> some View {
        issuesBanner(
            title: "AI Agent IPC server failed to start",
            issues: issues,
            accessibilityID: AccessibilityID.Sidebar.agentServerIssuesBanner
        )
    }

    /// Shared look for `hooksIssuesBanner` and `agentServerIssuesBanner`:
    /// plain, quiet text -- no icon, no background -- matching
    /// `disabledPlaceholder` / `emptyPlaceholder` rather than a designed
    /// warning box, so nothing opaque paints over `MainContentView`'s
    /// single root glass sheet showing through the sidebar.
    private func issuesBanner(title: String, issues: [String], accessibilityID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(issues, id: \.self) { issue in
                Text(issue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - Placeholders

    private var disabledPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("AI Agent IPC is disabled")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Settings → Agents → Enable AI Agent IPC")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No agents connected yet.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    /// Same two lines, same typography, as `disabledPlaceholder` above
    /// (the fact is the same: AI Agent IPC is disabled) but shown below
    /// the rows rather than in place of them, for the case where herdr
    /// rows keep the sidebar showing rows even while Calyx's own IPC
    /// server is stopped. Gated by
    /// `AgentSidebarGate.showsMonitoringDisabledBanner`.
    ///
    /// `minHeight` is the viewport space left over below the rows
    /// (`content`'s `GeometryReader` minus the rows height measured by
    /// `.onGeometryChange`), so the block centers the way
    /// `emptyPlaceholder` centers in an empty list: few rows leave a lot
    /// of leftover space and the block sits in the middle of it; many
    /// rows leave none (`minHeight` clamped to 0) and the block just
    /// follows the rows with its own padding.
    ///
    /// The caller (`content`) rounds that leftover down and subtracts
    /// one more point, so the scroll content is always at least 1pt
    /// shorter than the viewport: fractional measurement can otherwise
    /// round `rowsHeight + minHeight` up past the viewport height by a
    /// hair, which is enough for `ScrollView` to draw a phantom
    /// scrollbar with nothing to actually scroll to. The caller also
    /// withholds this call entirely until `rowsHeight > 0` (the first
    /// real measurement has landed), since `rowsHeight`'s default `0`
    /// on the very first frame would otherwise read as "rows measure
    /// zero" and hand this a `minHeight` of the FULL viewport for one
    /// frame, forcing a scrollbar flash before the real measurement
    /// corrects it.
    private func monitoringDisabledPlaceholder(minHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Text("AI Agent IPC is disabled")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Settings → Agents → Enable AI Agent IPC")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight, alignment: .center)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentMonitoringDisabledBanner)
    }
}

// MARK: - Sidebar Gate

/// Pure decision behind `AgentStatusView.content`'s placeholder branch,
/// extracted so it's directly testable without mounting the view --
/// mirrors `HerdrChildExitedPolicy`'s own extraction shape: the caller
/// resolves its own inputs (`AgentRegistry.shared.isServerRunning` /
/// `.hasExternalEntries`) before calling in.
enum AgentSidebarGate {

    /// Whether the sidebar should render its entries list (`true`)
    /// rather than the "AI Agent IPC is disabled" placeholder
    /// (`false`). An external (herdr) row must keep the sidebar showing
    /// rows even while Calyx's own IPC server is stopped, since it
    /// doesn't depend on it -- so the placeholder is shown only when
    /// BOTH `isServerRunning` is `false` AND there are no external
    /// entries.
    static func decide(isServerRunning: Bool, hasExternal: Bool) -> Bool {
        isServerRunning || hasExternal
    }

    /// Companion to `decide(isServerRunning:hasExternal:)`: whether the
    /// rows branch should ALSO show `monitoringDisabledPlaceholder`, an
    /// explanatory notice that Calyx's own agent monitoring is disabled,
    /// rendered below the rows (not stacked at the top of the rows
    /// branch's `VStack` like `hooksIssuesBanner`) and centered in
    /// whatever viewport space is left over once the rows are measured
    /// -- see that view's own doc comment. Keeps the `...Banner` name
    /// here for API/test stability even though the gated view is named
    /// `monitoringDisabledPlaceholder` and matches `disabledPlaceholder`'s
    /// typography rather than `hooksIssuesBanner`'s.
    ///
    /// The old all-or-nothing gate was incoherent either way: hiding
    /// everything while herdr was connected threw away real, useful
    /// rows; showing rows with no indication was silently misleading,
    /// since a user's own locally-run agents (which DO depend on
    /// Calyx's own IPC server) would be missing from the list with no
    /// explanation. The coherent design shows the rows AND flags why
    /// Calyx's own agents might be absent -- so this is `true` only when
    /// Calyx's own server is off AND something else (herdr) is why rows
    /// are showing at all: `isServerRunning == true` never warns (Calyx's
    /// own monitoring IS running, herdr or not), and `hasExternal ==
    /// false` with the server off never reaches the rows branch to begin
    /// with (see `decide`).
    /// `serverIssues` suppresses this banner: a standing server-start
    /// failure already renders `agentServerIssuesBanner`, which states
    /// why Calyx's own agents are absent, so stacking the generic
    /// "disabled, open Settings" notice on top of it would both
    /// duplicate the explanation and contradict a Settings switch that
    /// still reads ON (a start failure is not the same state as the
    /// setting being off).
    static func showsMonitoringDisabledBanner(isServerRunning: Bool, hasExternal: Bool, serverIssues: [String]) -> Bool {
        !isServerRunning && hasExternal && serverIssues.isEmpty
    }

    /// Whether the sidebar should render `agentServerIssuesBanner`: a
    /// server-start failure (`AgentRegistry.serverIssues`) is standing
    /// while Calyx's own server is not running. Independent of `decide`
    /// and of `hasExternal`: a herdr row's presence must not hide a real
    /// server-start failure any more than its absence does. Applies in
    /// BOTH of `content`'s branches:
    /// the placeholder branch (no rows at all) and the rows branch (rows
    /// shown from herdr), so the caller renders this banner above
    /// `disabledPlaceholder`/rows in the former case and above
    /// `hooksIssuesBanner` in the latter.
    static func showsServerIssuesBanner(isServerRunning: Bool, serverIssues: [String]) -> Bool {
        !isServerRunning && !serverIssues.isEmpty
    }
}

// MARK: - Row Focus Target

/// Pure resolution of the surface a row's click should focus, extracted
/// from `AgentRowView.body` so it's directly testable without mounting
/// the view — mirrors `AgentSidebarGate` / `AgentRowDisplay`'s own
/// extraction shape. Not `@MainActor`: unlike `AgentRowDisplay` (which
/// calls into `AgentRegistry`, a `@MainActor` type), this touches only
/// plain `Sendable` values.
enum AgentRowFocusTarget {

    /// The surface to focus when a row is clicked, or `nil` when the row
    /// has no resolvable focus target at all — `AgentRowView` renders a
    /// `nil` result as a non-interactive row (no tap, no hover
    /// highlight) rather than posting `.calyxFocusSurface` for a surface
    /// nothing can resolve. Resolution order:
    ///   1. `focusSurfaceID`, when set, always wins — it is the explicit
    ///      "focus this Calyx surface instead" pointer `AgentEntry`
    ///      documents for an `.external` row whose own `surfaceID` isn't
    ///      a `SurfaceRegistry` id.
    ///   2. Otherwise, a `.hooks`/`.titleHeuristic` row's own `surfaceID`
    ///      IS a real `SurfaceRegistry` id (that's where those sources
    ///      get it from) and is always resolvable.
    ///   3. Otherwise -- an `.external` row with no `focusSurfaceID` (true
    ///     of every UNBRIDGED herdr row: `HerdrAgentMirror` only
    ///     resolves one for a pane the pane registry actually bridges --
    ///     see `HerdrAgentMirror.swift`'s header) -- there is nothing
    ///     valid to focus.
    static func resolve(source: AgentSource, surfaceID: UUID, focusSurfaceID: UUID?) -> UUID? {
        if let focusSurfaceID { return focusSurfaceID }
        return source == .external ? nil : surfaceID
    }
}

// MARK: - Sidebar Rows

/// Pure flattening of the parent/child agent tree into the single flat
/// list `AgentStatusView.content`'s `ForEach` renders -- mirrors
/// `AgentSidebarGate` / `AgentRowFocusTarget`'s own extraction shape.
/// Flat is required, not stylistic: `.accessibilityElement(children:
/// .combine)` makes one row exactly one VoiceOver stop, so a child row
/// nested inside its parent's view would be swallowed into the parent's
/// own announcement instead of becoming its own stop. Children must be
/// SwiftUI siblings of their parent, which this function makes possible
/// by returning both as elements of the same array.
enum AgentSidebarRows {

    /// One rendered row: either a pane's own row, carrying how many
    /// children it currently has and whether it's disclosed, or one of
    /// those children. `childCount` is carried on `.parent` even when
    /// collapsed, so the caller can still draw the count badge without
    /// re-deriving it from `children(_:)`.
    enum Row: Identifiable {
        case parent(AgentEntry, childCount: Int, isExpanded: Bool)
        case child(SubagentEntry)

        var id: String {
            switch self {
            case .parent(let entry, _, _): return entry.id.uuidString
            case .child(let child): return child.id
            }
        }

        /// The origin this row's per-row `TimelineView` should be
        /// anchored to, and the same instant its own seconds-ticking
        /// label is measured from: a parent row's anchor must match
        /// `lastEventLabel(lastEventAt:now:)`'s `lastEventAt`, and a
        /// child row's anchor must match `elapsedLabel(since:now:)`'s
        /// `since`, so the row's `TimelineView` fires exactly when that
        /// label's displayed value would change.
        var tickAnchor: Date {
            switch self {
            case .parent(let entry, _, _): return entry.lastEventAt
            case .child(let child): return child.startedAt
            }
        }
    }

    /// Builds the flat row list: one `.parent` row per entry in
    /// `entries` order, immediately followed by that parent's own
    /// `.child` rows (in `children(_:)` order) when its surfaceID is in
    /// `expanded`. A collapsed parent contributes only its `.parent`
    /// row -- its children are still counted (`childCount`) but not
    /// emitted. An `expanded` entry naming a surfaceID with no
    /// corresponding `AgentEntry` is a no-op: this function only ever
    /// iterates `entries`, so a phantom surfaceID never produces a row.
    static func build(entries: [AgentEntry], children: (UUID) -> [SubagentEntry], expanded: Set<UUID>) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let kids = children(entry.surfaceID)
            let isExpanded = expanded.contains(entry.surfaceID)
            rows.append(.parent(entry, childCount: kids.count, isExpanded: isExpanded))
            if isExpanded {
                rows.append(contentsOf: kids.map(Row.child))
            }
        }
        return rows
    }
}

// MARK: - Agent Row View

private struct AgentRowView: View {
    let entry: AgentEntry
    /// The "current" instant supplied by this row's own enclosing
    /// `TimelineView`, anchored (per `AgentSidebarRows.Row.tickAnchor`) on
    /// this same `entry.lastEventAt`, passed to
    /// `AgentRowDisplay.lastEventLabel(lastEventAt:now:)` to render that
    /// value's trailing label without this row managing its own timer. An
    /// interval under one second between the two -- including a negative
    /// one, `lastEventAt` landing ahead of
    /// this tick -- reads "now" rather than a `RelativeDateTimeFormatter`
    /// phrase; see `lastEventLabel` for why.
    let now: Date
    /// Resolves the pane's own recorded title (`SurfacePropertyStore
    /// .title(for:)`) for the surface `focusTarget` names, this row's
    /// primary label source. Passed down from `AgentStatusView`'s own
    /// `paneTitle`.
    let paneTitle: (UUID) -> String?
    /// Resolves the pane's own recorded cwd (`SurfacePropertyStore
    /// .cwd(for:)`) for the surface `focusTarget` names, this row's cwd
    /// line fallback when `entry.cwd` is `nil`/empty. Passed down from
    /// `AgentStatusView`'s own `paneCwd`.
    let paneCwd: (UUID) -> String?
    /// How many children `AgentSidebarRows.build` currently counts for
    /// this row's surfaceID. `0` renders the row exactly as it rendered
    /// before subagent rows existed: no chevron, no badge, no layout
    /// shift -- the first-class appearance for a CLI (pi, hermes, herdr)
    /// that never reports children.
    let childCount: Int
    /// Whether this row's children are currently disclosed, per
    /// `AgentStatusView.expandedParents`. Drives the chevron's rotation.
    let isExpanded: Bool
    /// Flips this row's disclosure state. A separate hit target from the
    /// row body's own tap gesture (which focuses the pane) -- see the
    /// chevron `Button` in `rowContent` below.
    let onToggleExpanded: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private var dotColor: Color { AgentRowDisplay.dotColor(for: entry.state) }

    /// The row's primary label: the pane's own recorded title. Delegates
    /// to `AgentRowDisplay.primaryLabel(source:surfaceID:focusSurfaceID:
    /// paneTitle:)` so the derivation -- including the focus-target
    /// resolution that reaches a bridged herdr row's title through
    /// `focusSurfaceID` -- exists in exactly one place, directly testable
    /// without mounting this view.
    private var displayName: String {
        AgentRowDisplay.primaryLabel(
            source: entry.source,
            surfaceID: entry.surfaceID,
            focusSurfaceID: entry.focusSurfaceID,
            paneTitle: paneTitle
        )
    }

    /// The row's second line: the pane's working directory basename.
    /// Delegates to `AgentRowDisplay.cwdLabel(entryCwd:source:surfaceID:
    /// focusSurfaceID:paneCwd:)` so the derivation -- including the
    /// fallback to the pane's live cwd for a `.titleHeuristic` row
    /// (always created with `cwd: nil`) or a fresh `.mcpConnection`
    /// row -- exists in exactly one place, directly testable without
    /// mounting this view.
    private var cwdLabel: String {
        AgentRowDisplay.cwdLabel(
            entryCwd: entry.cwd,
            source: entry.source,
            surfaceID: entry.surfaceID,
            focusSurfaceID: entry.focusSurfaceID,
            paneCwd: paneCwd
        )
    }

    /// The row's third line. Delegates to `AgentRowDisplay.subtitle`
    /// so the derivation exists in exactly one place, directly testable
    /// without mounting this view.
    private var subtitle: String {
        AgentRowDisplay.subtitle(kind: entry.kind, source: entry.source)
    }

    /// The surface this row's click should focus, per
    /// `AgentRowFocusTarget.resolve`'s doc comment -- `nil` for a row
    /// with no resolvable target (an unbridged herdr row).
    private var focusTarget: UUID? {
        AgentRowFocusTarget.resolve(source: entry.source, surfaceID: entry.surfaceID, focusSurfaceID: entry.focusSurfaceID)
    }

    var body: some View {
        // Presentation choice for a row with no resolvable focus
        // target (`focusTarget == nil`) -- rather than keeping the tap
        // gesture wired to `entry.surfaceID` (for an UNBRIDGED herdr
        // row, a synthetic id no `SurfaceRegistry` knows, so the click
        // would be a silent no-op), the row is rendered as plain,
        // non-interactive content: no `.onTapGesture` and no hover
        // highlight. This branch has no hover writer of its own --
        // `isHovering` is only ever flipped by the `.onAssumeInsideHover`
        // attached in the interactive branch below -- so the
        // `.onChange` below clears it back to `false` on the transition
        // into this branch, keeping the background fill in `rowContent`
        // from ever appearing here even for a row that WAS hovered right
        // up to the moment it lost its focus target (e.g. its bridging
        // Calyx pane closed while the pointer was still over the row).
        // This was chosen as the least surprising option over, say, a
        // visibly "disabled" treatment (dimmed/greyed row) -- the row
        // still needs to convey real, current agent state at a glance;
        // only the click AFFORDANCE (hover feedback inviting a tap) is
        // removed, matching how every other purely-informational element
        // in this sidebar (e.g. `hooksIssuesBanner`) already has no
        // hover/tap treatment at all.
        // `displayName` and its tooltip string are each resolved exactly
        // once per render, here, and threaded into
        // `rowContent(title:tooltip:)` and the `.help` modifier below.
        // `displayName` delegates to `paneTitle`, an injected closure
        // that ends in a dictionary lookup (`SurfacePropertyStore
        // .title(for:)`), and the tooltip is built from `resolvedTitle`
        // plus `cwdLabel`/`subtitle` besides -- resolving both once here
        // avoids rebuilding either for the row's two consumers of the
        // tooltip text, `.help` and `.accessibilityLabel`.
        let resolvedTitle = displayName
        let resolvedTooltip = AgentRowDisplay.tooltip(title: resolvedTitle, cwdLabel: cwdLabel, subtitle: subtitle)
        Group {
            if let focusTarget {
                rowContent(title: resolvedTitle, tooltip: resolvedTooltip)
                    .onAssumeInsideHover($isHovering)
                    .onTapGesture {
                        NotificationCenter.default.post(
                            name: .calyxFocusSurface,
                            object: nil,
                            userInfo: ["surfaceID": focusTarget]
                        )
                    }
            } else {
                rowContent(title: resolvedTitle, tooltip: resolvedTooltip)
            }
        }
        // The title/cwd/subtitle lines `rowContent` renders are each
        // `.lineLimit(1)` and can truncate on screen -- the subtitle in
        // particular truncates in the middle of a narrow column for
        // `.external` rows (to keep their trailing " via herdr" marker
        // readable; see `AgentRowDisplay.subtitleTruncationMode`) -- so
        // the tooltip is how a row's full text is reached, whether or
        // not the row is clickable. Attached to the `Group` so both
        // branches of the `if` above get it.
        .help(resolvedTooltip)
        // `focusTarget` can flip non-nil -> nil at runtime (its bridging
        // Calyx pane closing prunes `focusSurfaceID`), which tears down
        // `.onAssumeInsideHover` above along with it -- AppKit sends no
        // `mouseExited` to a tracking view already removed from the
        // hierarchy, so nothing else would ever clear a hover left
        // `true` at that instant. Mirrors `CloseButtonHoverHighlight`'s
        // own `.onChange(of: isVisible)` guard for the identical
        // tracking-view-removal case.
        .onChange(of: focusTarget) { _, newValue in
            if newValue == nil { isHovering = false }
        }
    }

    private func rowContent(title: String, tooltip: String) -> some View {
        HStack(spacing: 8) {
            // The row's own content, combined into a single VoiceOver
            // stop -- kept in its own HStack, separate from the
            // disclosure chevron below, because `.accessibilityElement
            // (children: .combine)` replaces EVERY descendant with one
            // element: putting the chevron `Button` inside this HStack
            // would make `AccessibilityID.Sidebar.agentRowDisclosure`
            // unreachable and leave VoiceOver with no way to operate it,
            // exactly the "must work for everyone" failure the count
            // badge already avoids via `.accessibilityValue` below.
            HStack(spacing: 8) {
                // State dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                // Name + agent kind
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(cwdLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(AgentRowDisplay.subtitleTruncationMode(source: entry.source))
                }

                Spacer()

                if entry.unreadCount > 0 {
                    UnreadCountBadge(count: entry.unreadCount)
                }

                Text(AgentRowDisplay.lastEventLabel(lastEventAt: entry.lastEventAt, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                // Absent entirely for childCount == 0, so a row for a
                // CLI that never reports children (pi, hermes, herdr)
                // renders identically to before subagent rows existed --
                // no badge, no layout shift.
                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(Color.secondary.opacity(0.18))
                        }
                }
            }
            // `.combine` merges this row's own Text children into a single
            // accessibility element whose content VoiceOver announces once --
            // unlike `.contain`, which keeps each child individually
            // accessible inside a labelled container and would announce the
            // row's content once for the container and again as separate
            // stops for every child. The explicit `.accessibilityLabel`
            // below then replaces that merged content with `tooltip`
            // (title/cwd/subtitle), and `.accessibilityValue` separately
            // surfaces the unread count `UnreadCountBadge` draws, so this
            // inner element is exactly one VoiceOver stop carrying both.
            //
            // The relative last-event time is deliberately left out of
            // both: this row sits inside its own
            // `TimelineView(.periodic(from: row.tickAnchor, by: 1))` that
            // re-renders every second, so a value that changed every
            // second would re-announce while VoiceOver focus sits on the
            // row.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Sidebar.agentRow(id: entry.id))
            .accessibilityLabel(tooltip)
            .accessibilityValue(AgentRowDisplay.unreadAccessibilityValue(count: entry.unreadCount))

            // Disclosure: a separate hit target from the row body's own
            // .onTapGesture (which focuses the pane) -- an Agents row's
            // click already means "focus this pane", so the chevron must
            // not also carry that meaning -- and its own, reachable
            // VoiceOver stop, per the comment above. Absent entirely for
            // childCount == 0.
            if childCount > 0 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        onToggleExpanded()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Sidebar.agentRowDisclosure(id: entry.surfaceID))
                .accessibilityLabel(isExpanded ? "Collapse subagents" : "Expand subagents")
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(reduceTransparency ? 0.08 : 0.05))
            }
        }
        .opacity(controlActiveState == .key ? 1.0 : 0.5)
    }
}

// MARK: - Agent Sub Row View

/// One child row, a sibling of its parent's own `AgentRowView` in the
/// same flat `ForEach` -- see `AgentSidebarRows`'s doc comment for why
/// flat is required rather than nesting this inside the parent. Shows
/// the child's lifecycle state (the same dot colors `AgentRowView`
/// uses) plus whatever the CLI has reported for it: `agentType` on its
/// own line, and `lastToolName` with `lastToolSummary` together on one
/// line via `AgentRowDisplay.toolLine(toolName:toolSummary:)`. A `nil`
/// `agentType` or `lastToolName` simply omits that line rather than
/// rendering an "N/A" placeholder, since a child carries no pane of its
/// own for those fields to ever legitimately resolve to a missing value
/// the way a parent row's title/cwd can. The trailing
/// label is a counting-up elapsed duration since the child started
/// (`AgentRowDisplay.elapsedLabel(since:now:)`), matching what the CLI's
/// own display shows for a running subagent -- not a relative "... ago"
/// time, which is what `AgentRowView`'s own trailing label means for the
/// parent row.
private struct AgentSubRowView: View {
    let child: SubagentEntry
    /// The instant used to render the counting-up elapsed duration since
    /// `child.startedAt` (`AgentRowDisplay.elapsedLabel(since:now:)`),
    /// supplied by this row's own enclosing `TimelineView`, anchored (per
    /// `AgentSidebarRows.Row.tickAnchor`) on that same `startedAt`, so it
    /// stays live without this row managing its own timer.
    let now: Date
    /// The surface a click on this row should focus -- resolved once by
    /// the caller via `AgentRowFocusTarget.resolve(source:surfaceID:
    /// focusSurfaceID:)` on the PARENT's own source/surfaceID/
    /// focusSurfaceID, since a child shares its parent's surface rather
    /// than owning one of its own. `nil` renders this row
    /// non-interactive, mirroring `AgentRowView.body`'s own branch for
    /// the identical case.
    let focusTarget: UUID?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private var dotColor: Color { AgentRowDisplay.dotColor(for: child.state) }

    private var typeLine: String? {
        guard let agentType = child.agentType, !agentType.isEmpty else { return nil }
        return agentType
    }

    private var toolLine: String? {
        AgentRowDisplay.toolLine(toolName: child.lastToolName, toolSummary: child.lastToolSummary)
    }

    private var elapsedLine: String {
        AgentRowDisplay.elapsedLabel(since: child.startedAt, now: now)
    }

    /// This row's hover help text: the child's state (always present, via
    /// `AgentRowDisplay.stateLabel(for:)`), `typeLine` and `toolLine`,
    /// each omitted (not "N/A") when `nil`, and the elapsed duration
    /// since the child started. The state is always included, unlike
    /// `typeLine` / `toolLine`, so this string is never empty even for a
    /// CLI whose subagent hooks are lifecycle-only (codex) and report
    /// neither an agent type nor a tool name. Unlike `accessibilityLabel`
    /// below, hover help has no re-announce concern, so it includes
    /// `elapsedLine`.
    private var helpText: String {
        ([AgentRowDisplay.stateLabel(for: child.state), typeLine, toolLine, elapsedLine] as [String?])
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    /// This row's accessibility label: the same content as `helpText`
    /// minus `elapsedLine`. This row sits inside its own
    /// `TimelineView(.periodic(from: row.tickAnchor, by: 1))` that
    /// re-renders every second, so including the counting-up elapsed
    /// duration here would change the label every second and re-announce
    /// the row while VoiceOver focus sits on it.
    private var accessibilityLabel: String {
        ([AgentRowDisplay.stateLabel(for: child.state), typeLine, toolLine] as [String?])
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var body: some View {
        Group {
            if let focusTarget {
                rowContent
                    .onAssumeInsideHover($isHovering)
                    .onTapGesture {
                        NotificationCenter.default.post(
                            name: .calyxFocusSurface,
                            object: nil,
                            userInfo: ["surfaceID": focusTarget]
                        )
                    }
            } else {
                rowContent
            }
        }
        .help(helpText)
        .onChange(of: focusTarget) { _, newValue in
            if newValue == nil { isHovering = false }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                if let typeLine {
                    Text(typeLine)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                if let toolLine {
                    Text(toolLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The sidebar is user-resizable, so SwiftUI picks
                        // the elision point from the actual width: eliding
                        // at the tail keeps the tool name and the head of
                        // its content, the part that identifies the call.
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Text(elapsedLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                // A long tool line must not squeeze the duration into an
                // ellipsis of its own: the duration keeps its full width
                // and the tool line elides instead.
                .layoutPriority(1)
        }
        .contentShape(Rectangle())
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(reduceTransparency ? 0.08 : 0.05))
            }
        }
        .opacity(controlActiveState == .key ? 1.0 : 0.5)
        // See AgentRowView.rowContent's own `.accessibilityElement`
        // comment: `.combine` makes this row one VoiceOver stop, and the
        // elapsed duration is left out of the merged content for the
        // same re-announce-every-second reason.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentSubRow(id: child.id))
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Row Display

/// Pure label derivation extracted from `AgentRowView.displayName` so
/// it's directly testable without mounting the view.
@MainActor
enum AgentRowDisplay {

    /// The Agents sidebar row's primary label: the pane's own recorded
    /// title (`paneTitle`, ultimately `SurfacePropertyStore
    /// .title(for:)`), returned verbatim -- no stripping, truncation, or
    /// trimming of whatever an agent CLI wrote into the pane's title.
    /// `"N/A"` for a `nil`, empty, or whitespace-only title (no
    /// resolvable pane, a pane whose own title is empty, or a title
    /// consisting only of whitespace/newlines). The emptiness check
    /// trims a copy to decide, but the returned string is always the
    /// original, untrimmed `title` -- a title with real content keeps
    /// its exact bytes, including any leading/trailing padding.
    /// `nonisolated`: pure string work, so `MissionMapSnapshotBuilder`
    /// can reuse it off the main actor.
    nonisolated static func primaryLabel(title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "N/A" }
        return title
    }

    /// The state dot color shared by a parent row (`AgentRowView`) and
    /// its child rows (`AgentSubRowView`) -- extracted here so both draw
    /// from the same mapping rather than each keeping its own copy of
    /// this switch.
    static func dotColor(for state: AgentState) -> Color {
        switch state {
        case .blocked: return .red
        case .working: return .yellow
        case .done:    return .blue
        case .idle:    return .green
        }
    }

    /// A human-readable name for `state`, the CLI-reported fact
    /// `dotColor(for:)` also draws from -- unlike `agentType` /
    /// `lastToolName`, `state` always has a value, so
    /// `AgentSubRowView` folds this into its tooltip/accessibility
    /// label to guarantee that text is never empty even when a CLI
    /// (e.g. codex, whose subagent hooks are lifecycle-only) reports
    /// neither an agent type nor a tool name for a child.
    static func stateLabel(for state: AgentState) -> String {
        switch state {
        case .blocked: return "Blocked"
        case .working: return "Working"
        case .done:    return "Done"
        case .idle:    return "Idle"
        }
    }

    /// The Agents sidebar row's primary label, composed end to end from
    /// an entry's own `source`/`surfaceID`/`focusSurfaceID` plus a pane
    /// title lookup -- the full composition `AgentRowView.displayName`
    /// performs, hoisted here so it exists in exactly one place, directly
    /// testable without mounting the view. Resolves the surface to look
    /// up through `AgentRowFocusTarget.resolve(source:surfaceID:
    /// focusSurfaceID:)` rather than passing `surfaceID` straight to
    /// `paneTitle`: an `.external` row's own `surfaceID` is a herdr pane
    /// id and is never resolvable in the per-surface title store
    /// `paneTitle` reads from, so a bridged herdr row reaches its title
    /// only through `focusSurfaceID`. Delegates to `primaryLabel(title:)`
    /// for the "N/A" fallback rather than duplicating that rule.
    static func primaryLabel(
        source: AgentSource,
        surfaceID: UUID,
        focusSurfaceID: UUID?,
        paneTitle: (UUID) -> String?
    ) -> String {
        let focusTarget = AgentRowFocusTarget.resolve(source: source, surfaceID: surfaceID, focusSurfaceID: focusSurfaceID)
        return primaryLabel(title: focusTarget.flatMap(paneTitle))
    }

    /// A child row's tool line: the CLI-reported tool name, followed by
    /// that call's own content (`SubagentEntry.lastToolSummary` -- the
    /// command, the file path, the URL) after a colon and one space.
    /// `nil` for a `nil` or empty tool name, so a row with no tool
    /// reported omits the line entirely rather than showing a
    /// placeholder. The name alone when there is no summary or it is
    /// empty: never a trailing separator. The separator is plain
    /// punctuation because VoiceOver speaks this string as-is.
    /// `nonisolated` (like `primaryLabel(title:)`): pure string work, so
    /// `MissionMapSnapshotBuilder` can reuse it off the main actor.
    nonisolated static func toolLine(toolName: String?, toolSummary: String?) -> String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        guard let toolSummary, !toolSummary.isEmpty else { return toolName }
        return "\(toolName): \(toolSummary)"
    }

    /// The Agents sidebar row's second line: the pane's working
    /// directory basename. Reuses `AgentRegistry.basename` rather than
    /// re-deriving it, so the basename logic exists in exactly one
    /// place. `"N/A"` for a `nil` or empty `cwd` (an empty basename),
    /// matching `primaryLabel(title:)`'s own fallback.
    static func cwdLabel(cwd: String?) -> String {
        let basename = AgentRegistry.basename(cwd)
        guard !basename.isEmpty else { return "N/A" }
        return basename
    }

    /// The Agents sidebar row's second line, composed end to end from an
    /// entry's own `cwd` plus a live pane cwd lookup -- mirrors
    /// `primaryLabel(source:surfaceID:focusSurfaceID:paneTitle:)`'s
    /// composition shape. `entryCwd` wins outright whenever non-empty
    /// (`paneCwd` is never called in that case); a `nil` or empty
    /// `entryCwd` falls back to `paneCwd` at the surface resolved by
    /// `AgentRowFocusTarget.resolve(source:surfaceID:focusSurfaceID:)`,
    /// the same resolution `primaryLabel`'s composed overload uses, so a
    /// `.titleHeuristic` row (always created with `cwd: nil`) or a fresh
    /// `.mcpConnection` row still reaches its pane's live cwd, and a bridged
    /// `.external` row reaches it through `focusSurfaceID` rather than
    /// its own (herdr) `surfaceID`. Delegates to `cwdLabel(cwd:)` for the
    /// basename derivation and the `"N/A"` fallback rather than
    /// duplicating either.
    static func cwdLabel(
        entryCwd: String?,
        source: AgentSource,
        surfaceID: UUID,
        focusSurfaceID: UUID?,
        paneCwd: (UUID) -> String?
    ) -> String {
        if let entryCwd, !entryCwd.isEmpty {
            return cwdLabel(cwd: entryCwd)
        }
        let focusTarget = AgentRowFocusTarget.resolve(source: source, surfaceID: surfaceID, focusSurfaceID: focusSurfaceID)
        return cwdLabel(cwd: focusTarget.flatMap(paneCwd))
    }

    /// The Agents sidebar row's third line: `AgentEntry
    /// .displayName(forKind:)`, with a plain `" via herdr"` suffix for
    /// `.external` rows so a row sourced from herdr rather than Calyx's
    /// own hooks/title-heuristic pipeline is distinguishable at a
    /// glance ("Claude Code via herdr"). Kept in natural reading order
    /// (kind first): `AgentRowView` pairs this with the
    /// `.truncationMode` `subtitleTruncationMode(source:)` picks for the
    /// rendered `Text`, so `.lineLimit(1)` truncating in the narrow
    /// (~60pt) subtitle column elides the string in a way that keeps
    /// this marker readable rather than swallowing it.
    static func subtitle(kind: String, source: AgentSource) -> String {
        let kindLabel = AgentEntry.displayName(forKind: kind)
        guard source == .external else { return kindLabel }
        return "\(kindLabel) via herdr"
    }

    /// The `.truncationMode` `AgentRowView.rowContent` applies to the
    /// subtitle `Text` returned by `subtitle(kind:source:)`. Only
    /// `.external` rows carry a trailing `" via herdr"` marker, so only
    /// they need `.middle`: a narrow (~60pt) column truncating at the
    /// tail would elide the marker itself ("Claude Code via h..."
    /// becoming unreadable), whereas `.middle` keeps it visible
    /// ("Clau...herdr"). Rows without a marker (`.hooks`,
    /// `.titleHeuristic`, `.mcpConnection`) get `.tail` instead, so
    /// their more informative leading text stays readable.
    static func subtitleTruncationMode(source: AgentSource) -> Text.TruncationMode {
        source == .external ? .middle : .tail
    }

    /// The Agents sidebar row's tooltip and accessibility-label text:
    /// `title`, `cwdLabel`, and `subtitle` newline-joined, always three
    /// lines. Both `AgentRowView`'s `.help` tooltip and its
    /// `.accessibilityLabel` are built from this function's result, and
    /// `AgentRowView.rowContent` renders the same three lines
    /// unconditionally, so the two always stay in agreement.
    static func tooltip(title: String, cwdLabel: String, subtitle: String) -> String {
        [title, cwdLabel, subtitle].joined(separator: "\n")
    }

    /// The Agents sidebar row's `.accessibilityValue`: the unread count
    /// `AgentRowView.rowContent` also draws via `UnreadCountBadge`,
    /// spoken so the row's most actionable fact survives the
    /// `.accessibilityLabel(tooltip)` override on the same element.
    /// Mirrors `UnreadCountBadge`'s two rules exactly, so the spoken
    /// value can never disagree with the drawn badge: empty (nothing
    /// announced) for `count <= 0`, matching the `if entry.unreadCount >
    /// 0` guard `rowContent` wraps `UnreadCountBadge` in; capped at
    /// `"99+ unread"` for `count > 99`, matching `UnreadCountBadge`'s own
    /// `count > 99 ? "99+" : "\(count)"` digit cap.
    static func unreadAccessibilityValue(count: Int) -> String {
        guard count > 0 else { return "" }
        return count > 99 ? "99+ unread" : "\(count) unread"
    }

    /// A counting-up elapsed duration from `since` to `now`, shown on a
    /// child row (`AgentSubRowView`) as how long the CLI has reported it
    /// running -- not a relative "... ago" phrase, which is what a
    /// parent row's own trailing label means. Three forms: seconds only
    /// under a minute (`"0s"`...`"59s"`), minutes and seconds under an
    /// hour (`"1m 0s"`...`"59m 59s"`), hours and minutes at an hour and
    /// over (`"1h 0m"`, `"25h 0m"`). A `now` earlier than `since` -- clock
    /// skew, or an out-of-order write -- clamps to `"0s"` rather than
    /// rendering a negative duration.
    static func elapsedLabel(since: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(since)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    /// A parent row's trailing "last event" label, from `lastEventAt` to
    /// `now`. `RelativeDateTimeFormatter` renders the whole window
    /// strictly inside one second, in either direction, as a future-tense
    /// "in 0 sec." -- indistinguishable from an actual future instant, and
    /// reached almost permanently by a pane whose hook events arrive
    /// faster than the enclosing `TimelineView`'s one-second tick. Any
    /// interval under one second, including a negative one where
    /// `lastEventAt` lands ahead of `now`, instead reads the hardcoded
    /// English "now" -- deliberately unlocalized, matching `stateLabel
    /// (for:)`'s "Working"/"Idle" in this same type. At and beyond one
    /// second the formatter's own unit escalation ("1 sec. ago" through
    /// "1 hr. ago") is unchanged.
    static func lastEventLabel(lastEventAt: Date, now: Date) -> String {
        guard now.timeIntervalSince(lastEventAt) >= 1 else { return "now" }
        return relativeDateFormatter.localizedString(for: lastEventAt, relativeTo: now)
    }
}
