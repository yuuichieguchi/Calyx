# Calyx

A macOS 26+ native terminal application built on [libghostty](https://github.com/ghostty-org/ghostty) with Liquid Glass UI.

<!-- Screenshot: TODO -->

## Features

- **libghostty terminal engine** -- Metal GPU-accelerated rendering via Ghostty v1.2.3 submodule
- **Liquid Glass UI** -- native macOS 26 Tahoe design language
- **Tab Groups** -- 10 color presets, collapsible sections, hierarchical organization
- **Split Panes** -- horizontal and vertical splits with directional focus navigation
- **Command Palette** -- search and execute all operations with `Cmd+Shift+P`
- **Session Persistence** -- tabs, splits, and working directories auto-saved and restored on restart
- **Desktop Notifications** -- OSC 9/99/777 support with rate limiting
- **Browser Integration** -- WKWebView tabs alongside terminal tabs (http/https only, non-persistent storage, popup blocking)
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

### Global

| Shortcut | Action |
|---|---|
| `Cmd+Shift+P` | Command palette |

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
cd calyx

# Build libghostty
cd ghostty
zig build -Doptimize=ReleaseFast
cd ..

# Copy framework
cp -R ghostty/zig-out/lib/GhosttyKit.xcframework .

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

- **Option+Click cursor movement on full-width text** -- cursor placement may be offset on Japanese/full-width text lines because Ghostty's cursor-click-to-move internally translates clicks into arrow-key steps over terminal cells.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

Built on [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto (MIT License).

