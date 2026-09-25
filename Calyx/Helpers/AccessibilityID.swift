// AccessibilityID.swift
// Calyx
//
// Stable accessibility identifiers for XCUITest element lookup.

import Foundation

enum AccessibilityID {
    enum Sidebar {
        static let container = "calyx.sidebar"
        static let newGroupButton = "calyx.sidebar.newGroupButton"
        static let agentModeButton = "calyx.sidebar.agentModeButton"
        static func group(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString)" }
        static func tab(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString)" }
        static func groupNameTextField(_ id: UUID) -> String { "calyx.sidebar.groupNameTextField.\(id.uuidString)" }
        static func groupCollapseButton(_ id: UUID) -> String { "calyx.sidebar.groupCollapseButton.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString).closeButton" }
        static func groupCloseAllButton(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString).closeAllButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calyx.sidebar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ groupID: UUID, _ index: Int) -> String {
            "calyx.sidebar.group.\(groupID.uuidString).tab.index.\(index)"
        }
        static func agentRow(id: UUID) -> String { "calyx.sidebar.agentRow.\(id.uuidString)" }
        static func agentRowDisclosure(id: UUID) -> String { "calyx.sidebar.agentRowDisclosure.\(id.uuidString)" }
        static func agentSubRow(id: String) -> String { "calyx.sidebar.agentSubRow.\(id)" }
        static let agentHooksIssuesBanner = "calyx.sidebar.agentHooksIssuesBanner"
        static let agentMonitoringDisabledBanner = "calyx.sidebar.agentMonitoringDisabledBanner"
        static let agentServerIssuesBanner = "calyx.sidebar.agentServerIssuesBanner"
    }
    enum GroupContextMenu {
        static let close = "calyx.groupMenu.close"
        static let closeOthers = "calyx.groupMenu.closeOthers"
        static let closeBelow = "calyx.groupMenu.closeBelow"
        static let rename = "calyx.groupMenu.rename"
        static let color = "calyx.groupMenu.color"
        static func color(_ color: TabGroupColor) -> String { "calyx.groupMenu.color.\(color.rawValue)" }
    }
    enum TabBar {
        static let container = "calyx.tabBar"
        static let newTabButton = "calyx.tabBar.newTabButton"
        static func tab(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString).closeButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calyx.tabBar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ index: Int) -> String { "calyx.tabBar.tab.index.\(index)" }
    }
    enum CommandPalette {
        static let container = "calyx.commandPalette"
        static let searchField = "calyx.commandPalette.searchField"
        static let resultsTable = "calyx.commandPalette.resultsTable"
    }
    enum MissionMap {
        static let container = "calyx.missionMap"
        static let edgeCanvas = "calyx.missionMap.edgeCanvas"
        static let popover = "calyx.missionMap.popover"
        static let popoverCloseButton = "calyx.missionMap.popoverCloseButton"
        static let escHint = "calyx.missionMap.escHint"
        static func card(_ id: UUID) -> String { "calyx.missionMap.card.\(id.uuidString)" }
        static func allowButton(_ id: UUID) -> String { "calyx.missionMap.allowButton.\(id.uuidString)" }
        static func openButton(_ id: UUID) -> String { "calyx.missionMap.openButton.\(id.uuidString)" }
        static func cardOpenButton(_ id: UUID) -> String { "calyx.missionMap.cardOpenButton.\(id.uuidString)" }
    }
    enum Compose {
        static let container = "calyx.compose"
        static let textView = "calyx.compose.textView"
        static let placeholder = "calyx.compose.placeholder"
    }
    enum Search {
        static let container = "calyx.search"
        static let searchField = "calyx.search.searchField"
        static let matchCount = "calyx.search.matchCount"
        static let previousButton = "calyx.search.previousButton"
        static let nextButton = "calyx.search.nextButton"
        static let closeButton = "calyx.search.closeButton"
    }
    enum Browser {
        static let toolbar = "calyx.browser.toolbar"
        static let backButton = "calyx.browser.backButton"
        static let forwardButton = "calyx.browser.forwardButton"
        static let reloadButton = "calyx.browser.reloadButton"
        static let urlDisplay = "calyx.browser.urlDisplay"
        static let errorBanner = "calyx.browser.errorBanner"
    }
    enum Git {
        static let changesContainer = "calyx.git.changes"
        static let refreshButton = "calyx.git.refreshButton"
        static let modeToggle = "calyx.git.modeToggle"
        static let stagedSection = "calyx.git.staged"
        static let unstagedSection = "calyx.git.unstaged"
        static let untrackedSection = "calyx.git.untracked"
        static let commitsSection = "calyx.git.commits"
        static func fileEntry(_ path: String) -> String { "calyx.git.file.\(path)" }
        static func commitRow(_ hash: String) -> String { "calyx.git.commit.\(hash)" }
        /// `id` is the repository's work-tree root path.
        static func repoSection(_ id: String) -> String { "calyx.git.repoSection.\(id)" }
        /// `id` is the repository's work-tree root path.
        static func refPicker(_ id: String) -> String { "calyx.git.refPicker.\(id)" }
    }
    /// Settings window (Calyx/Features/Settings/SettingsWindowController.
    /// swift). Applied to each pane's toggle NSSwitch controls, plus the
    /// AI Agent IPC row's Refresh button and status label, so an XCUITest
    /// suite can locate a specific control by a stable identifier instead
    /// of an ordinal position (`app.switches.firstMatch`), which silently
    /// breaks the moment a row is reordered or another switch is added
    /// above it.
    enum Settings {
        static let persistentSessionsSwitch = "calyx.settings.sessions.persistentSessionsSwitch"
        static let historyPersistenceSwitch = "calyx.settings.sessions.historyPersistenceSwitch"
        static let agentResumeSwitch = "calyx.settings.sessions.agentResumeSwitch"
        static let agentResumeAutoExecuteSwitch = "calyx.settings.sessions.agentResumeAutoExecuteSwitch"
        static let commandTrackingSwitch = "calyx.settings.sessions.commandTrackingSwitch"
        static let smoothScrollingSwitch = "calyx.settings.appearance.smoothScrollingSwitch"
        static let glassOpacityCellsSwitch = "calyx.settings.appearance.glassOpacityCellsSwitch"
        static let lspAutoInstallSwitch = "calyx.settings.lsp.lspAutoInstallSwitch"
        static let lspRequireConfirmationSwitch = "calyx.settings.lsp.lspRequireConfirmationSwitch"
        static let cockpitAutoApproveSwitch = "calyx.settings.sessions.cockpitAutoApproveSwitch"
        static let agentHookApprovalSwitch = "calyx.settings.sessions.agentHookApprovalSwitch"
        static let agentIPCSwitch = "calyx.settings.agents.agentIPCSwitch"
        static let agentIPCRefreshButton = "calyx.settings.agents.agentIPCRefreshButton"
        static let agentIPCStatusLabel = "calyx.settings.agents.agentIPCStatusLabel"
    }
    enum SessionBrowser {
        static func row(_ id: String) -> String { "calyx.sessionBrowser.row.\(id)" }
        static func attachButton(_ id: String) -> String { "calyx.sessionBrowser.row.\(id).attachButton" }
        static func killButton(_ id: String) -> String { "calyx.sessionBrowser.row.\(id).killButton" }
        static func remoteHostRow(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host)" }
        static func remoteHostAttachButton(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host).attachButton" }
        static func remoteHostInstallButton(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host).installButton" }
        static func herdrRow(_ id: String) -> String { "calyx.sessionBrowser.herdr.\(id)" }
        static func herdrCreateButton(_ id: String) -> String { "calyx.sessionBrowser.herdr.\(id).createButton" }
        static func herdrWorkspaceRow(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id)" }
        static func herdrWorkspaceAttachButton(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id).attachButton" }
        static func herdrWorkspaceKillButton(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id).killButton" }
    }
    /// Chrome-style in-app "your previous session was preserved" bar,
    /// shown at the top of a window when AppDelegate
    /// .hasPreservedSessionSnapshot is true (see RecoveryBarModel,
    /// Calyx/Features/Persistence/). Deliberately `calyx.recoveryBar.*`
    /// (a container + two per-window action buttons), not the bare
    /// `calyx.recoveryBar` some other single-container enums here use
    /// (e.g. Sidebar.container == "calyx.sidebar"), since this bar's own
    /// two buttons need distinguishable identifiers alongside it.
    enum RecoveryBar {
        static let container = "calyx.recoveryBar.container"
        static let restoreButton = "calyx.recoveryBar.restoreButton"
        static let dismissButton = "calyx.recoveryBar.dismissButton"
    }
    /// Cockpit approval banner, shown in a floating panel
    /// (ApprovalPanelWindow) at the screen's top-right corner when
    /// ApprovalBannerModel.current is non-nil (see ApprovalBannerModel,
    /// Calyx/Features/ApprovalInbox/). A macOS-notification-style
    /// layout, at a fixed 344pt (640pt for a request wanting inline
    /// option rows): the app icon on the left, a bold single-line,
    /// middle-truncated title (tool/target label, plus the queue
    /// navigator while more than one request is queued), a one-to-two-
    /// line secondary body (`payload`, tap-to-expand into
    /// `payloadExpanded`), and a vertically centered trailing column
    /// holding one source-specific primary action button plus an
    /// `optionsMenu` pull-down that lists every choice the CLI offers
    /// beyond that primary action (ApprovalBannerView). The panel itself
    /// paints with the same untinted regular glass as a native
    /// notification, independent of the Calyx theme
    /// (ApprovalPanelContentView).
    ///
    /// `payload` carries the FULL rendered text as its accessibility
    /// label (queried while visually truncated to two lines); clicking
    /// it toggles `payloadExpanded`, the scrolling full payload shown
    /// below the body (`ExpandableBodyText`, shared by `.mcpTool`/
    /// `.agentHook`/`.mcpApp`'s payload and `.agentQuestion`'s question text).
    /// `optionsMenu` is an `NSMenu` pull-down -- its own items reach the
    /// accessibility tree as `NSMenuItem` titles, found by title text
    /// rather than identifier, the same way the queue preview menu's rows
    /// already are: every row that ever lands only in a `Menu` (a
    /// `.mcpTool`/`.agentHook`/`.mcpApp` choice row, a question option/"Other…"
    /// row rendered through the Options menu rather than inline, "Add
    /// notes"/"Back"/"Chat about this") carries no identifier of its own
    /// for this reason, and is looked up by title in an XCUITest instead.
    ///
    /// `.mcpTool`'s primary action is "Allow" (`allowButton`); its
    /// `optionsMenu` lists "Always Allow" and "Deny", by title.
    /// `.agentHook`'s primary action is "Yes" (`allowButton`); its
    /// `optionsMenu` lists one row per `AgentHookOffers.permissionUpdates`
    /// element, Calyx's own pane-scoped "Always Allow ... in This Pane"
    /// only when the CLI sent no offer of its own, and "No" -- all by
    /// title. `.mcpApp` (an MCP Apps view's consent prompt) uses
    /// `allowButton` for its primary action -- "Open" for `ui/open-link`,
    /// "Send" for `ui/message`, "Copy" for a pane-less view's message --
    /// and its `optionsMenu` lists "Always Allow for This View" plus
    /// "Cancel"/"Don't Send", or only "Dismiss" for the copy, all by
    /// title. `.agentQuestion` shows no primary action at all for a plain
    /// single-select click (an option click confirms immediately);
    /// "Next"/"Answer" (`answerButton`) appears only while a multi-select
    /// question or a visible free-text field needs confirming. For a
    /// single-select question with no option carrying a `preview`, its
    /// `optionsMenu` lists each option (`optionButton(_:)`), "Other…"
    /// (`otherButton`), "Add notes", "Back" once available, and "Chat
    /// about this" -- the last three by title. For a multi-select
    /// question, or one where any option carries a `preview`, the
    /// options themselves render as an inline list instead (still
    /// `optionButton(_:)`, plus a standing `otherButton` row on the same
    /// list) and `optionsMenu` holds only "Add notes"/"Back"/"Chat about
    /// this" (by title) -- no `otherButton` of its own there, since the
    /// inline list's own row already covers it. `questionText`/
    /// `otherTextField`/`notesTextField`/`questionPosition` cover the
    /// body/input elements that layout adds below the header and body
    /// text. `previewText` is the side-by-side markdown preview box,
    /// shown next to the inline option list only when an option carries a
    /// `preview`. Queue navigation adds `previousButton`/
    /// `nextButton`/`positionLabel`, shown only while more than one
    /// request is queued for this window (see ApprovalBannerModel.
    /// positionInfo). The queue preview menu wraps that same position
    /// label in a `Menu` (`queueMenu`) listing every request in
    /// ApprovalBannerModel.queueEntries, so a click can jump straight to
    /// any queued request via ApprovalBannerModel.select(id:). macOS
    /// collapses that `Menu` into one accessibility element, which leaves
    /// `positionLabel` unreachable from the accessibility tree: the
    /// "N / M" text is exposed as `queueMenu`'s own accessibility label
    /// instead (see ApprovalBannerView.queueNavigator(positionInfo:)).
    enum ApprovalBanner {
        static let container = "calyx.approvalBanner.container"
        static let allowButton = "calyx.approvalBanner.allowButton"
        static let payload = "calyx.approvalBanner.payload"
        static let payloadExpanded = "calyx.approvalBanner.payloadExpanded"
        static let optionsMenu = "calyx.approvalBanner.optionsMenu"
        static let previousButton = "calyx.approvalBanner.previousButton"
        static let nextButton = "calyx.approvalBanner.nextButton"
        static let positionLabel = "calyx.approvalBanner.positionLabel"
        static let queueMenu = "calyx.approvalBanner.queueMenu"
        static let questionText = "calyx.approvalBanner.questionText"
        static func optionButton(_ index: Int) -> String { "calyx.approvalBanner.optionButton.\(index)" }
        static let otherButton = "calyx.approvalBanner.otherButton"
        static let otherTextField = "calyx.approvalBanner.otherTextField"
        static let answerButton = "calyx.approvalBanner.answerButton"
        static let questionPosition = "calyx.approvalBanner.questionPosition"
        static let previewText = "calyx.approvalBanner.previewText"
        static let notesTextField = "calyx.approvalBanner.notesTextField"
        /// The panel's own top-left ×, straddling the glass sheet's
        /// top-left corner (`ApprovalPanelContentView`'s own
        /// `.overlay(alignment: .topLeading)`, drawn into the window's
        /// transparent `ApprovalPanelArranger.gutter`), shown only
        /// while the panel is hovered. Resolves `.dismissed` for a
        /// dismissible request (`ApprovalRequest.isDismissible`);
        /// disabled (but still present, same identifier) for one that
        /// isn't.
        static let dismissButton = "calyx.approvalBanner.dismissButton"
        /// `ApprovalTooltipWindow`'s own content -- the Calyx-drawn
        /// tooltip `ExpandableBodyText`'s `collapsedText` shows on
        /// hover, in place of AppKit's own `.help` (the panel is a
        /// non-activating panel that never becomes key on hover, so a
        /// pointer entering it elsewhere and sliding onto the text never
        /// arms the system tooltip).
        static let tooltip = "calyx.approvalBanner.tooltip"
    }
    enum Diff {
        static let container = "calyx.diff"
        static let toolbar = "calyx.diff.toolbar"
        static let content = "calyx.diff.content"
        static let lineNumberGutter = "calyx.diff.lineNumbers"
    }
    enum DiffReview {
        static let submitButton = "calyx.diff.review.submitButton"
        static let discardButton = "calyx.diff.review.discardButton"
        static let commentBadge = "calyx.diff.review.commentBadge"
        static let commentPopover = "calyx.diff.review.commentPopover"
        static let submitAllButton = "calyx.diff.review.submitAllButton"
        static let discardAllButton = "calyx.diff.review.discardAllButton"
    }
    /// MCP Apps views: the inline dock of a pane, each view's card, and
    /// the standalone panel of a pane-less invocation (see
    /// Calyx/Features/MCPApps/). A view's `ui/open-link`/`ui/message`
    /// consent prompt is not in the card: it is the approval panel's
    /// (`ApprovalBanner`).
    enum MCPApps {
        static func dock(_ surfaceID: UUID) -> String { "calyx.mcpApps.dock.\(surfaceID.uuidString)" }
        static func viewWeb(_ viewID: UUID) -> String { "calyx.mcpApps.view.\(viewID.uuidString).web" }
        static func viewHeader(_ viewID: UUID) -> String { "calyx.mcpApps.view.\(viewID.uuidString).header" }
        static func viewStateLabel(_ viewID: UUID) -> String { "calyx.mcpApps.view.\(viewID.uuidString).stateLabel" }
        static func viewCloseButton(_ viewID: UUID) -> String { "calyx.mcpApps.view.\(viewID.uuidString).closeButton" }
        static func viewReloadButton(_ viewID: UUID) -> String { "calyx.mcpApps.view.\(viewID.uuidString).reloadButton" }
        static func standalonePanel(_ viewID: UUID) -> String { "calyx.mcpApps.standalonePanel.\(viewID.uuidString)" }
        static let dockSwitcher = "calyx.mcpApps.dock.switcher"
        static let elicitationContainer = "calyx.mcpApps.elicitation.container"
        static let elicitationAcceptButton = "calyx.mcpApps.elicitation.acceptButton"
        static let elicitationDeclineButton = "calyx.mcpApps.elicitation.declineButton"
        static let signInContainer = "calyx.mcpApps.signIn.container"
        static let signInButton = "calyx.mcpApps.signIn.button"
        static func tabActivityIndicator(_ tabID: UUID) -> String { "calyx.mcpApps.tabActivity.\(tabID.uuidString)" }
    }
    /// Settings > MCP Servers. Row identifiers use
    /// `MCPServerID.rawValue.uuidString`.
    enum MCPServersSettings {
        static let list = "calyx.settings.mcpServers.list"
        static let emptyState = "calyx.settings.mcpServers.emptyState"
        static let ipcDisabledBanner = "calyx.settings.mcpServers.ipcDisabledBanner"
        static let configErrorBanner = "calyx.settings.mcpServers.configErrorBanner"
        static let addButton = "calyx.settings.mcpServers.addButton"
        static let importButton = "calyx.settings.mcpServers.importButton"
        static func rowStatus(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).status" }
        static func rowEnabledSwitch(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).enabledSwitch" }
        static func rowEditButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).editButton" }
        static func rowRetryButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).retryButton" }
        static func rowRemoveButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).removeButton" }
        static func rowSignInButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).signInButton" }
        static func rowCancelSignInButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).cancelSignInButton" }
        static func rowSignOutButton(_ serverID: UUID) -> String { "calyx.settings.mcpServers.row.\(serverID.uuidString).signOutButton" }
        static let editorNameField = "calyx.settings.mcpServers.editor.nameField"
        static let editorAliasField = "calyx.settings.mcpServers.editor.aliasField"
        static let editorTransportPicker = "calyx.settings.mcpServers.editor.transportPicker"
        static let editorCommandField = "calyx.settings.mcpServers.editor.commandField"
        static let editorArgsField = "calyx.settings.mcpServers.editor.argsField"
        static let editorSaveButton = "calyx.settings.mcpServers.editor.saveButton"
        static let importTextView = "calyx.settings.mcpServers.import.textView"
        static let importPreview = "calyx.settings.mcpServers.import.preview"
        static let importParseError = "calyx.settings.mcpServers.import.parseError"
        static let importConfirmButton = "calyx.settings.mcpServers.import.confirmButton"
    }
}
