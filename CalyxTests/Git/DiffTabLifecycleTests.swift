// DiffTabLifecycleTests.swift
// CalyxTests
//
// Tests for diff tab lifecycle: GitChangesState transitions, SidebarMode, DiffSource dedup.

import Testing
@testable import Calyx

@MainActor
struct DiffTabLifecycleTests {
    @Test func gitChangesStateTransitions() {
        let session = WindowSession()
        if case .notLoaded = session.gitChangesState {} else {
            Issue.record("Expected initial state .notLoaded")
        }

        session.gitChangesState = .loading
        if case .loading = session.gitChangesState {} else {
            Issue.record("Expected .loading")
        }

        session.gitChangesState = .loaded
        if case .loaded = session.gitChangesState {} else {
            Issue.record("Expected .loaded")
        }
    }

    @Test func gitChangesStateNotRepository() {
        let session = WindowSession()
        session.gitChangesState = .loading
        session.gitChangesState = .notRepository
        if case .notRepository = session.gitChangesState {} else {
            Issue.record("Expected .notRepository")
        }
    }

    @Test func gitChangesStateError() {
        let session = WindowSession()
        session.gitChangesState = .error("test error")
        if case .error(let msg) = session.gitChangesState {
            #expect(msg == "test error")
        } else {
            Issue.record("Expected .error")
        }
    }

    @Test func sidebarModeToggle() {
        let session = WindowSession()
        #expect(session.sidebarMode == .tabs)
        session.sidebarMode = .changes
        #expect(session.sidebarMode == .changes)
        session.sidebarMode = .tabs
        #expect(session.sidebarMode == .tabs)
    }

    @Test func diffSourceDedup() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/repo")
        #expect(a != c)

        let d = DiffSource.commit(hash: "abc", path: "foo.swift", workDir: "/repo")
        #expect(a != d)
    }
}
