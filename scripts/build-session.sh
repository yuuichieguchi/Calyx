#!/bin/bash
set -euo pipefail

# Builds the calyx-session daemon/CLI binary for the host architecture
# only (arm64 macOS). Cross compilation for other targets
# (remote-install) is P5 scope, not handled here.
#
# calyx-session's `vt` crate links a Zig-built shim (`gvt`) against
# ghostty-vt sources, so it needs a Zig toolchain version compatible
# with whatever the ghostty submodule currently pins. Resolution order:
# an explicit GVT_ZIG override, then the versioned Homebrew Cellar path
# this repo has been developed against, then whatever `zig` happens to
# be on PATH (warned about if its version doesn't look right, since an
# ABI mismatch here fails at Zig build/link time with a much less
# obvious error than "wrong zig version").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_DIR="$REPO_ROOT/calyx-session"
OUT_DIR="$REPO_ROOT/build/session"

EXPECTED_ZIG_MINOR="0.15"
CELLAR_ZIG="/opt/homebrew/Cellar/zig/0.15.2/bin/zig"

if [ -n "${GVT_ZIG:-}" ]; then
    : # explicit override wins outright
elif [ -x "$CELLAR_ZIG" ]; then
    GVT_ZIG="$CELLAR_ZIG"
elif command -v zig >/dev/null 2>&1; then
    GVT_ZIG="$(command -v zig)"
    found_version="$("$GVT_ZIG" version)"
    case "$found_version" in
        "$EXPECTED_ZIG_MINOR".*) ;;
        *)
            echo "warning: zig on PATH reports version $found_version, not $EXPECTED_ZIG_MINOR.x — the gvt shim may fail to build or link against an ABI-incompatible Zig. Set GVT_ZIG to an explicit $EXPECTED_ZIG_MINOR.x binary if this fails." >&2
            ;;
    esac
else
    echo "error: no Zig toolchain found (checked GVT_ZIG, $CELLAR_ZIG, and PATH)." >&2
    echo "Install Zig $EXPECTED_ZIG_MINOR.x or set GVT_ZIG to an ABI-compatible binary." >&2
    exit 1
fi
export GVT_ZIG

if [ ! -x "$GVT_ZIG" ]; then
    echo "error: GVT_ZIG ($GVT_ZIG) is not an executable file." >&2
    exit 1
fi

echo "=== Building calyx-session (host-only, release) ==="
echo "GVT_ZIG=$GVT_ZIG"

(
    cd "$SESSION_DIR"
    cargo build --release -p cli
)

mkdir -p "$OUT_DIR"
cp "$SESSION_DIR/target/release/calyx-session" "$OUT_DIR/calyx-session"
chmod 0755 "$OUT_DIR/calyx-session"

echo "Built $OUT_DIR/calyx-session"
