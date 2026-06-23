# LSP MCP Proxy Verification

End-to-end verification procedure for the LSP MCP proxy feature.
Items 1-4 are automated via `swift test`; items 5-15 require Calyx
running with real language servers and are run manually.

## 1. Build

```
cd ~/projects/Calyx-worktrees/lsp-mcp-proxy
xcodegen generate
xcodebuild -project Calyx.xcodeproj -scheme Calyx -configuration Debug -arch arm64 build
```

Expected: `** BUILD SUCCEEDED **`, zero source-level warnings.

## 2. Unit tests

```
xcodebuild -project Calyx.xcodeproj -scheme Calyx -destination 'platform=macOS' test -only-testing:CalyxTests
```

Expected: all XCTest suites and all Swift Testing suites pass. The
LSP subsystem alone contributes the following test files:

- `LSPTypesFoundationTests`, `LSPTypesLifecycleTests`,
  `LSPTypesPositionRequestsTests`, `LSPTypesCompletionAndSymbolTests`,
  `LSPTypesEditClusterTests`, `LSPTypesHierarchyAndMonikerTests`,
  `LSPTypesVisualizationClusterTests`,
  `LSPTypesWorkspaceOpsClusterTests`, `LSPTypesNotebookTests`,
  `TextDocumentSyncTypesTests`, `PublishDiagnosticsParamsTests`
- `LSPClientTests`, `LSPSessionTests`,
  `LSPSessionServerHandlersTests`, `LSPSessionPersistenceTests`,
  `LSPSessionPersistenceWiringTests`
- `LSPServerRegistryTests`, `LSPInstallerTests`,
  `LSPServiceTests`, `LSPServiceFileSyncWiringTests`,
  `WorkspaceResolverTests`, `FileSyncManagerTests`
- `CapabilityRegistryTests`, `ProgressBrokerTests`,
  `DiagnosticsStoreTests`
- `MCPLSPBridgeTests`, `MCPLSPBridgeExtendedToolsTests`,
  `MCPLSPBridgeHierarchyToolsTests`,
  `MCPLSPBridgeInfoClusterATests`,
  `MCPLSPBridgeInfoClusterBTests`,
  `MCPLSPBridgeEditWorkspaceToolsTests`,
  `MCPLSPBridgeFileOpsAndAITests`,
  `MCPLSPBridgeNotebookToolsTests`
- `LSPSettingsTests`
- `CalyxMCPServerLSPIntegrationTests` (cross-module)

## 3. Registry coverage

`LSPServerRegistryTests` asserts the 15 built-in languages
(TypeScript/JavaScript, Python, Swift, Rust, Go, Ruby, Java, Kotlin,
PHP, C#, Lua, Elixir, Haskell, Zig, OCaml) each have the executable,
install command, prerequisites, file extensions, and workspace
markers populated. Passes as part of `swift test`.

## 4. Bridge coverage

The bridge tests collectively verify that the 70 LSP MCP tools
dispatch to the correct LSP method with the correct params shape.

- 7 IPC + 70 LSP = 77 tools in `tools/list`.
- Each tool's input schema is asserted in the catalogue tests.

## 5. End-to-end with real LSP servers (per-language)

Prerequisites:

1. Launch Calyx (`/run` skill, or `open <DerivedData>/Calyx.app`).
2. Inside Calyx: `Cmd+Shift+P` -> **Enable AI Agent IPC**. The MCP
   server starts listening on TCP 41830 and writes the Bearer token
   to `~/.claude.json` (and to other agent configs if installed).
   Verify with `lsof -i :41830`.

Then run the smoke test script to verify the MCP plumbing:

```
./scripts/lsp-mcp-smoke-test.sh
```

For each of TypeScript / Python / Swift / Rust / Go, ensure the
matching language server is installed (or rely on `lsp_install` from
item 11). Then from a Claude Code instance attached to `calyx-ipc`:

```
Run lsp_hover on src/index.ts at line 0 column 7
```

Expected: the response contains the type signature and any doc
comment for the symbol at that position. Same shape as VSCode's
Hover popover.

## 6. AI-specific tools

- `lsp_batch`: pass `requests: [{tool: lsp_hover, params: ...}, {tool: lsp_definition, params: ...}]`. Both responses returned in one round trip.
- `lsp_hover_bundle`: returns `{hover, definition, surrounding_code}`.
- `lsp_global_workspace_symbol`: with two workspaces warmed, returns aggregated symbols from both.
- `lsp_session_warmup` followed by `lsp_hover` against the same workspace should respond faster than the first cold call.

## 7. FSEvents sync

Open a file in the workspace via `lsp_session_warmup` + `lsp_hover`.
Edit the file in a text editor and save. Run `lsp_hover` on the new
content. Expected: hover reflects the edit (Calyx auto-sent
`textDocument/didChange` via FileSyncManager).

## 8. Tool visibility from Claude Code

`/mcp` from Claude Code attached to `calyx-ipc`. Expected: 77 tools
listed (7 IPC + 70 LSP).

## 9. Idle shutdown

Wait ≥30 minutes with no LSP traffic. `ps aux | grep
typescript-language-server` (or whichever server was last used)
should show the process gone. The next LSP tool call respawns it.

## 10. Crash recovery

`pkill -f typescript-language-server` while a session is active. Next
LSP tool call against that workspace should respawn the server and
re-apply `didOpen` for files in the persisted snapshot.

## 11. Auto-install when server missing

With Settings -> LSP Proxy -> Auto-install on, Confirm off, remove
the language server binary from PATH (or use a workspace whose
language is not installed yet). Call `lsp_hover` against a file of
that language. Expected: Calyx runs the install command from the
registry, then dispatches the hover.

## 12. Chained prerequisite install

Without `npm` on PATH, attempt `lsp_install language_id=typescript
approve_prerequisites=true`. Expected: Calyx installs the
prerequisite first (e.g. `brew install node`), then the language
server.

## 13. Duplicate-install suppression

Run two concurrent `lsp_install` calls for the same language. The
installer should only execute the install command once; both calls
share the same status.

## 14. Capability fallback

Connect to a server that doesn't reply to `client/registerCapability`
(e.g. OmniSharp). The bridge should still dispatch features the
server advertised statically in `initialize` (e.g. `hoverProvider`).

## 15. lsp_check_installation

Without arguments, returns one entry per built-in registry entry (15
entries). With `language_id`, returns a single entry. Each entry
includes `isInstalled`, `detectedPath`, `detectedVersion`, and
`prerequisiteStatuses`.
