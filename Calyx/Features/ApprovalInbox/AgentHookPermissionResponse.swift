// AgentHookPermissionResponse.swift
// Calyx
//
// The PermissionRequest hook stdout body Calyx writes back to a CLI
// agent to carry a human's approval decision into that CLI's own
// synchronous permission gate -- shape and field names follow the
// PermissionRequest hook-response contract both Claude Code and Codex
// document (`hookSpecificOutput.decision.behavior`), replacing the
// older PreToolUse-era `hookSpecificOutput.permissionDecision` /
// `permissionDecisionReason` shape entirely -- neither CLI recognizes
// those two field names under PermissionRequest.
//
// `ApprovalDecision` is a CLI-agnostic value: the model/view pick a
// `DenyReason`/`InterruptReason`, never a wire string. This type -- and
// ONLY this type -- maps each `(kind, decision)` pair to the exact bytes
// that kind's hook reads: which fields exist, and which literal message/
// reason text a reason selects, both live here, nowhere upstream.
//
// Claude Code accepts the widest vocabulary: `updatedPermissions`
// (`.allowedWithPermissions`, echoing an `AgentPermissionOffer`'s own
// `entryJSON`), `updatedInput` (`.answered`'s own AskUserQuestion
// `updatedInput`), and `interrupt: true` (`.interrupted`) are all valid
// for it. Codex fails closed on all three -- Codex rejects the whole
// response if any of them is present -- so `.allowedWithPermissions`/
// `.interrupted`/`.answered` all produce nil for codex, exactly like
// `.expired` (no fallback body under PermissionRequest for either CLI --
// absent output lets that CLI's own confirmation prompt take over).
// `.dismissed` ("Calyx does not answer this request") produces nil for
// both too, folded into that same `.expired` arm: `cliKeepsOwnPrompt(
// kind:)` is true for both, so an absent hook response there means the
// same thing a dismissal does -- that CLI's own confirmation prompt
// takes over.
//
// Grok and pi read neither the nested envelope nor any of those three
// extra fields at all: both answer in a flat, top-level
// `{"decision":"allow"}` / `{"decision":"deny","reason":"..."}`
// vocabulary. Grok's gate is PreToolUse (it has no PermissionRequest
// event at all); pi's is a `tool_call` extension handler that reads this
// body itself and returns `{ block: true, reason }` on a deny. Neither
// has an "ask" analog, and for both an expired decision maps to an
// explicit deny -- a banner nobody answered within the hold window is
// not an approval -- but the two get there for different reasons.
//
// Silence at Grok's gate hands the call back to Grok's own permission
// pipeline rather than to a guaranteed prompt: a hook deny stops a call,
// while a hook allow only declines to deny and falls through to that
// pipeline. Under `bypassPermissions` the pipeline runs the call without
// asking anyone, so a banner nobody answered would silently permit
// exactly what Calyx was asked to gate -- hence the expiry deny. That
// mode is also the only one a grok request is ever held for:
// `CalyxMCPServer.routeApprovalRequest` answers every other mode with no
// body at all (`ApprovalHookEvent.gateIsSoleAuthority`), so Grok's own
// prompt keeps deciding there, the same way claude-code's and codex's
// do.
//
// pi has no such pipeline in any mode: it ships no permission prompt at
// all (`docs/usage.md`: it intentionally does not include permission
// popups), so Calyx's gate is the only approval mechanism a pi tool call
// ever passes through, and an expiry has nothing to defer to. Silence
// would run the call unreviewed.
//
// Since grok/pi have no vocabulary for `.allowedWithPermissions`/
// `.interrupted`/`.answered` at all (there is no question tool, no
// permission-suggestion offer, and no chat-about-this reachable for
// either kind today), those three produce a body BYTE-IDENTICAL to
// `.expired`'s own -- the same "nothing behind the gate would ask
// anyone, so an unrepresentable decision must still deny explicitly"
// reasoning `.expired` itself follows, reached through the very same
// code path rather than a second, separately-written deny body that
// could drift from it. `.dismissed` joins that same group for grok/pi:
// `cliKeepsOwnPrompt(kind:)` is false for both, so unlike claude-code/
// codex there is no prompt to hand a dismissed call back to --
// `ApprovalRequest.isDismissible` is false for both kinds for exactly
// that reason, so `flatBody` never actually reaches `.dismissed` in
// production, but answers it identically to `.expired` rather than
// `nil`/a crash, should that guard ever be bypassed.
//
// `.allowedForView` is an MCP Apps-only decision (an `.mcpApp`-sourced
// request's "Always Allow for This View") that never reaches a hook
// response at all; it is mapped exactly like `.expired` for every kind
// -- nil for claude-code/codex, the expiry deny body for grok/pi -- so
// a stray one can never read as an allow.
//
// `.answered` is claude-code's own AskUserQuestion decision (see
// `ApprovalDecision.answered(_:)`): `behavior: "allow"` plus
// `updatedInput`, which is the ENTIRE original `tool_input` echoed back
// verbatim (`AgentQuestionPrompt.originalToolInputJSON`, re-parsed as a
// JSON object) plus an `answers` key mapping each question's own text to
// its chosen value, and (only for a question whose entry carries notes
// or a previewed `.selectedOne` selection) an `annotations` key -- see
// `encodeAnswered(_:)`'s own doc comment for the exact per-question
// rule. Claude Code's own hook contract documents `updatedInput` as
// replacing the whole input object, so every unchanged field (e.g.
// `questions` itself, or an unknown key such as `metadata`) must
// round-trip through here too, not just `questions`. A stale
// `annotations` key already present on the original `tool_input` is
// OVERWRITTEN by the freshly built one, never merged with it -- same
// rule `answers` already follows.
//
// FAIL-SAFE CONTRACT: `body(kind:decision:)` returns `nil` for any
// `kind` other than `AgentEntry.claudeCodeKind` / `AgentEntry.codexKind`
// / `AgentEntry.grokKind` / `AgentEntry.piKind`. Calyx must never inject
// a permission decision into a CLI hook protocol it doesn't recognize --
// guessing at an unknown CLI's own stdout shape risks either silently
// authorizing a dangerous action or corrupting that CLI's own parsing of
// its hook's output.

import Foundation

enum AgentHookPermissionResponse {

    /// codex's/grok's/pi's own deny message -- the only `DenyReason` any
    /// of the three kinds' gates ever reaches is `.userRejected`, so one
    /// message covers it.
    static let deniedMessage = "Denied from the Calyx approval inbox."

    /// Whether `kind`'s own CLI keeps its own confirmation prompt to fall
    /// back to when Calyx answers its PermissionRequest hook with no
    /// decision at all (a `nil` body): true for claude-code/codex, which
    /// treat an absent hook response as "let my own prompt decide" --
    /// see this file's own header. False for grok/pi, which have no such
    /// fallback (Calyx's gate is the only approval mechanism either ever
    /// passes through), so an otherwise-unrepresentable decision must
    /// still deny explicitly rather than fall silently through to
    /// nothing.
    ///
    /// The single fact behind two call sites: `body(kind:decision:)`
    /// returns `nil` for `.dismissed` only where this is true (folded
    /// into the same nil arm `.expired` already uses), and
    /// `ApprovalRequest.isDismissible` is true for `.agentHook`/
    /// `.agentQuestion` only where this is true -- someone other than
    /// Calyx can decide a dismissed request only for a CLI that keeps its
    /// own prompt to hand it back to.
    static func cliKeepsOwnPrompt(kind: String) -> Bool {
        kind == AgentEntry.claudeCodeKind || kind == AgentEntry.codexKind
    }

    /// claude-code's own `.denied(.userRejected)` message -- VERBATIM
    /// from the binary (2.1.251), the same text Claude Code's own TUI
    /// "No" choice hands back to the model, so declining from Calyx's
    /// banner reads identically to declining in Claude Code's own
    /// dialog.
    static let claudeCodeRejectedMessage = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."

    /// claude-code's own `.interrupted(.chatAboutQuestion)` message --
    /// the question banner's [Chat about this] action, paired with
    /// `interrupt: true`.
    static let chatAboutQuestionMessage = "The user chose to chat about this question instead of answering it; wait for their message."

    /// Claude Code's own multi-select answer encoding (2.1.251, verbatim
    /// from the binary): `labels.map(t => t.includes(", ") || t.includes('"')
    /// ? JSON.stringify(t) : t).join(", ")`. On receipt Claude Code parses
    /// the string back apart (a quoted token via `JSON.parse`, a bare token
    /// by splitting on `", "`) and only recognizes the result as a listed
    /// selection if re-encoding those parsed tokens reproduces the string
    /// exactly and every token names a listed option -- so a label that
    /// itself contains `", "` or `"` MUST be JSON-string-quoted here, or
    /// Claude Code's own round-trip check silently fails to recognize the
    /// answer. This round-trip check runs ONLY for a multi-select answer
    /// (the binary's own recognition logic: `W.has(B)` -- is the raw
    /// string a member of the listed label set -- checked FIRST, and only
    /// falls through to the quoted round-trip when the question is
    /// multi-select): a single-select answer is matched against its
    /// listed labels verbatim, so this function must never be applied to
    /// one -- `encodedValue(for:)` is the only caller, and only for
    /// `.selectedMany`. Kept internal (not `private`), not because
    /// production code outside this encoder may call it -- it may not --
    /// but so a test can exercise the encoding rule directly, independent
    /// of `encodeAnswered`'s own JSON envelope. A one-element multi-select
    /// answer still goes through this function, matching Claude Code's
    /// own dialog.
    static func selectedLabelsAnswerValue(_ labels: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return labels.map { label in
            guard label.contains(", ") || label.contains("\"") else { return label }
            let quoted = try? encoder.encode(label)
            guard let quoted, let json = String(data: quoted, encoding: .utf8) else { return label }
            return json
        }.joined(separator: ", ")
    }

    /// Builds the JSON body for a CLI agent's approval-gate hook stdout,
    /// dispatching on `kind` alone to the one function that knows that
    /// kind's own vocabulary. `nil` for any `kind` other than
    /// `claude-code`/`codex`/`grok`/`pi` -- see this file's own header.
    static func body(kind: String, decision: ApprovalDecision) -> Data? {
        switch kind {
        case AgentEntry.claudeCodeKind:
            return claudeCodeBody(for: decision)
        case AgentEntry.codexKind:
            return codexBody(for: decision)
        case AgentEntry.grokKind, AgentEntry.piKind:
            return flatBody(for: decision, kind: kind)
        default:
            return nil
        }
    }

    /// Wraps `decision` in the `hookSpecificOutput{hookEventName,
    /// decision}` envelope both Claude Code and Codex document.
    private static func envelope(decision: [String: Any]) -> Data? {
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": ApprovalHookEvent.name,
                "decision": decision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// claude-code's own full vocabulary -- see this file's own header.
    private static func claudeCodeBody(for decision: ApprovalDecision) -> Data? {
        switch decision {
        case .allowed:
            return envelope(decision: ["behavior": "allow"])
        case .allowedWithPermissions(let offer):
            guard let entry = try? JSONSerialization.jsonObject(with: offer.entryJSON) else { return nil }
            return envelope(decision: ["behavior": "allow", "updatedPermissions": [entry]])
        case .denied(let reason):
            return envelope(decision: ["behavior": "deny", "message": claudeCodeDenyMessage(for: reason)])
        case .interrupted(let reason):
            return envelope(decision: [
                "behavior": "deny", "message": claudeCodeInterruptMessage(for: reason), "interrupt": true,
            ])
        case .expired, .dismissed, .allowedForView:
            // `.allowedForView` is an MCP Apps-only decision that never
            // reaches a hook response; like `.expired`, it has no
            // vocabulary here.
            return nil
        case .answered(let answers):
            return encodeAnswered(answers)
        }
    }

    private static func claudeCodeDenyMessage(for reason: DenyReason) -> String {
        switch reason {
        case .userRejected: return claudeCodeRejectedMessage
        }
    }

    private static func claudeCodeInterruptMessage(for reason: InterruptReason) -> String {
        switch reason {
        case .chatAboutQuestion: return chatAboutQuestionMessage
        }
    }

    /// codex's own vocabulary: `allow`/`deny` only, `message` always
    /// `deniedMessage`. Every decision codex fails closed on
    /// (`.allowedForView`/`.allowedWithPermissions`/`.interrupted`/
    /// `.answered`/`.dismissed`) produces `nil`, exactly like `.expired`.
    private static func codexBody(for decision: ApprovalDecision) -> Data? {
        switch decision {
        case .allowed:
            return envelope(decision: ["behavior": "allow"])
        case .denied:
            return envelope(decision: ["behavior": "deny", "message": deniedMessage])
        case .allowedForView, .allowedWithPermissions, .interrupted, .expired, .answered, .dismissed:
            return nil
        }
    }

    /// Grok's and pi's flat body: `decision` alone for an allow,
    /// `decision` plus `reason: deniedMessage` for a deny (their spelling
    /// of the field Claude Code and Codex call `message`), and an
    /// explicit deny with its own reason for an expiry. Neither kind
    /// keeps a confirmation prompt of its own to fall back to
    /// (`cliKeepsOwnPrompt(kind:)` is false for both), so every decision
    /// with no other representation here -- `.dismissed`, and every
    /// decision neither kind has ANY vocabulary for (`.allowedForView`/
    /// `.allowedWithPermissions`/`.interrupted`/`.answered`) -- routes
    /// back through `body(kind:decision:)` with `.expired`, producing
    /// bytes byte-identical to an actual expiry's own body rather than a
    /// second, separately-written deny that could drift from it.
    private static func flatBody(for decision: ApprovalDecision, kind: String) -> Data? {
        switch decision {
        case .allowed:
            return try? JSONSerialization.data(withJSONObject: ["decision": "allow"])
        case .denied:
            return try? JSONSerialization.data(withJSONObject: ["decision": "deny", "reason": deniedMessage])
        case .expired:
            return try? JSONSerialization.data(withJSONObject: [
                "decision": "deny",
                "reason": "No approval was given in the Calyx approval inbox before the request expired.",
            ])
        case .allowedForView, .allowedWithPermissions, .interrupted, .answered, .dismissed:
            return body(kind: kind, decision: .expired)
        }
    }

    /// claude-code's `.answered` body: `behavior: "allow"` plus
    /// `updatedInput` -- the original `tool_input` object (`answers.prompt.
    /// originalToolInputJSON`, re-parsed) with `"answers"` set on it, so
    /// the key set is the original keys plus `answers` (for a plain
    /// payload, exactly `questions` + `answers`) -- see this file's own
    /// header comment for why the whole object round-trips, not just
    /// `questions`. `encodedValue(for:)` is the ONE place that turns an
    /// `AgentQuestionAnswer` (free of wire encoding, see that type's own
    /// doc comment) into the string Claude Code's own hook reads.
    ///
    /// `annotations[question.text]` is built per question, added ONLY
    /// when that question's own entry contributes something: `notes`
    /// (the entry's own, already trimmed to non-nil-or-nil by
    /// `AgentQuestionFormState`) and/or `preview` (the SELECTED option's
    /// own `preview`, and ONLY for a `.selectedOne` answer -- a
    /// `.selectedMany`/`.freeText` answer never carries a preview, even
    /// when one of its options has one, since no single option was
    /// exclusively chosen). A question contributing neither is omitted
    /// from `annotations` entirely; if NO question contributes anything,
    /// the whole `annotations` key is omitted from `updatedInput`, never
    /// present-but-empty. A stale `annotations` key already on the
    /// original `tool_input` is overwritten, never merged with the fresh
    /// one -- same rule `answers` already follows.
    private static func encodeAnswered(_ answers: AgentQuestionAnswers) -> Data? {
        guard var updatedInput = try? JSONSerialization.jsonObject(with: answers.prompt.originalToolInputJSON) as? [String: Any] else {
            return nil
        }
        var answersObject: [String: String] = [:]
        var annotationsObject: [String: Any] = [:]
        for (question, entry) in zip(answers.prompt.questions, answers.entries) {
            answersObject[question.text] = encodedValue(for: entry.answer)

            var annotation: [String: Any] = [:]
            if let notes = entry.notes {
                annotation["notes"] = notes
            }
            if case .selectedOne(let label) = entry.answer,
               let preview = question.options.first(where: { $0.label == label })?.preview {
                annotation["preview"] = preview
            }
            if !annotation.isEmpty {
                annotationsObject[question.text] = annotation
            }
        }
        updatedInput["answers"] = answersObject
        if annotationsObject.isEmpty {
            updatedInput.removeValue(forKey: "annotations")
        } else {
            updatedInput["annotations"] = annotationsObject
        }

        let decision: [String: Any] = [
            "behavior": "allow",
            "updatedInput": updatedInput,
        ]
        return envelope(decision: decision)
    }

    /// The wire string for one question's answer -- the sole place this
    /// type maps `AgentQuestionAnswer` to what Claude Code's own
    /// AskUserQuestion recognition logic expects (2.1.251 binary):
    /// `.selectedOne` sends the label RAW, since a single-select answer is
    /// matched against `W` (the listed label set) verbatim; `.selectedMany`
    /// runs the labels through `selectedLabelsAnswerValue` (the quoted
    /// round-trip, which that recognition logic only falls through to for
    /// a multi-select question); `.freeText` sends the typed text RAW --
    /// free text is meant to reach the CLI unencoded, never matched
    /// against `W` at all.
    private static func encodedValue(for answer: AgentQuestionAnswer) -> String {
        switch answer {
        case .selectedOne(let label): return label
        case .selectedMany(let labels): return selectedLabelsAnswerValue(labels)
        case .freeText(let text): return text
        }
    }
}
