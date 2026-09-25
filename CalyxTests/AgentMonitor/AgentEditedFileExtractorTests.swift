//
//  AgentEditedFileExtractorTests.swift
//  CalyxTests
//
//  Pins AgentEditedFileExtractor.paths(toolName:toolInput:) -- the pure
//  function that pulls the file path(s) a PreToolUse event's tool call
//  is about to touch out of its raw tool_input payload, per the mapping
//  in Calyx/Features/AgentMonitor/AgentEditedFile.swift's doc comment:
//
//  - Write / Edit / MultiEdit -> tool_input["file_path"]
//  - NotebookEdit             -> tool_input["notebook_path"]
//  - "apply_patch"            -> lines "*** Add File: p" /
//                                "*** Update File: p" / "*** Delete
//                                File: p" parsed out of the text under
//                                tool_input["input"], falling back to
//                                tool_input["patch"] when "input" is
//                                absent
//  - Read / any other tool name, a missing key, or a non-string value
//    -> []
//
//  Also pins AgentEvent.editedFilePaths, populated by both AgentEvent
//  .decode (Claude Code / Codex snake_case) and .decodeGrokShaped (Grok
//  camelCase) ONLY for a PreToolUse event -- a PostToolUse event (which
//  carries no forward-looking intent, only a completed call) must
//  always report an empty array, however its own tool_name/tool_input
//  look.
//

import XCTest
@testable import Calyx

final class AgentEditedFileExtractorTests: XCTestCase {

    // MARK: - Write / Edit / MultiEdit

    func test_write_extractsFilePath() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Write",
            toolInput: ["file_path": "/Users/dev/project/main.swift"]
        )

        XCTAssertEqual(paths, ["/Users/dev/project/main.swift"])
    }

    func test_edit_extractsFilePath() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Edit",
            toolInput: ["file_path": "/Users/dev/project/README.md"]
        )

        XCTAssertEqual(paths, ["/Users/dev/project/README.md"])
    }

    func test_multiEdit_extractsFilePath() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "MultiEdit",
            toolInput: ["file_path": "/Users/dev/project/Sources/App.swift"]
        )

        XCTAssertEqual(paths, ["/Users/dev/project/Sources/App.swift"])
    }

    // MARK: - NotebookEdit

    func test_notebookEdit_extractsNotebookPath() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "NotebookEdit",
            toolInput: ["notebook_path": "/Users/dev/project/analysis.ipynb"]
        )

        XCTAssertEqual(paths, ["/Users/dev/project/analysis.ipynb"])
    }

    /// NotebookEdit must read its own key, never fall back to Write's.
    func test_notebookEdit_ignoresFilePathKey() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "NotebookEdit",
            toolInput: ["file_path": "/Users/dev/project/wrong.ipynb"]
        )

        XCTAssertEqual(paths, [])
    }

    // MARK: - Read / unknown tools

    func test_read_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Read",
            toolInput: ["file_path": "/Users/dev/project/main.swift"]
        )

        XCTAssertEqual(paths, [])
    }

    func test_unknownTool_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Bash",
            toolInput: ["command": "ls -la"]
        )

        XCTAssertEqual(paths, [])
    }

    // MARK: - Missing key / non-string value

    func test_write_missingFilePathKey_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Write",
            toolInput: ["content": "package main"]
        )

        XCTAssertEqual(paths, [])
    }

    func test_write_nonStringFilePathValue_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "Write",
            toolInput: ["file_path": 42]
        )

        XCTAssertEqual(paths, [])
    }

    // MARK: - apply_patch

    /// The canonical Codex envelope shape: the patch body lives under
    /// "input". Three files across the three verbs, in document order --
    /// proves ordering is preserved, not just membership.
    func test_applyPatch_fromInputKey_extractsAddUpdateDeletePaths() {
        let patchBody = """
        *** Begin Patch
        *** Add File: Sources/New.swift
        +new content
        *** Update File: Sources/Existing.swift
        @@
        -old line
        +new line
        *** Delete File: Sources/Obsolete.swift
        *** End Patch
        """

        let paths = AgentEditedFileExtractor.paths(
            toolName: "apply_patch",
            toolInput: ["input": patchBody]
        )

        XCTAssertEqual(paths, [
            "Sources/New.swift",
            "Sources/Existing.swift",
            "Sources/Obsolete.swift",
        ])
    }

    /// When "input" is absent, "patch" is the fallback key.
    func test_applyPatch_fallsBackToPatchKey_whenInputKeyMissing() {
        let patchBody = """
        *** Begin Patch
        *** Update File: Sources/Existing.swift
        @@
        -old
        +new
        *** End Patch
        """

        let paths = AgentEditedFileExtractor.paths(
            toolName: "apply_patch",
            toolInput: ["patch": patchBody]
        )

        XCTAssertEqual(paths, ["Sources/Existing.swift"])
    }

    /// Neither "input" nor "patch" is present: degrades to no conflict
    /// line rather than crashing or guessing.
    func test_applyPatch_missingBothKeys_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "apply_patch",
            toolInput: ["unrelated": "value"]
        )

        XCTAssertEqual(paths, [])
    }

    /// A patch body naming no Add/Update/Delete line (e.g. malformed or
    /// empty) extracts no paths.
    func test_applyPatch_bodyWithNoRecognizedLines_returnsEmpty() {
        let paths = AgentEditedFileExtractor.paths(
            toolName: "apply_patch",
            toolInput: ["input": "*** Begin Patch\n*** End Patch"]
        )

        XCTAssertEqual(paths, [])
    }

    // MARK: - AgentEvent.editedFilePaths (snake_case decoder)

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func test_agentEvent_decode_preToolUseWrite_populatesEditedFilePaths() {
        let object: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "cwd": "/Users/dev/project",
            "tool_name": "Write",
            "tool_input": ["file_path": "/Users/dev/project/main.swift"],
        ]

        let event = AgentEvent.decode(from: jsonData(object))

        XCTAssertEqual(event?.editedFilePaths, ["/Users/dev/project/main.swift"])
    }

    /// PostToolUse carries a completed (not forward-looking) call --
    /// editedFilePaths must stay empty even though tool_name/tool_input
    /// name a real file-editing call.
    func test_agentEvent_decode_postToolUseWrite_editedFilePathsIsEmpty() {
        let object: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": "session-1",
            "cwd": "/Users/dev/project",
            "tool_name": "Write",
            "tool_input": ["file_path": "/Users/dev/project/main.swift"],
        ]

        let event = AgentEvent.decode(from: jsonData(object))

        XCTAssertEqual(event?.editedFilePaths, [])
    }

    /// A PreToolUse event for a non-file-editing tool (e.g. Read) must
    /// also report an empty array -- editedFilePaths reuses the same
    /// per-tool mapping as AgentEditedFileExtractor.paths, not "any
    /// PreToolUse populates something".
    func test_agentEvent_decode_preToolUseRead_editedFilePathsIsEmpty() {
        let object: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "cwd": "/Users/dev/project",
            "tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/main.swift"],
        ]

        let event = AgentEvent.decode(from: jsonData(object))

        XCTAssertEqual(event?.editedFilePaths, [])
    }

    // MARK: - AgentEvent.editedFilePaths (Grok camelCase decoder)

    func test_agentEvent_decodeGrokShaped_preToolUseWrite_populatesEditedFilePaths() {
        let object: [String: Any] = [
            "hookEventName": "pre_tool_use",
            "sessionId": "session-1",
            "cwd": "/Users/dev/project",
            "toolName": "Write",
            "toolInput": ["file_path": "/Users/dev/project/grok.swift"],
        ]

        let event = AgentEvent.decode(from: jsonData(object))

        XCTAssertEqual(event?.editedFilePaths, ["/Users/dev/project/grok.swift"])
    }

    func test_agentEvent_decodeGrokShaped_postToolUseWrite_editedFilePathsIsEmpty() {
        let object: [String: Any] = [
            "hookEventName": "post_tool_use",
            "sessionId": "session-1",
            "cwd": "/Users/dev/project",
            "toolName": "Write",
            "toolInput": ["file_path": "/Users/dev/project/grok.swift"],
        ]

        let event = AgentEvent.decode(from: jsonData(object))

        XCTAssertEqual(event?.editedFilePaths, [])
    }
}
