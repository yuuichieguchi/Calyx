//
//  IPCActivationResultFixtures.swift
//  CalyxTests
//
//  Shared IPCConfigResult / AgentHooksResult builders for the IPC
//  coordinator and config manager tests: every axis skipped by
//  default, only the axes a test cares about overridden.
//  One copy so this fixture's own axis list stays in lockstep with
//  IPCConfigResult.axes / AgentHooksResult.axes -- the same reason those
//  two collapsed their own six duplicated per-agent lists down to one
//  each; two independently maintained copies here would silently
//  reintroduce that problem one level up.
//

import Foundation
@testable import Calyx

/// Builds an IPCConfigResult with every axis skipped by default,
/// overriding only the axes a test cares about.
func configResult(
    claudeCode: ConfigStatus = .skipped(reason: "not installed"),
    codex: ConfigStatus = .skipped(reason: "not installed"),
    openCode: ConfigStatus = .skipped(reason: "not installed"),
    hermes: ConfigStatus = .skipped(reason: "not installed"),
    grok: ConfigStatus = .skipped(reason: "not installed")
) -> IPCConfigResult {
    IPCConfigResult(claudeCode: claudeCode, codex: codex, openCode: openCode, hermes: hermes, grok: grok)
}

/// Builds an AgentHooksResult with every axis skipped by default,
/// overriding only the axes a test cares about.
func hooksResult(
    claudeCode: ConfigStatus = .skipped(reason: "not installed"),
    codex: ConfigStatus = .skipped(reason: "not installed"),
    openCode: ConfigStatus = .skipped(reason: "not installed"),
    grok: ConfigStatus = .skipped(reason: "not installed"),
    pi: ConfigStatus = .skipped(reason: "not installed")
) -> AgentHooksResult {
    AgentHooksResult(claudeCode: claudeCode, codex: codex, openCode: openCode, grok: grok, pi: pi)
}
