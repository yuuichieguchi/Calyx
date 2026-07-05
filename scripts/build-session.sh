#!/bin/bash
set -euo pipefail

# Builds the calyx-session daemon/CLI binary.
#
# Default (--host-only): host architecture only (arm64 macOS).
# --all: additionally cross-compiles static Linux binaries for
# remote-install, into build/session/session-remote/{x86_64,aarch64}/.
# The Linux builds use plain cargo with `zig cc` as the linker driver
# (no cargo-zigbuild dependency); rustup targets
# {x86_64,aarch64}-unknown-linux-musl must be installed.
#
# calyx-session's `vt` crate links a Zig-built shim (`gvt`) against
# ghostty-vt sources, so it needs a Zig toolchain version compatible
# with whatever the ghostty submodule currently pins. Resolution order:
# an explicit GVT_ZIG override, then the versioned Homebrew Cellar path
# this repo has been developed against, then whatever `zig` happens to
# be on PATH (warned about if its version doesn't look right, since an
# ABI mismatch here fails at Zig build/link time with a much less
# obvious error than "wrong zig version"). The same pinned zig doubles
# as the cross linker, so the shim objects and the final link always
# come from one toolchain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_DIR="$REPO_ROOT/calyx-session"
OUT_DIR="$REPO_ROOT/build/session"

MODE=host
for arg in "$@"; do
    case "$arg" in
        --all) MODE=all ;;
        --host-only) MODE=host ;;
        *)
            echo "usage: $0 [--all|--host-only]" >&2
            exit 2
            ;;
    esac
done

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
# rm before cp: same stale-code-signature-cache SIGKILL risk as the Bundle Session Daemon script in project.yml.
rm -f "$OUT_DIR/calyx-session"
cp "$SESSION_DIR/target/release/calyx-session" "$OUT_DIR/calyx-session"
chmod 0755 "$OUT_DIR/calyx-session"

echo "Built $OUT_DIR/calyx-session"

if [ "$MODE" != "all" ]; then
    exit 0
fi

# --- Linux musl cross builds (remote-install payloads) ---------------
#
# Each entry: <rust triple> <zig -target triple> <output arch dir>.
# vt-sys/build.rs maps the cargo TARGET to the matching `zig build
# -Dtarget` for the gvt shim on its own; the wrapper below only covers
# the final executable link, where `zig cc` provides the musl
# cross-linker this macOS host otherwise lacks.
REMOTE_TARGETS=(
    "x86_64-unknown-linux-musl x86_64-linux-musl x86_64"
    "aarch64-unknown-linux-musl aarch64-linux-musl aarch64"
)

INSTALLED_TARGETS="$(rustup target list --installed)"
LINKER_DIR="$OUT_DIR/zig-linkers"
mkdir -p "$LINKER_DIR"

for entry in "${REMOTE_TARGETS[@]}"; do
    read -r rust_triple zig_triple arch_dir <<< "$entry"

    if ! grep -qx "$rust_triple" <<< "$INSTALLED_TARGETS"; then
        echo "error: rustup target $rust_triple is not installed." >&2
        echo "Run: rustup target add $rust_triple" >&2
        exit 1
    fi

    echo "=== Building calyx-session ($rust_triple, release) ==="

    # cargo's linker setting must be a single executable, so wrap the
    # pinned zig in a generated shim script that bakes in `cc -target`.
    wrapper="$LINKER_DIR/zig-cc-$zig_triple"
    rm -f "$wrapper"
    printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "$GVT_ZIG" "$zig_triple" > "$wrapper"
    chmod 0755 "$wrapper"

    triple_env="$(tr '[:lower:]-' '[:upper:]_' <<< "$rust_triple")"

    (
        cd "$SESSION_DIR"
        # link-self-contained=no: for musl targets rustc normally
        # injects its own bundled CRT objects (rcrt1.o etc.), but zig
        # treats musl as a target it fully provisions and always links
        # its own compiled crt1.o, so the two collide on a duplicate
        # _start. Handing the whole C runtime to zig resolves it.
        #
        # Strip only the Linux payloads (host build keeps its symbols
        # for crash triage); rustc strips in-process, so this works
        # without a target-specific strip binary.
        env "CARGO_TARGET_${triple_env}_LINKER=$wrapper" \
            "CARGO_TARGET_${triple_env}_RUSTFLAGS=-C link-self-contained=no" \
            CARGO_PROFILE_RELEASE_STRIP=symbols \
            cargo build --release -p cli --target "$rust_triple"
    )

    dest_dir="$OUT_DIR/session-remote/$arch_dir"
    mkdir -p "$dest_dir"
    rm -f "$dest_dir/calyx-session"
    cp "$SESSION_DIR/target/$rust_triple/release/calyx-session" "$dest_dir/calyx-session"
    chmod 0755 "$dest_dir/calyx-session"

    echo "Built $dest_dir/calyx-session"
done
