// SessionKillTracker.swift
// Calyx
//
// Tracks `SessionDaemonClient.kill(id:)` calls dispatched as
// fire-and-forget `Task`s (from `CalyxWindowController
// .killSessionIfPersistent`) so `AppDelegate.applicationWillTerminate`
// can wait — briefly — for them to finish before the process actually
// exits. Without this, an explicit pane close immediately followed by
// Cmd+Q could have its kill Task torn down mid-`Process` spawn,
// silently leaving the calyx-session running as an orphan even though
// the user asked to end it.
//
// `@MainActor`-isolated because every caller (`killSessionIfPersistent`,
// `applicationWillTerminate`) already runs on the main actor.

import Foundation

@MainActor
enum SessionKillTracker {
    private static var pendingTasks: [Task<Void, Never>] = []

    /// Runs `operation` as a tracked, fire-and-forget `Task`.
    static func track(_ operation: @escaping () async -> Void) {
        pendingTasks.append(Task { await operation() })
    }

    /// Waits for every currently-tracked kill to finish, bounded by
    /// `timeoutSeconds` — whichever finishes first. Safe to call with
    /// nothing pending (returns immediately). Clears the tracked list
    /// regardless of whether the wait completed or timed out, since a
    /// still-running kill past the timeout is abandoned exactly like
    /// today's untracked fire-and-forget behavior.
    static func drain(timeoutSeconds: Double) async {
        let tasks = pendingTasks
        pendingTasks = []
        guard !tasks.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks {
                    _ = await task.value
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
            }
            await group.next()
            group.cancelAll()
        }
    }
}
