// ApprovalRequest.swift
// Calyx
//
// Cockpit approval-core data model: a pending gated action (e.g. an MCP
// tool call, or an MCP Apps view's `ui/open-link`/`ui/message` consent
// prompt) waiting on a human decision from the approval inbox. See
// ApprovalInboxStore for the queueing/decision lifecycle and
// ApprovalPolicy for whether a given action requires approval at all.

import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        case mcpTool(name: String)
        /// A tool call intercepted from a non-MCP CLI agent's own
        /// approval-gate hook (Claude Code / Codex / Grok), or from pi's
        /// extension gate, rather than Calyx's own MCP server -- `kind`
        /// identifies the owning CLI (`AgentEntry.claudeCodeKind` /
        /// `AgentEntry.codexKind` / `AgentEntry.grokKind` /
        /// `AgentEntry.piKind`); `toolName` and `summary` come from the
        /// decoded `AgentHookToolCall`.
        case agentHook(toolName: String, kind: String, summary: String, offers: AgentHookOffers)
        /// Claude Code's `AskUserQuestion` tool call, decoded into an
        /// `AgentQuestionPrompt` rather than the generic `.agentHook`
        /// summary -- the approval banner renders this question's own
        /// options (through the Options pull-down, or inline when the
        /// question wants it, see `AgentQuestionPrompt.Question.
        /// wantsInlineOptionList`) instead of a Deny/Always Allow/Allow
        /// row. `kind` is always
        /// `AgentEntry.claudeCodeKind` (see `AgentHookToolCall.question`'s
        /// own doc comment for why no other kind ever produces one), kept
        /// here rather than hardcoded so `displayToolName` stays a plain
        /// switch over `Source` with no special-cased kind literal. No
        /// separate `toolName`: it is always "AskUserQuestion" (the gate
        /// that produces a `.agentQuestion` at all), so there is nothing
        /// for a second field to carry that `displayToolName`'s own
        /// "Question" literal doesn't already say.
        case agentQuestion(kind: String, prompt: AgentQuestionPrompt)
        /// An MCP Apps view's consent prompt (`MCPAppWebViewRuntime.
        /// requestConsent(viewID:state:kind:)`): the view `viewID` asks to
        /// open a link, to send a message to its pane, or -- having no
        /// pane -- to have its message copied instead. `title` is the
        /// invocation's `serverDisplayName` (e.g. "Notion"). The "Always Allow for This View" answer
        /// (`ApprovalDecision.allowedForView`) is remembered by
        /// `MCPAppOpenLinkPolicy`/`MCPAppMessageConsentGate`, never by
        /// `ApprovalBannerModel.alwaysAllow(id:)`.
        case mcpApp(viewID: UUID, title: String, kind: MCPAppConsentKind)
    }

    let id: UUID
    let source: Source
    let targetSurfaceID: UUID?
    let payload: String
    let createdAt: Date
}

/// What an `.mcpApp`-sourced request asks the human to consent to.
enum MCPAppConsentKind: Sendable, Equatable {
    /// `ui/open-link`: open `URL` in the default browser.
    case openLink(URL)
    /// `ui/message` to a view with a pane: send the message to it.
    /// `preview` is the message's text with every newline already folded
    /// to a space (`ControlCharacterDisplay` would otherwise show each
    /// one as `^J`).
    case sendMessage(preview: String)
    /// `ui/message` from a pane-less (standalone) view: there is nothing
    /// to send to, so the only offer is to copy `text` -- the formatted
    /// message, newlines intact, exactly what lands on the pasteboard --
    /// to the clipboard.
    case copyMessage(text: String)

    /// The body text the approval panel shows for this prompt, also the
    /// request's own `payload`: the URL, the folded preview, or a
    /// sentence explaining the missing pane followed by the message with
    /// its newlines folded to spaces. RAW, unescaped -- see
    /// `ApprovalRequest.displayPayload`.
    var displayText: String {
        switch self {
        case .openLink(let url):
            return url.absoluteString
        case .sendMessage(let preview):
            return preview
        case .copyMessage(let text):
            let folded = text.components(separatedBy: .newlines).joined(separator: " ")
            return "The app wants to send a message, but this window has no pane. Copy it instead: \(folded)"
        }
    }

    /// The action half of `ApprovalRequest.displayToolName`.
    fileprivate var actionName: String {
        switch self {
        case .openLink: return "Open Link"
        case .sendMessage: return "Send Message"
        case .copyMessage: return "Copy Message"
        }
    }
}

/// What an `.agentHook`-sourced request may offer beyond the plain
/// "Yes"/"No" -- everything `ApprovalBannerView.agentHookMenuItems(toolName:offers:)`
/// reads to decide which choice rows to render, derived once at decode
/// time (`AgentHookToolCall`) so the view never branches on `kind` itself.
struct AgentHookOffers: Sendable, Equatable {
    /// One choice row per element -- see `AgentPermissionOffer`.
    let permissionUpdates: [AgentPermissionOffer]
    /// True iff `permissionUpdates` is non-empty -- i.e. this request
    /// actually carries at least one CLI always-allow row. When true, the
    /// CLI itself persists the human's always-allow choice through one of
    /// those rows, so `ApprovalBannerModel.alwaysAllow(id:)` (Calyx's OWN
    /// pane memory) is a no-op for this request: recording a second,
    /// Calyx-side memory alongside the CLI's own would be redundant and
    /// could silently diverge from it. When `permissionUpdates` is empty,
    /// `cliOwnsPersistence` is false: Calyx's own pane-scoped memory is
    /// the only persistence available, and its row renders instead.
    let cliOwnsPersistence: Bool

    /// The no-offers constant: no permission updates, so Calyx's own
    /// pane-scoped Always-Allow memory is the only persistence available.
    /// Used as a default where no offers apply -- test fixtures and any
    /// caller with no decoded call at hand -- not something
    /// `routeApprovalRequest` itself produces.
    static let none = AgentHookOffers(permissionUpdates: [], cliOwnsPersistence: false)
}

/// Why a `.denied` decision was made -- the model/view pick a reason,
/// never a wire string; `AgentHookPermissionResponse` alone maps a reason
/// to the message/reason text a given `kind`'s hook actually reads.
enum DenyReason: Sendable, Equatable {
    /// The human clicked "No" on an ordinary tool-call banner.
    case userRejected
}

/// Why an `.interrupted` decision was made.
enum InterruptReason: Sendable, Equatable {
    /// The question banner's [Chat about this] action -- the human wants
    /// to reply free-form in the pane instead of answering the structured
    /// prompt.
    case chatAboutQuestion
}

enum ApprovalDecision: Sendable, Equatable {
    case allowed
    /// "Always Allow for This View" on an `.mcpApp`-sourced request
    /// (`ApprovalBannerModel.allowForView(id:)`): allow this one and
    /// every later prompt of the same kind from the same view, remembered
    /// by `MCPAppOpenLinkPolicy`/`MCPAppMessageConsentGate` for as long
    /// as the view lives. Never produced for any other source.
    case allowedForView
    /// Accepting one of `AgentHookOffers.permissionUpdates` -- the CLI's
    /// own "always allow" choice, echoed back verbatim.
    case allowedWithPermissions(AgentPermissionOffer)
    case denied(DenyReason)
    /// The banner's own [Chat about this] action -- distinct from
    /// `.denied`: the CLI is told to STOP and wait for the human, not
    /// that the call was refused.
    case interrupted(InterruptReason)
    case expired
    /// A human's answer to an `.agentQuestion`-sourced request's
    /// `AskUserQuestion` prompt -- see `AgentQuestionAnswers`.
    case answered(AgentQuestionAnswers)
    /// The banner's own [x] dismiss action: "Calyx does not answer this
    /// request" -- distinct from `.denied` (nobody actually refused the
    /// call) and from `.expired` (nobody sat out the hold window, a
    /// human actively dismissed it). Applies to every `Source`, unlike
    /// `.interrupted`/`.answered` (`.agentQuestion` only).
    case dismissed
}

extension ApprovalRequest {
    /// The tool-name label `ApprovalBannerView` renders in its header.
    /// RAW, unescaped -- escaping untrusted text for display is
    /// `ControlCharacterDisplay`'s job, applied later in the view layer,
    /// not here. `.mcpTool` is just the tool's own name (today's
    /// semantics, unchanged); `.agentHook` combines the owning CLI's
    /// display label (`AgentEntry.displayName(forKind:)`) with the tool
    /// name, since an agent-hook call has no MCP tool name of its own.
    /// `.mcpApp` combines the view's `title` with the prompt's action
    /// ("Open Link"/"Send Message"/"Copy Message").
    var displayToolName: String {
        switch source {
        case .mcpTool(let name):
            return name
        case .agentHook(let toolName, let kind, _, _):
            return "\(AgentEntry.displayName(forKind: kind)) · \(toolName)"
        case .agentQuestion(let kind, _):
            return "\(AgentEntry.displayName(forKind: kind)) · Question"
        case .mcpApp(_, let title, let kind):
            return "\(title) · \(kind.actionName)"
        }
    }

    /// The payload text `ApprovalBannerView` renders in its body. RAW,
    /// unescaped, same caveat as `displayToolName` above. `.mcpTool`
    /// reuses `payload` unchanged (today's semantics); `.agentHook` uses
    /// the hook call's own `summary` instead -- `payload` there is the
    /// full (and possibly large) `tool_input` JSON, not what's meant for
    /// display. `.mcpApp` uses `MCPAppConsentKind.displayText`.
    var displayPayload: String {
        switch source {
        case .mcpTool:
            return payload
        case .agentHook(_, _, let summary, _):
            return summary
        case .agentQuestion(_, let prompt):
            return prompt.questions.map(\.text).joined(separator: "\n")
        case .mcpApp(_, _, let kind):
            return kind.displayText
        }
    }

    /// Whether the floating panel should show at `ApprovalPanelArranger.
    /// wideWidth` instead of its default `fixedWidth` for this request --
    /// true only for an `.agentQuestion` prompt carrying any question
    /// whose inline option rows would show (`AgentQuestionPrompt.
    /// Question.wantsInlineOptionList`). Derived from EVERY question in
    /// `prompt.questions`, not just whichever one is currently displayed
    /// -- the displayed question index lives in `AgentQuestionFormState`,
    /// view state this model layer does not have -- so the panel never
    /// changes width mid-answer as the form advances from a narrow
    /// question to a wide one or back.
    var prefersWideApprovalPanel: Bool {
        guard case .agentQuestion(_, let prompt) = source else { return false }
        return prompt.questions.contains { $0.wantsInlineOptionList }
    }

    /// Whether the panel's own × ("Calyx does not answer this request",
    /// `ApprovalBannerModel.dismiss(id:)`) applies to this request --
    /// true only when someone OTHER than Calyx can still decide it once
    /// Calyx itself declines to. `.mcpTool`: always true, the calling MCP
    /// agent receives `{"status": "dismissed"}` from `MCPCockpitBridge
    /// .gate`, a valid "nobody decided" result for any caller. `.agentHook`/
    /// `.agentQuestion`: delegates to `AgentHookPermissionResponse
    /// .cliKeepsOwnPrompt(kind:)` -- true only for a CLI that falls back
    /// to its own confirmation prompt on an absent hook response (a `nil`
    /// body, what `.dismissed` produces for such a kind, same as
    /// `.expired`; see that type's own file header). Grok and pi have no
    /// such fallback -- Calyx's gate is their only prompt (same header) --
    /// so a grok/pi request is never dismissible: `ApprovalPanelContentView
    /// .dismissButton(request:)` renders its × disabled for one, and
    /// `ApprovalBannerModel.dismiss(id:)` no-ops. `.mcpApp`: always true,
    /// a dismissed consent prompt is answered like Cancel/Don't Send --
    /// `.dismissed` grants nothing (`MCPAppOpenLinkPolicy.PromptDecision
    /// .init(_:)`/`MCPAppMessageConsentGate.PromptDecision.init(_:)`).
    var isDismissible: Bool {
        switch source {
        case .mcpTool, .mcpApp:
            return true
        case .agentHook(_, let kind, _, _), .agentQuestion(let kind, _):
            return AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: kind)
        }
    }

    /// One-line summary for the queue preview menu
    /// (`ApprovalBannerModel.queueEntries`, rendered by
    /// `ApprovalBannerView`'s queue navigator Menu):
    /// `"\(displayToolName): \(compactTarget)"`, omitting the trailing
    /// colon entirely once `compactTarget` is empty. `compactTarget`
    /// collapses every run of whitespace (including newlines/tabs) in
    /// `displayPayload` into a single space and trims the result,
    /// leaving its length alone: how long a menu row may be is a
    /// question about how wide it DRAWS, which only the view can answer
    /// (`ApprovalBannerView.fittedToMenuWidth(_:)` bounds the finished
    /// row in points and elides its middle). `displayToolName` still
    /// goes through a two-cap truncation at `maxToolNameCharacters`/
    /// `maxToolNameScalars`, applied here rather than inside
    /// `displayToolName` itself, which the banner header renders in
    /// full. RAW, unescaped -- same caveat as `displayToolName`/
    /// `displayPayload` above (`ControlCharacterDisplay` escaping is the
    /// view layer's job, applied later, not here).
    var previewLine: String {
        let toolName = Self.truncated(displayToolName, maxCharacters: Self.maxToolNameCharacters, maxScalars: Self.maxToolNameScalars)
        let target = Self.compactTarget(from: displayPayload)
        guard !target.isEmpty else { return toolName }
        return "\(toolName): \(target)"
    }

    /// The two caps `previewLine` truncates `displayToolName` at. A
    /// `Character` (extended grapheme cluster) can legally carry an
    /// unbounded number of combining-mark scalars, so a single "Zalgo"
    /// cluster counts as just 1 against a `Character`-only cap while
    /// dragging thousands of scalars into the row: counting scalars too
    /// is what actually bounds the string, exactly the reasoning behind
    /// `ControlCharacterDisplay.render`'s own scalar-counted `cap` (see
    /// its doc comment). Nothing upstream bounds that string:
    /// `AgentHookToolCall.decode` caps a hook call's `summary` at
    /// `maxSummaryLength` `Character`s and its `payload` at
    /// `maxPayloadBytes` UTF-8 bytes, but takes `tool_name` from the
    /// hook JSON at whatever length it arrives, and `AgentEntry.
    /// displayName(forKind:)` passes an unrecognized `kind` through raw,
    /// so both halves of an `.agentHook` `displayToolName` come from an
    /// external process unmeasured. The values sit far above the longest
    /// realistic name (a composed `mcp__server__tool`, or "Claude Code ·
    /// NotebookEdit"), so a real one is never truncated.
    private static let maxToolNameCharacters = 120
    private static let maxToolNameScalars = 360

    /// Collapses every whitespace run to a single space and trims the
    /// result in one step (`split(whereSeparator:)`'s default
    /// `omittingEmptySubsequences: true` drops the empty leading/
    /// trailing components a leading/trailing whitespace run would
    /// otherwise produce).
    private static func compactTarget(from payload: String) -> String {
        payload.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Truncates to a trailing single U+2026 ellipsis as soon as EITHER
    /// cap is exceeded, returning `text` untouched while both hold. The
    /// truncated form appends whole `Character`s only (never splitting a
    /// grapheme cluster) and reserves one `Character` and one scalar of
    /// each budget for that ellipsis, so the returned string itself
    /// satisfies both caps. A leading cluster already wider than the
    /// scalar budget therefore leaves nothing but that ellipsis.
    private static func truncated(_ text: String, maxCharacters: Int, maxScalars: Int) -> String {
        guard text.count > maxCharacters || text.unicodeScalars.count > maxScalars else {
            return text
        }

        var truncated = ""
        var characterCount = 0
        var scalarCount = 0
        for character in text {
            let characterScalars = character.unicodeScalars.count
            guard characterCount < maxCharacters - 1,
                  scalarCount + characterScalars <= maxScalars - 1 else { break }
            truncated.append(character)
            characterCount += 1
            scalarCount += characterScalars
        }
        return truncated + "…"
    }
}
