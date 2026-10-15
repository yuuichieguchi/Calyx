// CancellationAwareTimeout.swift
// Calyx
//
// Ends a diff computation early once the Swift task running it is
// cancelled (e.g. superseded by a newer load), in addition to its base
// timeout. The computation then returns its `hitTimeout` result, which
// the cancelled caller discards.

import Foundation

struct CancellationAwareTimeout: DiffTimeout {
    let base: any DiffTimeout

    func isValid() -> Bool {
        base.isValid() && !Task.isCancelled
    }
}
