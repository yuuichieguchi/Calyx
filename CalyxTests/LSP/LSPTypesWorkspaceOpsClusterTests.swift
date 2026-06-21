//
//  LSPTypesWorkspaceOpsClusterTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 "workspace operations" feature
//  cluster:
//
//    Pull Diagnostics      (textDocument/diagnostic, workspace/diagnostic)
//      - DocumentDiagnosticParams
//      - DocumentDiagnosticReportKind                 ("full" | "unchanged")
//      - RelatedFullDocumentDiagnosticReport
//      - RelatedUnchangedDocumentDiagnosticReport
//      - RelatedDocumentDiagnosticReport              (union: full | unchanged)
//      - DocumentDiagnosticReport                     (union: full | unchanged)
//      - PreviousResultId
//      - WorkspaceDiagnosticParams
//      - WorkspaceFullDocumentDiagnosticReport
//      - WorkspaceUnchangedDocumentDiagnosticReport
//      - WorkspaceDocumentDiagnosticReport            (union: full | unchanged)
//      - WorkspaceDiagnosticReport
//
//    Execute Command       (workspace/executeCommand)
//      - ExecuteCommandParams
//
//    Apply Workspace Edit  (workspace/applyEdit)
//      - ApplyWorkspaceEditParams
//      - ApplyWorkspaceEditResult
//
//    Configuration         (workspace/configuration)
//      - ConfigurationParams
//      - ConfigurationItem
//
//    File Operations       (workspace/{willCreate,didCreate,willRename,didRename,
//                                     willDelete,didDelete}Files)
//      - FileCreate
//      - CreateFilesParams
//      - FileRename
//      - RenameFilesParams
//      - FileDelete
//      - DeleteFilesParams
//      - FileOperationFilter
//      - FileOperationPattern
//      - FileOperationPatternKind                     ("file" | "folder")
//      - FileOperationPatternOptions
//      - FileOperationRegistrationOptions
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//
//  Re-uses already-defined types:
//    - TextDocumentIdentifier
//    - Diagnostic
//    - DocumentUri
//    - ProgressToken
//    - WorkspaceEdit
//    - AnyCodable
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesWorkspaceOpsClusterTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Parse a JSON string literal into a Foundation object for semantic
    /// comparison via NSObject equality.
    private func parse(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Encode an Encodable value to a Foundation object (dict / array / scalar).
    private func toJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Assert that decoding `json` into `T` and re-encoding produces semantically
    /// equivalent JSON (NSObject equality on the parsed Foundation graph).
    private func assertRoundtrip<T: Codable>(
        _ type: T.Type,
        json: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let data = Data(json.utf8)
        let decoded = try decoder.decode(T.self, from: data)
        let reencoded = try toJSONObject(decoded) as AnyObject
        let original = try parse(json) as AnyObject
        XCTAssertTrue(
            reencoded.isEqual(original),
            "Round-trip mismatch for \(T.self):\n  reencoded=\(reencoded)\n  original=\(original)",
            file: file, line: line
        )
    }

    // ====================================================================
    // MARK: - DocumentDiagnosticParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_diagnostic
    // ====================================================================

    func test_documentDiagnosticParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/a.swift"}}
        """#
        try assertRoundtrip(DocumentDiagnosticParams.self, json: json)
    }

    func test_documentDiagnosticParams_full_roundtrip() throws {
        let json = #"""
        {
          "identifier":"swiftc",
          "partialResultToken":"part-1",
          "previousResultId":"prev-42",
          "textDocument":{"uri":"file:///tmp/a.swift"},
          "workDoneToken":7
        }
        """#
        try assertRoundtrip(DocumentDiagnosticParams.self, json: json)
    }

    func test_documentDiagnosticParams_decodesFields() throws {
        let json = #"""
        {
          "identifier":"id-1",
          "previousResultId":"r-9",
          "textDocument":{"uri":"file:///x.swift"}
        }
        """#
        let decoded = try decoder.decode(
            DocumentDiagnosticParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.textDocument.uri, "file:///x.swift")
        XCTAssertEqual(decoded.identifier, "id-1")
        XCTAssertEqual(decoded.previousResultId, "r-9")
        XCTAssertNil(decoded.workDoneToken)
        XCTAssertNil(decoded.partialResultToken)
    }

    // ====================================================================
    // MARK: - DocumentDiagnosticReportKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentDiagnosticReportKind
    // ====================================================================

    func test_documentDiagnosticReportKind_full_roundtrip() throws {
        let raw = try encoder.encode(DocumentDiagnosticReportKind.full)
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"full\"")
        let decoded = try decoder.decode(
            DocumentDiagnosticReportKind.self,
            from: Data("\"full\"".utf8)
        )
        XCTAssertEqual(decoded, .full)
    }

    func test_documentDiagnosticReportKind_unchanged_roundtrip() throws {
        let raw = try encoder.encode(DocumentDiagnosticReportKind.unchanged)
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"unchanged\"")
        let decoded = try decoder.decode(
            DocumentDiagnosticReportKind.self,
            from: Data("\"unchanged\"".utf8)
        )
        XCTAssertEqual(decoded, .unchanged)
    }

    // ====================================================================
    // MARK: - RelatedFullDocumentDiagnosticReport
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#relatedFullDocumentDiagnosticReport
    // ====================================================================

    func test_relatedFullDocumentDiagnosticReport_minimal_roundtrip() throws {
        // The `kind` field is the spec-required discriminator and is always present.
        let json = #"""
        {"items":[],"kind":"full"}
        """#
        try assertRoundtrip(RelatedFullDocumentDiagnosticReport.self, json: json)
    }

    func test_relatedFullDocumentDiagnosticReport_withItems_roundtrip() throws {
        let json = #"""
        {
          "items":[
            {
              "message":"unused variable",
              "range":{"end":{"character":7,"line":3},"start":{"character":4,"line":3}},
              "severity":2,
              "source":"swiftc"
            }
          ],
          "kind":"full",
          "resultId":"r-1"
        }
        """#
        try assertRoundtrip(RelatedFullDocumentDiagnosticReport.self, json: json)
    }

    func test_relatedFullDocumentDiagnosticReport_withRelatedDocuments_roundtrip() throws {
        // `relatedDocuments` maps a DocumentUri to a (full|unchanged) report.
        let json = #"""
        {
          "items":[],
          "kind":"full",
          "relatedDocuments":{
            "file:///tmp/header.h":{"kind":"unchanged","resultId":"r-99"}
          }
        }
        """#
        try assertRoundtrip(RelatedFullDocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - RelatedUnchangedDocumentDiagnosticReport
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#relatedUnchangedDocumentDiagnosticReport
    // ====================================================================

    func test_relatedUnchangedDocumentDiagnosticReport_minimal_roundtrip() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-42"}
        """#
        try assertRoundtrip(RelatedUnchangedDocumentDiagnosticReport.self, json: json)
    }

    func test_relatedUnchangedDocumentDiagnosticReport_withRelatedDocuments_roundtrip() throws {
        let json = #"""
        {
          "kind":"unchanged",
          "relatedDocuments":{
            "file:///tmp/b.swift":{"items":[],"kind":"full","resultId":"sub-1"}
          },
          "resultId":"r-77"
        }
        """#
        try assertRoundtrip(RelatedUnchangedDocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - RelatedDocumentDiagnosticReport union
    // Discriminator: kind == "full" => .full ; kind == "unchanged" => .unchanged.
    // ====================================================================

    func test_relatedDocumentDiagnosticReport_full_decodes() throws {
        let json = #"""
        {"items":[],"kind":"full","resultId":"r-1"}
        """#
        let decoded = try decoder.decode(
            RelatedDocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .full(let resultId, let items) = decoded else {
            XCTFail("Expected .full case")
            return
        }
        XCTAssertEqual(resultId, "r-1")
        XCTAssertEqual(items.count, 0)
    }

    func test_relatedDocumentDiagnosticReport_unchanged_decodes() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-7"}
        """#
        let decoded = try decoder.decode(
            RelatedDocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .unchanged(let resultId) = decoded else {
            XCTFail("Expected .unchanged case")
            return
        }
        XCTAssertEqual(resultId, "r-7")
    }

    func test_relatedDocumentDiagnosticReport_full_roundtrip() throws {
        let json = #"""
        {"items":[],"kind":"full"}
        """#
        try assertRoundtrip(RelatedDocumentDiagnosticReport.self, json: json)
    }

    func test_relatedDocumentDiagnosticReport_unchanged_roundtrip() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-x"}
        """#
        try assertRoundtrip(RelatedDocumentDiagnosticReport.self, json: json)
    }

    func test_relatedDocumentDiagnosticReport_unknownKind_throws() {
        let json = #"""
        {"kind":"bogus"}
        """#
        XCTAssertThrowsError(try decoder.decode(
            RelatedDocumentDiagnosticReport.self,
            from: Data(json.utf8)
        ))
    }

    // ====================================================================
    // MARK: - DocumentDiagnosticReport union
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentDiagnosticReport
    // ====================================================================

    func test_documentDiagnosticReport_full_decodes() throws {
        let json = #"""
        {"items":[],"kind":"full","resultId":"r-1"}
        """#
        let decoded = try decoder.decode(
            DocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .full(let report) = decoded else {
            XCTFail("Expected .full case")
            return
        }
        XCTAssertEqual(report.resultId, "r-1")
        XCTAssertEqual(report.items.count, 0)
    }

    func test_documentDiagnosticReport_unchanged_decodes() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-9"}
        """#
        let decoded = try decoder.decode(
            DocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .unchanged(let report) = decoded else {
            XCTFail("Expected .unchanged case")
            return
        }
        XCTAssertEqual(report.resultId, "r-9")
    }

    func test_documentDiagnosticReport_full_roundtrip() throws {
        let json = #"""
        {
          "items":[
            {
              "message":"oops",
              "range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}
            }
          ],
          "kind":"full"
        }
        """#
        try assertRoundtrip(DocumentDiagnosticReport.self, json: json)
    }

    func test_documentDiagnosticReport_unchanged_roundtrip() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-3"}
        """#
        try assertRoundtrip(DocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - PreviousResultId
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#previousResultId
    // ====================================================================

    func test_previousResultId_roundtrip() throws {
        let json = #"""
        {"uri":"file:///tmp/a.swift","value":"r-42"}
        """#
        try assertRoundtrip(PreviousResultId.self, json: json)
    }

    func test_previousResultId_directConstruction() {
        let p = PreviousResultId(uri: "file:///x", value: "vx")
        XCTAssertEqual(p.uri, "file:///x")
        XCTAssertEqual(p.value, "vx")
    }

    // ====================================================================
    // MARK: - WorkspaceDiagnosticParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_diagnostic
    // ====================================================================

    func test_workspaceDiagnosticParams_minimal_roundtrip() throws {
        let json = #"""
        {"previousResultIds":[]}
        """#
        try assertRoundtrip(WorkspaceDiagnosticParams.self, json: json)
    }

    func test_workspaceDiagnosticParams_full_roundtrip() throws {
        let json = #"""
        {
          "identifier":"global",
          "partialResultToken":3,
          "previousResultIds":[
            {"uri":"file:///tmp/a.swift","value":"a-1"},
            {"uri":"file:///tmp/b.swift","value":"b-1"}
          ],
          "workDoneToken":"wd-1"
        }
        """#
        try assertRoundtrip(WorkspaceDiagnosticParams.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceFullDocumentDiagnosticReport
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFullDocumentDiagnosticReport
    // ====================================================================

    func test_workspaceFullDocumentDiagnosticReport_minimal_roundtrip() throws {
        let json = #"""
        {"items":[],"kind":"full","uri":"file:///tmp/a.swift"}
        """#
        try assertRoundtrip(WorkspaceFullDocumentDiagnosticReport.self, json: json)
    }

    func test_workspaceFullDocumentDiagnosticReport_withVersionAndResultId_roundtrip() throws {
        let json = #"""
        {
          "items":[
            {
              "message":"bad",
              "range":{"end":{"character":1,"line":0},"start":{"character":0,"line":0}}
            }
          ],
          "kind":"full",
          "resultId":"r-5",
          "uri":"file:///tmp/a.swift",
          "version":12
        }
        """#
        try assertRoundtrip(WorkspaceFullDocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceUnchangedDocumentDiagnosticReport
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceUnchangedDocumentDiagnosticReport
    // ====================================================================

    func test_workspaceUnchangedDocumentDiagnosticReport_minimal_roundtrip() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-1","uri":"file:///tmp/a.swift"}
        """#
        try assertRoundtrip(WorkspaceUnchangedDocumentDiagnosticReport.self, json: json)
    }

    func test_workspaceUnchangedDocumentDiagnosticReport_withVersion_roundtrip() throws {
        let json = #"""
        {
          "kind":"unchanged",
          "resultId":"r-7",
          "uri":"file:///tmp/b.swift",
          "version":3
        }
        """#
        try assertRoundtrip(WorkspaceUnchangedDocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceDocumentDiagnosticReport union
    // ====================================================================

    func test_workspaceDocumentDiagnosticReport_full_decodes() throws {
        let json = #"""
        {"items":[],"kind":"full","uri":"file:///x.swift","version":2}
        """#
        let decoded = try decoder.decode(
            WorkspaceDocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .full(let r) = decoded else {
            XCTFail("Expected .full case")
            return
        }
        XCTAssertEqual(r.uri, "file:///x.swift")
        XCTAssertEqual(r.version, 2)
    }

    func test_workspaceDocumentDiagnosticReport_unchanged_decodes() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-1","uri":"file:///y.swift"}
        """#
        let decoded = try decoder.decode(
            WorkspaceDocumentDiagnosticReport.self,
            from: Data(json.utf8)
        )
        guard case .unchanged(let r) = decoded else {
            XCTFail("Expected .unchanged case")
            return
        }
        XCTAssertEqual(r.resultId, "r-1")
        XCTAssertEqual(r.uri, "file:///y.swift")
        XCTAssertNil(r.version)
    }

    func test_workspaceDocumentDiagnosticReport_full_roundtrip() throws {
        let json = #"""
        {"items":[],"kind":"full","uri":"file:///x.swift"}
        """#
        try assertRoundtrip(WorkspaceDocumentDiagnosticReport.self, json: json)
    }

    func test_workspaceDocumentDiagnosticReport_unchanged_roundtrip() throws {
        let json = #"""
        {"kind":"unchanged","resultId":"r-1","uri":"file:///y.swift","version":5}
        """#
        try assertRoundtrip(WorkspaceDocumentDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceDiagnosticReport
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceDiagnosticReport
    // ====================================================================

    func test_workspaceDiagnosticReport_empty_roundtrip() throws {
        let json = #"""
        {"items":[]}
        """#
        try assertRoundtrip(WorkspaceDiagnosticReport.self, json: json)
    }

    func test_workspaceDiagnosticReport_mixed_roundtrip() throws {
        let json = #"""
        {
          "items":[
            {"items":[],"kind":"full","uri":"file:///tmp/a.swift"},
            {"kind":"unchanged","resultId":"r-2","uri":"file:///tmp/b.swift","version":4}
          ]
        }
        """#
        try assertRoundtrip(WorkspaceDiagnosticReport.self, json: json)
    }

    // ====================================================================
    // MARK: - ExecuteCommandParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_executeCommand
    // ====================================================================

    func test_executeCommandParams_minimal_roundtrip() throws {
        let json = #"""
        {"command":"calyx.format"}
        """#
        try assertRoundtrip(ExecuteCommandParams.self, json: json)
    }

    func test_executeCommandParams_withArguments_roundtrip() throws {
        let json = #"""
        {
          "arguments":["file:///tmp/a.swift",42,{"opt":true}],
          "command":"calyx.refactor",
          "workDoneToken":"cmd-1"
        }
        """#
        try assertRoundtrip(ExecuteCommandParams.self, json: json)
    }

    func test_executeCommandParams_decodesFields() throws {
        let json = #"""
        {"arguments":["a","b"],"command":"do.it"}
        """#
        let decoded = try decoder.decode(
            ExecuteCommandParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.command, "do.it")
        XCTAssertEqual(decoded.arguments?.count, 2)
        XCTAssertNil(decoded.workDoneToken)
    }

    // ====================================================================
    // MARK: - ApplyWorkspaceEditParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit
    // ====================================================================

    func test_applyWorkspaceEditParams_minimal_roundtrip() throws {
        let json = #"""
        {"edit":{}}
        """#
        try assertRoundtrip(ApplyWorkspaceEditParams.self, json: json)
    }

    func test_applyWorkspaceEditParams_withLabelAndChanges_roundtrip() throws {
        let json = #"""
        {
          "edit":{
            "changes":{
              "file:///tmp/a.swift":[
                {"newText":"foo","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
              ]
            }
          },
          "label":"Rename foo"
        }
        """#
        try assertRoundtrip(ApplyWorkspaceEditParams.self, json: json)
    }

    // ====================================================================
    // MARK: - ApplyWorkspaceEditResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#applyWorkspaceEditResult
    // ====================================================================

    func test_applyWorkspaceEditResult_appliedTrue_roundtrip() throws {
        let json = #"""
        {"applied":true}
        """#
        try assertRoundtrip(ApplyWorkspaceEditResult.self, json: json)
    }

    func test_applyWorkspaceEditResult_appliedFalse_roundtrip() throws {
        let json = #"""
        {"applied":false,"failureReason":"file was locked"}
        """#
        try assertRoundtrip(ApplyWorkspaceEditResult.self, json: json)
    }

    func test_applyWorkspaceEditResult_full_roundtrip() throws {
        let json = #"""
        {
          "applied":false,
          "failedChange":2,
          "failureReason":"change index out of range"
        }
        """#
        try assertRoundtrip(ApplyWorkspaceEditResult.self, json: json)
    }

    func test_applyWorkspaceEditResult_directConstruction() {
        let r = ApplyWorkspaceEditResult(
            applied: false,
            failureReason: "boom",
            failedChange: 1
        )
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.failureReason, "boom")
        XCTAssertEqual(r.failedChange, 1)
    }

    // ====================================================================
    // MARK: - ConfigurationParams / ConfigurationItem
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration
    // ====================================================================

    func test_configurationParams_empty_roundtrip() throws {
        let json = #"""
        {"items":[]}
        """#
        try assertRoundtrip(ConfigurationParams.self, json: json)
    }

    func test_configurationParams_full_roundtrip() throws {
        let json = #"""
        {
          "items":[
            {"scopeUri":"file:///tmp/proj","section":"editor"},
            {"section":"calyx"},
            {}
          ]
        }
        """#
        try assertRoundtrip(ConfigurationParams.self, json: json)
    }

    func test_configurationItem_minimal_roundtrip() throws {
        let json = #"""
        {}
        """#
        try assertRoundtrip(ConfigurationItem.self, json: json)
    }

    func test_configurationItem_full_roundtrip() throws {
        let json = #"""
        {"scopeUri":"file:///tmp/proj","section":"calyx.lsp"}
        """#
        try assertRoundtrip(ConfigurationItem.self, json: json)
    }

    // ====================================================================
    // MARK: - File Operations: Create / Rename / Delete
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willCreateFiles
    //       https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willRenameFiles
    //       https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willDeleteFiles
    // ====================================================================

    func test_fileCreate_roundtrip() throws {
        let json = #"""
        {"uri":"file:///tmp/new.swift"}
        """#
        try assertRoundtrip(FileCreate.self, json: json)
    }

    func test_createFilesParams_empty_roundtrip() throws {
        let json = #"""
        {"files":[]}
        """#
        try assertRoundtrip(CreateFilesParams.self, json: json)
    }

    func test_createFilesParams_multiple_roundtrip() throws {
        let json = #"""
        {
          "files":[
            {"uri":"file:///tmp/a.swift"},
            {"uri":"file:///tmp/b.swift"}
          ]
        }
        """#
        try assertRoundtrip(CreateFilesParams.self, json: json)
    }

    func test_fileRename_roundtrip() throws {
        let json = #"""
        {"newUri":"file:///tmp/new.swift","oldUri":"file:///tmp/old.swift"}
        """#
        try assertRoundtrip(FileRename.self, json: json)
    }

    func test_renameFilesParams_roundtrip() throws {
        let json = #"""
        {
          "files":[
            {"newUri":"file:///tmp/new.swift","oldUri":"file:///tmp/old.swift"}
          ]
        }
        """#
        try assertRoundtrip(RenameFilesParams.self, json: json)
    }

    func test_fileDelete_roundtrip() throws {
        let json = #"""
        {"uri":"file:///tmp/gone.swift"}
        """#
        try assertRoundtrip(FileDelete.self, json: json)
    }

    func test_deleteFilesParams_roundtrip() throws {
        let json = #"""
        {"files":[{"uri":"file:///tmp/gone.swift"}]}
        """#
        try assertRoundtrip(DeleteFilesParams.self, json: json)
    }

    // ====================================================================
    // MARK: - FileOperationPatternKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationPatternKind
    // ====================================================================

    func test_fileOperationPatternKind_file_encoding() throws {
        let raw = try encoder.encode(FileOperationPatternKind.file)
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"file\"")
        let decoded = try decoder.decode(
            FileOperationPatternKind.self,
            from: Data("\"file\"".utf8)
        )
        XCTAssertEqual(decoded, .file)
    }

    func test_fileOperationPatternKind_folder_encoding() throws {
        let raw = try encoder.encode(FileOperationPatternKind.folder)
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"folder\"")
        let decoded = try decoder.decode(
            FileOperationPatternKind.self,
            from: Data("\"folder\"".utf8)
        )
        XCTAssertEqual(decoded, .folder)
    }

    // ====================================================================
    // MARK: - FileOperationPatternOptions
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationPatternOptions
    // ====================================================================

    func test_fileOperationPatternOptions_minimal_roundtrip() throws {
        let json = #"""
        {}
        """#
        try assertRoundtrip(FileOperationPatternOptions.self, json: json)
    }

    func test_fileOperationPatternOptions_ignoreCase_roundtrip() throws {
        let json = #"""
        {"ignoreCase":true}
        """#
        try assertRoundtrip(FileOperationPatternOptions.self, json: json)
    }

    // ====================================================================
    // MARK: - FileOperationPattern
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationPattern
    // ====================================================================

    func test_fileOperationPattern_minimal_roundtrip() throws {
        let json = #"""
        {"glob":"**/*.swift"}
        """#
        try assertRoundtrip(FileOperationPattern.self, json: json)
    }

    func test_fileOperationPattern_full_roundtrip() throws {
        let json = #"""
        {
          "glob":"**/*.{swift,m}",
          "matches":"file",
          "options":{"ignoreCase":true}
        }
        """#
        try assertRoundtrip(FileOperationPattern.self, json: json)
    }

    func test_fileOperationPattern_folderMatches_roundtrip() throws {
        let json = #"""
        {"glob":"src/**","matches":"folder"}
        """#
        try assertRoundtrip(FileOperationPattern.self, json: json)
    }

    // ====================================================================
    // MARK: - FileOperationFilter
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationFilter
    // ====================================================================

    func test_fileOperationFilter_minimal_roundtrip() throws {
        let json = #"""
        {"pattern":{"glob":"**/*.swift"}}
        """#
        try assertRoundtrip(FileOperationFilter.self, json: json)
    }

    func test_fileOperationFilter_withScheme_roundtrip() throws {
        let json = #"""
        {
          "pattern":{"glob":"**/*.swift","matches":"file"},
          "scheme":"file"
        }
        """#
        try assertRoundtrip(FileOperationFilter.self, json: json)
    }

    // ====================================================================
    // MARK: - FileOperationRegistrationOptions
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationRegistrationOptions
    // ====================================================================

    func test_fileOperationRegistrationOptions_empty_roundtrip() throws {
        let json = #"""
        {"filters":[]}
        """#
        try assertRoundtrip(FileOperationRegistrationOptions.self, json: json)
    }

    func test_fileOperationRegistrationOptions_full_roundtrip() throws {
        let json = #"""
        {
          "filters":[
            {"pattern":{"glob":"**/*.swift","matches":"file"},"scheme":"file"},
            {"pattern":{"glob":"src/**","matches":"folder","options":{"ignoreCase":true}}}
          ]
        }
        """#
        try assertRoundtrip(FileOperationRegistrationOptions.self, json: json)
    }

    // ====================================================================
    // MARK: - Equatable sanity
    // ====================================================================

    func test_documentDiagnosticReportKind_equatable() {
        XCTAssertEqual(DocumentDiagnosticReportKind.full, DocumentDiagnosticReportKind.full)
        XCTAssertNotEqual(DocumentDiagnosticReportKind.full, DocumentDiagnosticReportKind.unchanged)
    }

    func test_fileOperationPatternKind_equatable() {
        XCTAssertEqual(FileOperationPatternKind.file, FileOperationPatternKind.file)
        XCTAssertNotEqual(FileOperationPatternKind.file, FileOperationPatternKind.folder)
    }

    func test_previousResultId_equatable() {
        let a = PreviousResultId(uri: "file:///x", value: "v1")
        let b = PreviousResultId(uri: "file:///x", value: "v1")
        let c = PreviousResultId(uri: "file:///y", value: "v1")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_applyWorkspaceEditResult_equatable() {
        let a = ApplyWorkspaceEditResult(applied: true, failureReason: nil, failedChange: nil)
        let b = ApplyWorkspaceEditResult(applied: true, failureReason: nil, failedChange: nil)
        let c = ApplyWorkspaceEditResult(applied: false, failureReason: "x", failedChange: 0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
