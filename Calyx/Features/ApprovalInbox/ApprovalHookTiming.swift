// ApprovalHookTiming.swift
// Calyx
//
// Single source of truth for the timing constants that must nest
// strictly inside one another across the whole approval-inbox-for-
// CLI-agents hook chain: Calyx's own long-poll timeout must resolve
// before the hook script's own curl `-m` deadline gives up on it,
// which itself must fire before the CLI agent's own hook-entry
// timeout kills the whole hook process outright. Getting this nesting
// wrong in either direction produces a user-visible failure at the
// wrong layer:
//
// - If curl's timeout were <= the server's, curl would give up while
//   Calyx is still legitimately waiting on a human decision, and the
//   hook would report a spurious network failure even though the
//   server would have answered (with the fail-safe body, at worst) a
//   few seconds later.
// - If the CLI's own hook-entry timeout were <= curl's, the CLI agent
//   (Claude Code / Codex) would kill the hook process before curl's own
//   `-m` deadline ever gets a chance to fire and print the fail-safe
//   body -- the hook simply vanishes with no output at all, and the
//   CLI falls back to its own in-pane prompt with no reason surfaced.
//
// So the invariant this file exists to enforce is:
//     serverTimeoutMs < curlTimeoutSeconds * 1000 < hookEntryTimeoutSeconds * 1000
//
// `holdSeconds` (600s -- Claude Code's and Codex's own default
// PreToolUse hook timeout) is the one constant that isn't ours to
// choose; everything else is derived backward from it, each with
// enough margin for the layer below to have already given up before it
// does. On total failure of the whole chain (server unreachable, or
// every deadline above blown), the CLI's hook runner treats the hook as
// having produced no usable decision and falls back to its own
// in-pane prompt -- Calyx never silently allows anything by going
// missing.
//
// See CalyxMCPServerApprovalRequestTests.test_timing_constants_orderingInvariant
// for the specced ordering assertions.

import Foundation

enum ApprovalHookTiming {
    /// Claude Code's and Codex's own default PreToolUse hook timeout, in
    /// seconds -- the outermost deadline in the chain, and the value
    /// every other constant here is derived backward from. Configurable
    /// per-hook entry in both CLIs; Calyx's own injected approval-hook
    /// entry (`ClaudeHooksConfigManager.approvalCommandEntry` /
    /// `CodexHooksConfigManager`'s equivalent) DOES write an explicit
    /// `timeout` value for it, rather than leaving it as an unspecified
    /// CLI default -- but that written value is itself
    /// `hookEntryTimeoutSeconds`, i.e. this same 600, so the nesting
    /// invariant below still holds regardless.
    static let holdSeconds = 600

    /// `CalyxMCPServer.approvalRequestTimeoutMs`'s default: the
    /// server's own `POST /approval-request` long-poll timeout, in
    /// milliseconds. 30s of margin under `holdSeconds * 1000` so the
    /// server always answers -- even if only with the fail-safe
    /// `.expired` mapping -- strictly before curl's own deadline below
    /// would otherwise give up on it.
    static let serverTimeoutMs = holdSeconds * 1000 - 30_000

    /// The `calyx-approval-hook` script's own curl `-m` deadline, in
    /// seconds. 15s of margin under `holdSeconds` so curl gives up (and
    /// the hook can still fall back to its own fail-safe "ask" output)
    /// strictly after the server has already answered, and strictly
    /// before the CLI's own hook-entry timeout below would kill the
    /// hook process outright.
    static let curlTimeoutSeconds = holdSeconds - 15

    /// The CLI's own hook-entry timeout that kills the hook process if
    /// it hasn't exited by then -- restated here (equal to
    /// `holdSeconds`) purely so every link of the nesting invariant has
    /// its own named constant to compare against.
    static let hookEntryTimeoutSeconds = holdSeconds
}
