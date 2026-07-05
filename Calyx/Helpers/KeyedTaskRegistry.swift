// KeyedTaskRegistry.swift
// Calyx
//
// Round-18 cleanup: CalyxWindowController.swift had FOUR hand-rolled
// copies of the same keyed-Task-dictionary idiom (diffTasks,
// expandTasks, childExitedTasks, reconnectEstablishGraceTasks), each
// duplicating cancel-before-replace, self-removal-on-completion, and
// cancel-all-on-window-close. Consolidated here, mirroring
// ProcessCancellationBridge.swift's placement/doc style, so a future fix
// to this discipline only has to land in one place.

import Foundation

/// A `[Key: Task<Void, Never>]` store following the cancel-before-
/// replace/cancel-all discipline `CalyxWindowController`'s per-window
/// `Task` dictionaries share: `insert(_:task:)` cancels any `Task`
/// already stored at `key` before replacing it (cheap insurance against
/// a same-key re-insert leaking the previous `Task`); each stored
/// `Task`'s own body is responsible for calling `removeValue(forKey:)`
/// once it completes, so a finished entry isn't retained forever;
/// `cancelAll()` cancels every stored `Task` and clears the dictionary,
/// for use at window teardown. The subscript setter is a plain,
/// non-cancelling store for the rare call site that must NOT cancel an
/// existing entry at the same key (see each such call site's own doc
/// comment for why) — prefer `insert(_:task:)` unless a call site has a
/// documented reason not to.
struct KeyedTaskRegistry<Key: Hashable> {
    private var tasks: [Key: Task<Void, Never>] = [:]

    /// Cancels any `Task` already stored at `key`, then stores `task` in
    /// its place.
    mutating func insert(_ key: Key, task: Task<Void, Never>) {
        tasks[key]?.cancel()
        tasks[key] = task
    }

    mutating func removeValue(forKey key: Key) {
        tasks.removeValue(forKey: key)
    }

    /// Cancels every stored `Task` and clears the dictionary.
    mutating func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    subscript(key: Key) -> Task<Void, Never>? {
        get { tasks[key] }
        set { tasks[key] = newValue }
    }
}
