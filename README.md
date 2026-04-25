# Calyx

A macOS 26+ native terminal application built on [libghostty](https://github.com/ghostty-org/ghostty) with Liquid Glass UI.

![Calyx Terminal](assets/screenshot.png)

## Features

- **libghostty terminal engine** -- Metal GPU-accelerated rendering via Ghostty v1.3.1 submodule
- **Liquid Glass UI** -- native macOS 26 Tahoe design language with customizable theme color (8 presets + custom hex/color picker; Ghostty preset reads your Ghostty config's background color). Text color adapts automatically: Ghostty preset follows Ghostty's foreground config, other presets switch between white/black based on theme color luminance ([demo video](https://www.youtube.com/watch?v=cUYc7yzI_eM))
- **Tab Groups** -- 10 color presets, collapsible/expandable sections with chevron toggle, double-click to rename groups or individual tabs, drag-to-reorder tabs in tab bar and sidebar
- **Split Panes** -- horizontal and vertical splits with directional focus navigation
- **Command Palette** -- search and execute all operations with `Cmd+Shift+P`
- **Session Persistence** -- tabs, splits, and working directories auto-saved and restored on restart
- **Desktop Notifications** -- OSC 9/99/777 support with rate limiting
- **Browser Integration** -- WKWebView tabs alongside terminal tabs (http/https only, non-persistent storage, popup blocking)
- **Scrollback Search** -- `Cmd+F` to search terminal scrollback with match highlighting, `Cmd+G`/`Cmd+Shift+G` to navigate matches
- **Drag and Drop** -- drag files, URLs, or text onto the terminal to insert content (file paths are shell-escaped)
- **Smooth Scrolling** -- trackpad uses full smooth pixel scrolling via sub-row CALayer transform; notched mouse wheel adds a velocity-based animation for smoother transitions. Togglable in Settings
- **Native Scrollbar** -- system overlay scrollbar for terminal scrollback
- **Cursor Click-to-Move** -- click on a prompt line to reposition cursor (requires shell integration)
- **Git Source Control** -- sidebar Changes view with working changes (staged/unstaged/untracked), commit graph with branch visualization, and inline diff viewer with review comments
- **Diff Review Comments** -- click the gutter `+` button to add inline comments to diff lines, then Submit Review to send directly to a Claude Code, Codex, OpenCode, or Hermes terminal tab
([demo video](https://www.youtube.com/watch?v=_O2Lr4oFf4c))
- **AI Agent IPC** -- MCP server for communication between AI agent instances (Claude Code, Codex CLI, OpenCode, Hermes) across tabs and panes ([demo video](https://www.youtube.com/watch?v=Xty0ad9gGcM))
- **Scriptable Browser** -- 25 CLI commands for browser automation (like cmux): snapshot, click, fill, eval, screenshot, wait, get-attribute, get-links, get-inputs, is-visible, hover, scroll. No enable step needed. `calyx` CLI bundled in the app
- **Ghostty config compatibility** -- reads `~/.config/ghostty/config` (most keys hot-reload on save; see Settings for Calyx-managed keys)
- **Compose Overlay** -- floating text editor over the terminal for comfortable multiline input (`Cmd+Shift+E`), useful for writing long commands or AI prompts ([demo video](https://www.youtube.com/watch?v=qhwYnk8adF4))
- **Quick Terminal** -- system-wide drop-down terminal toggled via global keybind
- **Clipboard Confirmation** -- prompts before pasting potentially unsafe content (respects Ghostty's `clipboard-paste-protection` setting)
- **Secure Keyboard Entry** -- prevents other apps from intercepting keystrokes (toggle via app menu)
- **Auto-update** -- Sparkle-based updates for direct downloads (Homebrew installs use `brew upgrade`)

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
| `Cmd+W` | Close tab |
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

### Compose Overlay

| Shortcut | Action |
|---|---|
| `Enter` | Send text to terminal |
| `Shift+Enter` | Insert newline |
| `Escape` | Close overlay |

## IPC (Inter-Pane Communication)

AI agent instances (Claude Code, Codex CLI, OpenCode, Hermes) running in different Calyx tabs or panes can communicate with each other via a built-in MCP server.

1. Open the command palette (`Cmd+Shift+P`) and run **Enable AI Agent IPC**
2. Start agents (Claude Code, Codex, OpenCode, or Hermes) in two or more terminal panes
3. Each instance automatically registers as a peer and can send/receive messages

Config is auto-written to `~/.claude.json`, `~/.codex/config.toml`, `~/.config/opencode/{opencode.json,AGENTS.md}`, and `~/.hermes/config.yaml` when the respective tool is installed. Restart running agent instances to pick up the new MCP server.

Available MCP tools: `register_peer`, `list_peers`, `send_message`, `broadcast`, `receive_messages`, `ack_messages`, `get_peer_status`

To disable, open the command palette and run **Disable AI Agent IPC**.

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

## Installation

### Homebrew

```bash
brew tap yuuichieguchi/calyx
brew install --cask calyx
```

### Manual

1. Download `Calyx.zip` from the [latest release](https://github.com/yuuichieguchi/Calyx/releases/latest)
2. Unzip the file
3. Drag `Calyx.app` into `/Applications`

Direct downloads include automatic update checking via Sparkle. Homebrew installs are updated via `brew upgrade`.

## Building from Source

### Prerequisites

- macOS 26+ (Tahoe)
- Xcode 26+
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

## Architecture

Calyx uses AppKit for window, tab, and focus management with SwiftUI for view rendering, bridged via `NSHostingView`.

- All ghostty C API calls go through the `GhosttyFFI` enum
- `@MainActor` enforced on all UI and model code
- Action dispatch via `NotificationCenter`

**Tech stack**: Swift 6.2, AppKit, SwiftUI, libghostty (Metal), XcodeGen

## Known Limitations

- **Cursor click-to-move on full-width text** -- cursor placement may be offset on Japanese/full-width text lines because Ghostty's cursor-click-to-move internally translates clicks into arrow-key steps over terminal cells.
- **Calyx-managed config keys** -- `background-opacity`, `background-blur`, `background-opacity-cells`, `font-codepoint-map`, `foreground` are overridden by Calyx for Glass UI. See Settings > Ghostty Config Compatibility for the full list.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

Built on [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto (MIT License).

