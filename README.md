# Calyx

**Run more coding agents without babysitting more terminals.**

Calyx is a native macOS terminal for running and supervising coding agents (Claude Code, Codex, OpenCode, Hermes, Grok, and pi...) in parallel. It keeps every agent visible and controllable with one approval inbox, live status, persistent sessions, agent-readable command history, and inline diff review -- without replacing the terminal workflow you already use.

[Documentation](https://help.getcalyx.app) · [Latest release](https://github.com/yuuichieguchi/Calyx/releases/latest) · [MIT license](LICENSE)

## Demo

Every agent pane on the Mission Map, approvals from one inbox, per-line diff comments sent straight to the agent, tab groups, and every command in the palette (30s):

https://github.com/user-attachments/assets/bcc425c6-2115-46d9-970a-87063818ded7

## Install

### Homebrew

```bash
brew install --cask calyx
```

### Manual download

1. Download `Calyx.zip` from the [latest release](https://github.com/yuuichieguchi/Calyx/releases/latest).
2. Unzip it and move `Calyx.app` to `/Applications`.

Calyx requires macOS 26 Tahoe or later on Apple Silicon (arm64 only). Direct downloads update through Sparkle; Homebrew installations update with `brew upgrade`.

## Why Calyx

### See which agent needs you

The Agents Sidebar shows every connected agent as working, blocked, idle, or done, and expands a pane into the subagents it is currently running. Unread badges and click-to-focus navigation replace the loop of checking terminal tabs one by one.

### Approve tool calls from one inbox

Claude Code and Codex permission prompts, the tool calls of Grok sessions running in always-approve mode, and every pi tool call appear in a macOS-notification-style panel at the top-right of your screen: a primary action plus an Options pull-down listing every other choice the CLI offers, including its own always-allow suggestions. Click the request text to expand its full payload, or hover it to read the full text in a tooltip. A Claude Code AskUserQuestion prompt answers the same way -- pick an option from Options, or from an inline option list when the question allows several answers at once or carries a preview, choose "Other…" to type a free-text answer, add notes, or hand the conversation back to the CLI with "Chat about this" -- and move through pending requests without hunting for the pane that raised them. Enable the integration explicitly in Settings; nothing is automatically approved unless you separately opt in. pi ships no permission prompt of its own, so with the integration off its tool calls run unreviewed.

### Review code without leaving the terminal

Inspect working changes and commit history in the Git sidebar, add comments to individual diff lines, and submit the complete review directly to a Claude Code, Codex, OpenCode, Hermes, or Grok pane.

### Give agents a terminal they can understand

Calyx exposes panes, commands, captured output, browser tabs, language servers, and peer agents through MCP and its bundled CLI. Agents can coordinate work, wait for commands to finish, and inspect results instead of relying on sleep timers or copied output.

## Features

### Agent supervision

- **Agents Sidebar** -- live status for Claude Code, Codex, OpenCode, Hermes, Grok, and pi, with every row named after its own pane (title, working directory, agent), unread badges, last-seen timestamps, and click-to-focus navigation
- **Subagent Rows** -- a pane running subagents gains a count badge and a disclosure chevron that expands them as indented child rows, for the CLIs that report subagents (Claude Code, Codex, OpenCode, Grok); each row carries the child's state, and the child's current tool with the command, path, or URL that call is working on wherever its CLI reports one (Claude Code and Grok; Codex and OpenCode report lifecycle only). Children exist only while the CLI reports them, and a pane whose CLI reports no subagents at all (pi, Hermes, herdr) looks exactly as it always did. Because a CLI reads its hook configuration once at session start, subagent rows appear in sessions started after Calyx installs the hooks, not in one already running
- **Approval Inbox** -- one opt-in queue across every pane for Claude Code and Codex permission prompts, for the tool calls of always-approve Grok sessions, and for every pi tool call, shown in a notification-style panel at the top-right of the screen with a primary action and an Options pull-down for every other choice (the CLI's own always-allow suggestions, or per-pane session-scoped approval when the CLI offers none, and No), or an inline option list when the question allows several answers at once or carries a preview; Claude Code and Codex queue a request only where the CLI would have prompted you itself and fall back to the agent's own prompt, while an unanswered Grok or pi request is denied
- **Approval Queue Navigation** -- inspect and decide pending requests in any order, with a preview menu on the position label for jumping straight to one, and automatic navigation to the nearest remaining request
- **Dismiss** -- the panel's own × is offered only when the CLI's own prompt, or the calling MCP agent, can still decide the request without Calyx: it hands a Claude Code or Codex tool call back to that CLI's own confirmation prompt, or reports a no-decision result to a Calyx MCP tool's own caller. Grok and pi requests must be answered in Calyx -- its own decision is their only gate, so the × is disabled for them
- **Mission Map** -- `Cmd+Shift+M` (or **Show All Tabs** in a tab's context menu) lays every pane in the window out as a card with its agent's state, working directory, Git branch, Claude Code token usage (with Usage Tracking on), current tool, subagents, and pending approval with an inline Allow; AI Agent IPC messages draw lines routed around the cards that disappear two minutes after the last message and list their messages on click, a red line joins two panes whose agents edited the same file in the last five minutes, a double-click jumps to a card's pane, and dragged card positions are saved with the layout
- **Agent Cockpit** -- MCP tools for listing, creating, and splitting panes; commands and keystrokes remain approval-gated unless auto-approve is enabled
- **Command Log** -- structured commands, working directories, exit status, and captured output exposed to agents through MCP; known secret patterns are redacted before exposure
- **Usage Tracking** -- off by default; turn it on in Settings -> Agents -> **Usage Tracking** (needs **Enable AI Agent IPC**). Claude Code counts its own token usage, subagents, advisor calls and background requests included, and while tracking is on Calyx adds telemetry settings to `~/.claude/settings.json` so that Claude Code on this Mac sends those counts to Calyx on localhost (turning Usage Tracking or AI Agent IPC off removes the settings again, and if the file already has telemetry settings of its own Calyx leaves it alone and says so in Settings). Calyx keeps them in a local database (`~/Library/Application Support/Calyx/usage/usage.sqlite`) of numbers and labels (model, effort, thread, agent type, session, and each session's project path, working directory and transcript path), never conversation text. **View -> Usage** (`Cmd+Option+U`, or **Usage…** in the command palette) shows them by model, effort, thread and project (and per day on request) for today, the last 7 or 30 days, or all time, per project and thread; each Mission Map card shows its session's running total; and agents can query them with `usage_report`. Tokens Claude Code counted while Calyx was not running are added from the totals Claude Code writes to the session's transcript under `~/.claude/projects` as **unreported** rows (model known, effort not). Turning tracking off keeps the stored data, and **Delete Usage Data…** in the Usage window erases it (sessions still running are counted from then on)

### Code review and agent coordination

- **Git Source Control** -- working changes, staging state, commit graph, branch visualization, and inline diffs in the sidebar, as one collapsible section per repository the window can reach, including linked worktrees and checked-out submodules
- **Commit Log Ref Picker** -- the commit graph uses an Auto scope modelled on VSCode's (the checked-out branch, its upstream, and the remote's default branch), with a per-repository picker for all references or any set of branches, remotes, and tags, and branch and tag badges on commit rows
- **Diff Review Comments** -- comment on individual lines and submit a complete review directly to an agent pane ([demo video](https://www.youtube.com/watch?v=_O2Lr4oFf4c))
- **AI Agent IPC** -- built-in MCP messaging lets agents discover and communicate with peers across tabs and panes ([demo video](https://www.youtube.com/watch?v=Xty0ad9gGcM))
- **LSP Proxy MCP** -- hover, definition, references, rename, diagnostics, and other language-server features for agents; missing servers can be installed from Settings
- **MCP Apps** -- add MCP servers (stdio or HTTP, with OAuth sign-in) in Settings -> **MCP Apps** and Calyx republishes their tools to every agent CLI as `calyx-mcp`; a tool that declares an MCP Apps view renders it docked to the right of the calling pane, with Open Link and Send Message consent routed through the approval panel

### Sessions and remote work

- **Persistent Sessions** -- opt-in daemon-backed terminals survive app quit and crashes, with a Session Browser that shows why a Kill failed, recovery flow, and optional on-disk history
- **Remote Sessions** -- deploy `calyx-session` once to an SSH host from `~/.ssh/config`, then browse and reattach to remote persistent sessions
- **Agent Resume** -- offer to resume the agent CLI conversation associated with a reattached session
- **Layout Restore** -- restore tabs, splits, and working directories on launch
- **herdr Integration** -- browse and manage herdr workspaces as native split-pane tabs, or jump to a workspace in a herdr TUI already running in a Calyx pane; herdr-hosted agents also appear in the Agents Sidebar, and a row bridged into a Calyx tab focuses that pane on click. Calyx watches for herdr instead of polling, so herdr started or installed after Calyx launched is picked up without a relaunch

### Terminal workspace

- **libghostty Engine** -- Metal GPU-accelerated rendering powered by Ghostty v1.3.1
- **Tab Groups and Split Panes** -- color-coded collapsible groups, tab renaming and reordering, group reordering and moving tabs between groups by dragging in the sidebar, horizontal and vertical splits, directional focus, and split zoom
- **Tab Context Menu** -- right-click or Ctrl+click a tab in the tab bar or sidebar to close it, close the other tabs or the tabs to its right in its group, rename it, or open Mission Map with **Show All Tabs**, without switching to it
- **Group Context Menu** -- right-click or Ctrl+click a group header in the sidebar to close it, close the other groups or the groups below it, rename it, or pick its color, without switching to it
- **Command Palette** -- search and run operations with `Cmd+Shift+P`
- **Ghostty Compatibility** -- read `~/.config/ghostty/config`, hot-reload most settings, and bind Calyx operations through Ghostty keybind actions
- **Search and Navigation** -- highlighted scrollback search, native overlay scrollbar, smooth trackpad and mouse-wheel scrolling, and prompt-line cursor click-to-move
- **Input Tools** -- shell-escaped drag and drop, multiline Compose Overlay, clipboard safety confirmation, and Secure Keyboard Entry that turns on automatically at password prompts, including inside local persistent sessions
- **Quick Terminal and Notifications** -- a system-wide drop-down terminal plus OSC 9/99/777 desktop notifications
- **VoiceOver and XCUITest** -- every terminal pane is an AXTextArea named "Terminal" (identifier `calyx.terminal.pane.<uuid>`) that exposes the visible viewport line by line with the current selection and on-screen frames; scrollback is not exposed
- **Liquid Glass Appearance** -- macOS 26-native glass UI drawn as one seamless sheet of window chrome, eight theme presets, custom colors, adaptive text color, an optional opacity pass that reaches cells an app paints itself, and a fully opaque window under Reduce Transparency ([demo video](https://www.youtube.com/watch?v=cUYc7yzI_eM))
- **About Window and Help Menu** -- **About Calyx** shows the version, build, and a linked git commit with **Docs** and **GitHub** buttons; **Help -> Calyx Help** (`Cmd+?`) opens the help center

### Browser automation

- **Browser Tabs** -- non-persistent WKWebView tabs alongside terminal tabs, limited to http and https with popups blocked
- **Scriptable Browser** -- 25 bundled `calyx browser` commands for accessibility snapshots, clicking, filling, evaluation, screenshots, waits, and inspection

## Keyboard Shortcuts

### Group Operations (Ctrl+Shift)

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+]` | Next group |
| `Ctrl+Shift+[` | Previous group |
| `Ctrl+Shift+N` | New group |
| `Ctrl+Shift+W` | Close group |

### Tab Operations (Cmd)

| Shortcut | Action |
|---|---|
| `Cmd+T` | New tab |
| `Cmd+W` | Close focused pane (whole tab if nothing narrower to close) |
| `Cmd+Option+W` | Close tab |
| `Cmd+Shift+W` | Close window |
| `Cmd+Shift+Option+W` | Close all windows |
| `Cmd+1`--`9` | Switch to tab |
| `Cmd+Shift+]` | Next tab |
| `Cmd+Shift+[` | Previous tab |

### Split Operations

| Shortcut | Action |
|---|---|
| `Cmd+D` | Split right |
| `Cmd+Shift+D` | Split down |
| `Cmd+Option+Arrow` | Focus between splits |

### Search

| Shortcut | Action |
|---|---|
| `Cmd+F` | Find in terminal |
| `Cmd+G` | Next match |
| `Cmd+Shift+G` | Previous match |
| `Escape` | Close search bar |

### Notifications

| Shortcut | Action |
|---|---|
| `Cmd+Shift+U` | Jump to most recent unread notification tab |

### Global

| Shortcut | Action |
|---|---|
| `Cmd+Shift+P` | Command palette |
| `Cmd+Shift+E` | Toggle compose overlay |
| `Cmd+Shift+B` | Session Browser |
| `Cmd+Shift+M` | Toggle Mission Map |
| `Cmd+Option+U` | Usage window |
| `Cmd+?` | Calyx Help (opens the help center) |
| `Cmd+Enter` / `Ctrl+Cmd+F` | Toggle full screen |

### Compose Overlay

| Shortcut | Action |
|---|---|
| `Enter` | Send text to terminal |
| `Shift+Enter` | Insert newline |
| `Escape` | Close overlay |

## IPC (Inter-Pane Communication)

AI agent instances (Claude Code, Codex CLI, OpenCode, Hermes, Grok, pi) running in different Calyx tabs or panes can communicate with each other via a built-in MCP server.

1. Open Settings -> **Agents** and turn on **Enable AI Agent IPC**
2. Start agents (Claude Code, Codex, OpenCode, Hermes, Grok, or pi) in two or more terminal panes
3. Each instance automatically registers as a peer and can send/receive messages

Config is auto-written to `~/.claude.json`, `~/.codex/config.toml`, `~/.config/opencode/{opencode.json,AGENTS.md}`, `~/.hermes/config.yaml`, and `~/.grok/config.toml` when the respective tool is installed, as a `calyx-ipc` entry plus a `calyx-mcp` entry that republishes the servers configured in Settings -> **MCP Apps**. Restart running agent instances to pick up the new MCP server. If you install a supported agent later, click **Refresh** under the switch to write its config and hooks. It never restarts a server that is already running, so agents already connected keep working. Calyx remembers the switch: while it is on, every launch starts the server and rewrites these entries, changing only Calyx's own entry in each file.

pi has no MCP client configuration file at all, so it reaches Calyx through a single TypeScript extension written to `~/.pi/agent/extensions/calyx.ts`, which pi auto-loads. It carries the whole integration: the sidebar row, the approval gate, a `calyx` tool that bridges the MCP tools above (call it with `{"tool": "list"}` to enumerate them), and a `calyx_mcp` tool that does the same for the MCP Apps servers. A pi started outside Calyx, or inside a herdr pane, registers only `calyx_mcp`.

Available MCP tools: `register_peer`, `list_peers`, `send_message`, `broadcast`, `receive_messages`, `get_peer_status`. `receive_messages` deletes each message from the inbox as it returns it, so a message is only ever delivered once.

Settings -> Agents -> **Wake Claude Code on IPC messages** is off by default. With the switch on, a message that arrives for a Claude Code pane wakes it if its wake hook is waiting, so an agent idle at its prompt picks the message up without being asked. It applies to Claude Code only and needs a Claude Code version that supports `asyncRewake` hooks. The wake only tells the agent how many messages are waiting and its own peer id; the agent reads them itself with `receive_messages`. Calyx never reads a message for it, and the note contains nothing written by another agent. A message wakes a pane at most once.

A pane can be woken only while its wake hook is waiting. The hook starts waiting when a turn ends or a session starts (including a resumed, cleared or compacted session), and waits for about 10 minutes. A turn interrupted with Esc fires no `Stop`, so it starts no new wait; a wait left from the end of the previous turn, if still open, can still wake the pane. A wake that arrives while a turn is running is absorbed into that turn right after the running tool finishes; no new turn is started. So a pane is not woken:

- about 10 minutes after its last wait began (that is, after its last completed turn or session start)
- after Calyx or its IPC server restarted, until the next wait begins
- right after the switch was turned on, until the next wait begins
- after a persistent session was reattached to another pane
- while a `claude` started inside the same pane has taken the hook over (the wake goes to that one)

Separately, as before, `send_message` to an expired peer fails. A peer expires only when 10 minutes have passed since its last IPC call and it is neither the sender nor the recipient of an undelivered message. Turning the wake switch off stops waking at once. The hook acts only on an answer signed with a key that the running Calyx creates at each start and shares with the hook through its 0600 endpoint file, so another process listening on the port cannot wake a pane. The hook entry (`calyx-ipc-wake-hook` on `Stop` and `SessionStart` in `~/.claude/settings.json`) stays installed together with Calyx's other Claude Code hooks and is removed with them when AI Agent IPC is turned off.

The approval hook (`calyx-approval-hook`) works the same way: it sends a fresh nonce with each request, Calyx signs each answer with the per-start key published in `agent-endpoint.json`, and the hook prints only an answer that verifies. Anything else is silence, so the CLI's own permission prompt takes over. Requests without the nonce header (pi, E2E) get the same unsigned answers as before.

`agent-endpoint.json` also records the process ID and start time of the Calyx that wrote it. Every sender (the hook scripts, the zsh/fish integration, the OpenCode plugin and the pi extension) checks that this Calyx is still alive before sending the token, and a Calyx whose IPC listener dies removes the file.

Calyx keeps the previous token across a restart and issues a new one only when another process holds the previous port at restart; Settings -> Agents then shows "IPC token renewed". Claude Code, Codex and Grok 1.0.52 or later follow the new token automatically and Hermes reconnects within seconds, but OpenCode and older Grok sessions started before that launch must be restarted.

The same server exposes cockpit tools that control Calyx (`pane_list`, `pane_split`, `tab_create`, `agent_status` for every pane's agent, approval, git and usage state; approval-gated: `pane_run`, `pane_send_keys`, `palette_execute`) and command-log tools (`terminal_list_commands`, `terminal_read_output`, `terminal_await_command`; requires the zsh/fish shell integration, installed automatically while Settings -> Agents -> **Track shell commands** is on). Command text and output are redacted for known secret patterns (tokens, passwords, API keys, JWTs) before agents can read them; output still being redacted reports `{"output_pending": true}` from `terminal_read_output` until it finishes. `usage_report` reports Claude Code token usage as counted by Claude Code itself and received by Calyx (input, cache and output tokens, grouped by model, effort, thread, agent type, day, project or session, with totals; tokens Calyx knows were used but did not receive in detail are marked unreported; requires Settings -> Agents -> **Usage Tracking**).

To disable, turn the switch off. Calyx removes its own entries and hooks, deletes the files it owns outright, and leaves a shared file that ends up empty in place. The hook scripts under `~/Library/Application Support/Calyx/bin/` are left in place.

## LSP Proxy MCP

Calyx can expose language server features to CLI AI agents through the same MCP server used by AI Agent IPC. Agents can call tools such as `lsp_hover`, `lsp_definition`, `lsp_references`, `lsp_rename`, and `lsp_diagnostics` to get symbol-aware results from TypeScript, Python, Rust, Go, Swift, and other language servers instead of relying on grep.

### Setup

1. Open Settings -> **Agents** and turn on **Enable AI Agent IPC**.
2. Restart or reconnect your AI agent so it picks up the `calyx-ipc` MCP server.
3. Optional: open Settings -> **LSP** and enable auto-install for missing language servers.

Calyx keeps language servers running in the background, syncs file changes from disk, and starts the right server on the first `lsp_*` call for a workspace.

## Browser Scripting

Agents can programmatically control browser tabs via 25 CLI commands, similar to cmux's browser automation.

1. Open a browser tab and navigate to a page
2. Use `calyx browser` commands from any terminal tab — no enable step needed

### CLI Commands

```bash
calyx browser list                         # List all browser tabs
calyx browser snapshot --tab-id <id>       # Accessibility tree with element refs
calyx browser get-text h1 --tab-id <id>    # Get element text
calyx browser click a --tab-id <id>        # Click element
calyx browser fill input --value "text"    # Fill input field
calyx browser eval 'document.title'        # Execute JavaScript
calyx browser screenshot                   # Capture to temp file
calyx browser wait --selector ".loaded"    # Wait for condition
calyx browser get-attribute a href         # Get element attribute
calyx browser get-links                    # List all links (JSON)
calyx browser get-inputs                   # List all form inputs (JSON)
calyx browser is-visible '#sidebar'        # Check element visibility
calyx browser hover '#menu-item'           # Hover over element
calyx browser scroll down --amount 500     # Scroll page/element
```

The `calyx` CLI binary is bundled inside `Calyx.app/Contents/Resources/bin/`. To install it to your PATH, run **Install CLI to PATH** from the command palette.

The browser server starts automatically with the app and listens on `localhost:41840`. Connection info is written to `~/.config/calyx/browser.json`.

## Building from Source

### Prerequisites

- macOS 26.6+ (Tahoe)
- Xcode 27+
- [Zig](https://ziglang.org/) (version matching ghostty's `build.zig.zon`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```bash
# Clone with submodules
git clone --recursive https://github.com/yuuichieguchi/Calyx.git
cd Calyx

# Build libghostty xcframework
cd ghostty
zig build -Demit-xcframework=true -Dxcframework-target=native
cd ..

# Copy framework
cp -R ghostty/macos/GhosttyKit.xcframework .

# Generate Xcode project & build
xcodegen generate
xcodebuild -project Calyx.xcodeproj -scheme Calyx -configuration Debug build
```

Debug builds are signed with the maintainer's Developer ID. If you don't have that certificate, append `CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to the `xcodebuild` command to override it.

## Architecture

Calyx uses AppKit for window, tab, and focus management with SwiftUI for view rendering, bridged via `NSHostingView`.

- All ghostty C API calls go through the `GhosttyFFI` enum
- `@MainActor` enforced on all UI and model code
- Action dispatch via `NotificationCenter`

**Tech stack**: Swift 6.4, AppKit, SwiftUI, libghostty (Metal), XcodeGen

## Contributing

Bug reports and feature ideas are welcome as issues. External pull requests are not accepted. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Known Limitations

- **Cursor click-to-move on full-width text** -- cursor placement may be offset on Japanese/full-width text lines because Ghostty's cursor-click-to-move internally translates clicks into arrow-key steps over terminal cells.
- **Calyx-managed config keys** -- `background-opacity`, `background-blur`, `background-opacity-cells`, `font-codepoint-map`, `foreground` are overridden by Calyx for Glass UI. `background-opacity-cells` is set from Settings > Appearance > Glass instead. See Settings > Ghostty Config Compatibility for the full list.
- **Claude Code usage totals** -- only sessions started while Usage Tracking is on are counted, because Claude Code reads the telemetry settings when it starts; restart sessions that were already running. A session that starts and ends while Calyx is not running is not counted at all. What a counted session used while Calyx was not running is counted when Calyx next hears from that Claude Code process; if the process ended before that, it appears as unreported rows (per model, without effort or thread) dated at the end of that run. Self-defined agents are reported by Claude Code under the name `custom`. Telemetry configured through shell environment variables instead of `~/.claude/settings.json` is not detected. Before downgrading to a Calyx version without this feature, turn Usage Tracking off so the settings are removed.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

Built on [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto (MIT License).
