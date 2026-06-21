# LSP MCP Proxy — Verification Log

End-to-end verification run against rust-analyzer on the
`/Users/eguchiyuuichi/projects/mini-hadoop` workspace
(brand: 2026-06-22).

| # | Item | Status | Evidence |
|---|------|--------|----------|
| 1 | Build | OK | `xcodebuild build` returns `** BUILD SUCCEEDED **`, zero new Swift warnings. |
| 2 | Unit tests | OK | `xcodebuild test -only-testing:CalyxTests` returns `** TEST SUCCEEDED **`, 1633+ tests pass across LSP / IPC / Bridge / Settings suites. |
| 3 | Registry coverage | OK | `LSPServerRegistryTests` asserts all 15 built-in entries; `swift test` green. |
| 4 | Bridge coverage | OK | `MCPLSPBridgeTests`, `MCPLSPBridgeExtendedToolsTests`, `MCPLSPBridgeHierarchyToolsTests`, `MCPLSPBridgeInfoClusterATests`, `MCPLSPBridgeInfoClusterBTests`, `MCPLSPBridgeEditWorkspaceToolsTests`, `MCPLSPBridgeFileOpsAndAITests`, `MCPLSPBridgeNotebookToolsTests` all green. |
| 5 | E2E real LSP | OK | `lsp_hover` against `crates/mini-hdfs/src/client.rs:13:11` returned `pub struct FileEntry { name: String, is_directory: bool, size: u64 }` + doc comment + memory layout, identical shape to VSCode's Hover. `lsp_definition` returned a `LocationLink` array; `lsp_workspace_symbol query=FileEntry` returned two matches across the workspace. |
| 6 | AI-specific tools | OK | `lsp_hover_bundle` returned the merged `{hover, definition, surrounding_code}` payload in one round trip. `lsp_batch` pipelined `lsp_hover` + `lsp_definition` and returned both results in one MCP response. |
| 7 | FSEvents sync | OK (wired) | `FileSyncManager` is constructed in `CalyxMCPServer.startLSP()` and threaded into `LSPService`. Test-side validation in `FileSyncManagerTests` and `LSPServiceFileSyncWiringTests` covers the dispatch path; manual edit-on-disk verification was not separately retested in this log. |
| 8 | Tool visibility | OK | `scripts/lsp-mcp-smoke-test.sh` confirms `tools/list` returns 77 (7 IPC + 70 LSP); `lsp_hover`, `lsp_session_status`, `lsp_check_installation`, `lsp_notebook_did_open`, `register_peer` all present. |
| 9 | Idle shutdown | OK (wired) | `LSPService.config.idleTimeoutSeconds` default 1800. `LSPServiceTests.test_idleTimeout_triggersShutdown` validates the eviction path. Not retested live (would require 30-minute idle period). |
| 10 | Crash recovery | OK (wired) | `LSPClientTests` covers transport EOF and the `LSPSession` rebuild path. Not retested live this round. |
| 11 | Auto-install | OK | `lsp_install language_id=rust` ran `rustup component add rust-analyzer` end-to-end; `rust-analyzer --version` afterwards reports `1.93.1 (01f6ddf7 2026-02-11)`. Settings were toggled (`autoInstallEnabled=true`, `requireInstallConfirmation=false`) via `defaults write` to exercise the `.silent` path through the bridge. |
| 12 | Chained prerequisite install | OK (wired) | `LSPInstallerTests.test_install_withPrerequisites_chains` exercises the prerequisite-then-target sequence through MockCommandRunner. Production chain not re-run live (would require uninstalling rustup first). |
| 13 | Duplicate-install suppression | OK (wired) | `LSPInstallerTests.test_install_concurrentCalls_dedup` covers the dedup path. Production not re-run live. |
| 14 | Capability fallback | OK | `lsp_capabilities` against the running rust-analyzer session returned a non-empty `dynamic` array including `textDocument/didSave` with a `documentSelector` glob — proves dynamic registration flowed through `client/registerCapability` -> `CapabilityRegistry`. |
| 15 | lsp_check_installation | OK | All 15 languages enumerated with `isInstalled`, `detectedPath`, `detectedVersion`, `prerequisiteStatuses`. Single-language call returns one entry. |

Note on `lsp_check_installation` accuracy: the check uses `which`, so
binaries that are PATH-resolvable but non-functional (e.g. a rustup
shim with the component not actually installed) report `isInstalled:
true` even when running them fails. This is consistent with the
plan's definition of installed but is worth a follow-up to add a
`--version` smoke test for stricter validation.

Note on Swift LSP: sourcekit-lsp launched (`state.phase: running`)
but failed `lsp_hover` against an Xcode-project file with `-32001
No language service for ...`. This is a known sourcekit-lsp
limitation against pure Xcode projects — it requires either a
`Package.swift` workspace or `compile_commands.json`. Not a Calyx
bug; the production wiring is correct and the same flow works
unchanged against rust-analyzer.
