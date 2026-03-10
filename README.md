# Calyx

A macOS 26+ native terminal application built on [libghostty](https://github.com/ghostty-org/ghostty) with Liquid Glass UI.

<!-- Screenshot: TODO -->

## Features

- **libghostty terminal engine** -- Metal GPU-accelerated rendering via Ghostty v1.3.0 submodule
- **Liquid Glass UI** -- native macOS 26 Tahoe design language
- **Tab Groups** -- 10 color presets, collapsible sections, hierarchical organization
- **Split Panes** -- horizontal and vertical splits with directional focus navigation
- **Command Palette** -- search and execute all operations with `Cmd+Shift+P`
- **Session Persistence** -- tabs, splits, and working directories auto-saved and restored on restart
- **Desktop Notifications** -- OSC 9/99/777 support with rate limiting
- **Browser Integration** -- WKWebView tabs alongside terminal tabs (http/https only, non-persistent storage, popup blocking)
- **Scrollback Search** -- `Cmd+F` to search terminal scrollback with match highlighting, `Cmd+G`/`Cmd+Shift+G` to navigate matches
- **Native Scrollbar** -- system overlay scrollbar for terminal scrollback
- **Cursor Click-to-Move** -- click on a prompt line to reposition cursor (requires shell integration)
- **Claude Code IPC** -- MCP server for inter-pane communication between Claude Code instances
- **Ghostty config compatibility** -- reads `~/.config/ghostty/config`

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

### Global

| Shortcut | Action |
|---|---|
| `Cmd+Shift+P` | Command palette |

## IPC (Inter-Pane Communication)

Multiple Claude Code instances running in different Calyx panes can communicate with each other via a built-in MCP server.

1. Open the command palette (`Cmd+Shift+P`) and run **Enable Claude Code IPC**
2. Start Claude Code in two or more terminal panes
3. Each instance automatically registers as a peer and can send/receive messages

Available MCP tools: `register_peer`, `list_peers`, `send_message`, `broadcast`, `receive_messages`, `ack_messages`, `get_peer_status`

To disable, open the command palette and run **Disable Claude Code IPC**.

## Installation

1. Download `Calyx.zip` from the [latest release](https://github.com/yuuichieguchi/Calyx/releases/latest)
2. Unzip the file
3. Drag `Calyx.app` into `/Applications`

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

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

Built on [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto (MIT License).

