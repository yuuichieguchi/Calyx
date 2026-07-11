#!/bin/bash
set -euo pipefail

# Drives the ~90-second Calyx product-demo XCUITest scenario
# (CalyxUITests/DemoRecordingScenario.swift) so a human can screen-record
# real Claude Code agents running in Calyx panes -- including a real
# approval-banner interaction -- without operating the app by hand.
#
# Refuses to run alongside a live production Calyx.app: both instances
# would fight over the same real, fixed
# ~/Library/Application Support/Calyx/agent-endpoint.json path (see
# CockpitApprovalE2ETests.swift's own header comment for why every
# pane-side script always reads that exact, no-override-possible path),
# so the demo's own "Enable AI Agent IPC" would clobber the production
# instance's endpoint file. Also requires the `claude` CLI on PATH --
# the scenario pastes `claude` into three panes and expects it to
# actually start a real agent.
#
# pkill/killall are prohibited in this repo: if a Calyx process is
# running, this asks the human to quit it rather than killing it out
# from under them.

cd "$(dirname "$0")/.."

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)
            SKIP_BUILD=1
            ;;
        *)
            echo "usage: $0 [--skip-build]" >&2
            echo "  --skip-build  run 'xcodebuild test-without-building' for a fast" >&2
            echo "                retake instead of a full 'xcodebuild test' -- requires" >&2
            echo "                a prior successful (non---skip-build) run of this" >&2
            echo "                script so the DebugUITesting products already exist." >&2
            exit 2
            ;;
    esac
done

if pgrep -x Calyx > /dev/null; then
    echo "ERROR: a Calyx.app process is currently running."
    echo
    echo "This demo needs sole use of the real"
    echo "~/Library/Application Support/Calyx/agent-endpoint.json path, so"
    echo "it cannot run alongside your normal Calyx session. This could"
    echo "also be a leftover demo-app instance from a crashed take (the"
    echo "demo build is a separate bundle ID, but the same process name,"
    echo "\"Calyx\") -- quit it from the Dock or Activity Monitor."
    echo
    echo "Then re-run this script."
    exit 1
fi

if ! command -v claude > /dev/null; then
    echo "ERROR: the 'claude' CLI was not found on PATH."
    echo "Install Claude Code first -- the demo scenario pastes 'claude'"
    echo "into three panes and expects it to actually start."
    exit 1
fi

# --- Fixture workspace ---------------------------------------------------
# Recreated fresh on every run so "Summarize the git log"/"List TODO
# comments" always see the same, known-good material regardless of
# whatever a previous run (or a previous demo take) left behind.

WORKSPACE=/tmp/calyx-demo-workspace
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/src" "$WORKSPACE/scripts"

cat > "$WORKSPACE/README.md" << 'EOF'
# Calyx Demo Workspace

A small fixture repo used only by `scripts/record-demo.sh` to drive
Calyx's scripted product-demo recording. Safe to delete -- this script
recreates it fresh on every run.
EOF

# Claude Code auto-loads the cwd's CLAUDE.md on startup -- this pins the
# fixture agents' response language and length for the recording without
# any on-camera instruction, so the demo reads as English/concise
# regardless of the operator's own Claude Code language preference.
cat > "$WORKSPACE/CLAUDE.md" << 'EOF'
# Demo workspace rules

- Respond only in English in this repository, regardless of any other language preference.
- Keep responses short: a few sentences or a compact list. This session is being screen-recorded.
EOF

cat > "$WORKSPACE/src/parser.py" << 'EOF'
"""Tiny config-line parser used by the demo fixture."""


def parse_line(line):
    key, _, value = line.partition("=")
    return key.strip(), value.strip()


# TODO: support quoted values containing '='
def parse_file(path):
    result = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            key, value = parse_line(line)
            result[key] = value
    return result
EOF

cat > "$WORKSPACE/src/cache.py" << 'EOF'
"""Tiny in-memory LRU cache used by the demo fixture."""

from collections import OrderedDict


class LRUCache:
    def __init__(self, capacity):
        self._capacity = capacity
        self._store = OrderedDict()

    def get(self, key):
        if key not in self._store:
            return None
        self._store.move_to_end(key)
        return self._store[key]

    # TODO: evict least-recently-used entry once len(_store) > capacity
    def put(self, key, value):
        self._store[key] = value
        self._store.move_to_end(key)
EOF

cat > "$WORKSPACE/src/main.py" << 'EOF'
"""Entry point wiring parser.py and cache.py together."""

from cache import LRUCache
from parser import parse_file


# TODO: read config_path from argv instead of hardcoding it below
def main(config_path):
    config = parse_file(config_path)
    cache = LRUCache(capacity=int(config.get("cache_size", "16")))
    cache.put("startup", "ok")
    print("Loaded", len(config), "config keys")


if __name__ == "__main__":
    main("config.ini")
EOF

cat > "$WORKSPACE/scripts/test.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Running test suite..."
sleep 2
echo "  collecting tests... 24 found"
sleep 3
echo "  running unit tests..."
sleep 3
echo "All 24 tests passed."
exit 0
EOF
chmod +x "$WORKSPACE/scripts/test.sh"

# --- git history, so "Summarize the git log" has real material ----------

(
    cd "$WORKSPACE"
    git init -q
    git config user.email "demo@calyx.local"
    git config user.name "Calyx Demo"

    # -c commit.gpgsign=false: these are throwaway fixture commits, not
    # real work -- must not fail (and abort this whole script under
    # `set -e`) just because the developer has global commit signing
    # (GPG/SSH) turned on. -c core.hooksPath=/dev/null: same reasoning,
    # insulating these commits from any global hooks that might reject
    # or alter them.
    git add README.md CLAUDE.md
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "Initial commit: demo workspace scaffold"

    git add src/parser.py src/cache.py
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "Add config parser and LRU cache utilities"

    git add src/main.py scripts/test.sh
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "Wire up main entry point and add test script"
)

# --- Run the scenario -----------------------------------------------------

echo
echo "=== Calyx Demo Recording ==="
echo "This launches an isolated Calyx.app instance (its own defaults"
echo "domain and session dir -- not your real Calyx state) at a fixed"
echo "1440x900 window, builds a 2x2 pane split, starts real 'claude'"
echo "agents in three panes, and drives a short scripted product demo"
echo "end to end, including a real approval-banner interaction."
echo
echo "When you see \"DEMO: PRE-ROLL COMPLETE\" in the log below (or the"
echo "4 panes visibly settle with their agents idle), start your screen"
echo "recording; the action begins 15 seconds later."
echo
echo "Note: the FIRST-EVER run of 'claude' against this fixture path on"
echo "this machine may show a one-time \"do you trust the files in this"
echo "folder?\" prompt; the scenario sends a Return to accept it, but if"
echo "a take looks wrong because of it, just retake."
echo

# Exit status captured explicitly (not left to `set -e`): a recorded
# XCTest failure makes xcodebuild exit non-zero, and this script's own
# closing endpoint-restore reminder below must still print in that case
# -- it's most needed exactly when something went wrong.
if [ "$SKIP_BUILD" -eq 1 ]; then
    if CALYX_DEMO_RECORDING=1 xcodebuild test-without-building \
        -project Calyx.xcodeproj \
        -scheme CalyxUITests \
        -only-testing:CalyxUITests/DemoRecordingScenario \
        -arch arm64; then
        status=0
    else
        status=$?
    fi
else
    if CALYX_DEMO_RECORDING=1 xcodebuild test \
        -project Calyx.xcodeproj \
        -scheme CalyxUITests \
        -only-testing:CalyxUITests/DemoRecordingScenario \
        -arch arm64; then
        status=0
    else
        status=$?
    fi
fi

echo
echo "Done. If you use the production Calyx again, re-run 'Enable AI Agent IPC' there to restore its endpoint file."
if [ "$status" -ne 0 ]; then
    echo "The take failed or recorded issues -- retake with --skip-build once you've fixed whatever went wrong."
fi

exit "$status"
