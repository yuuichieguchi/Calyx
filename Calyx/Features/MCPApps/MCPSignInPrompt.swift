//
//  MCPSignInPrompt.swift
//  Calyx
//
//  Asks the user to sign in to an upstream MCP server a tool call is
//  waiting on, in an `MCPPromptPanelWindow`: "<server> requires sign-in"
//  with Sign In and Cancel. `promptSignIn` returns as soon as the panel is
//  up; the waiting call keeps its own two-minute limit. A second prompt
//  for a server whose panel is still up brings that panel forward.
//
//  Sign In runs the injected sign-in (the supervisor's OAuth flow) and
//  closes the panel when it succeeds. A failure is shown in the panel,
//  which keeps Sign In and Cancel. Cancel cancels a sign-in in progress
//  and closes the panel.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class MCPSignInPrompt: MCPAuthorizationPrompting {

    private struct Prompt {
        let panel: MCPPromptPanelWindow
        let state: MCPSignInPromptState
    }

    private let signIn: @MainActor (MCPServerID) async throws -> Void
    private let windowForSurface: @MainActor (UUID) -> NSWindow?
    private var prompts: [MCPServerID: Prompt] = [:]
    private var signInTasks: [MCPServerID: Task<Void, Never>] = [:]

    /// In the app, `signIn` is `MCPUpstreamSupervisor.signIn(serverID:)`.
    init(
        signIn: @escaping @MainActor (MCPServerID) async throws -> Void,
        windowForSurface: @escaping @MainActor (UUID) -> NSWindow?
    ) {
        self.signIn = signIn
        self.windowForSurface = windowForSurface
    }

    func promptSignIn(serverID: MCPServerID, serverDisplayName: String, surfaceID: UUID?) async {
        if let existing = prompts[serverID] {
            existing.panel.orderFrontRegardless()
            return
        }
        let state = MCPSignInPromptState(serverName: serverDisplayName)
        let view = MCPSignInPromptView(
            state: state,
            onSignIn: { [weak self] in self?.startSignIn(serverID) },
            onCancel: { [weak self] in self?.cancel(serverID) }
        )
        let panel = MCPPromptPanelWindow(rootView: view)
        panel.title = "\(serverDisplayName) requires sign-in"
        prompts[serverID] = Prompt(panel: panel, state: state)
        panel.show(over: surfaceID.flatMap(windowForSurface))
    }

    private func startSignIn(_ serverID: MCPServerID) {
        guard let prompt = prompts[serverID], signInTasks[serverID] == nil else { return }
        prompt.state.phase = .signingIn
        let signIn = self.signIn
        signInTasks[serverID] = Task { [weak self] in
            do {
                try await signIn(serverID)
                self?.signInTasks[serverID] = nil
                self?.close(serverID)
            } catch {
                self?.signInTasks[serverID] = nil
                guard !Task.isCancelled else { return }
                prompt.state.phase = .failed(String(describing: error))
            }
        }
    }

    private func cancel(_ serverID: MCPServerID) {
        signInTasks.removeValue(forKey: serverID)?.cancel()
        close(serverID)
    }

    private func close(_ serverID: MCPServerID) {
        prompts.removeValue(forKey: serverID)?.panel.dismiss()
    }
}

@MainActor @Observable
final class MCPSignInPromptState {
    enum Phase: Equatable {
        case idle
        case signingIn
        case failed(String)
    }

    let serverName: String
    var phase: Phase = .idle

    init(serverName: String) {
        self.serverName = serverName
    }
}

struct MCPSignInPromptView: View {
    let state: MCPSignInPromptState
    let onSignIn: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        MCPPromptCard {
            Text("\(state.serverName) requires sign-in")
                .font(.system(size: 13, weight: .semibold))
            Text("A tool call is waiting for this MCP server. Sign in to continue.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            switch state.phase {
            case .idle:
                EmptyView()
            case .signingIn:
                Text("Complete sign-in in your browser.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text("Sign-in failed: \(reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") { onSignIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.phase == .signingIn)
                    .accessibilityIdentifier(AccessibilityID.MCPApps.signInButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MCPApps.signInContainer)
    }
}
