#!/usr/bin/env bash
#
# LSP MCP proxy smoke test.
# Verifies the live Calyx MCP server: tools/list returns 77 entries
# (7 IPC + 70 LSP), unknown tool surfaces an error, and a few tools
# that don't need a real language server return well-formed JSON.
#
# Requires:
# - Calyx running with AI Agent IPC enabled (Cmd+Shift+P -> Enable AI Agent IPC).
# - ~/.claude.json updated (Calyx auto-writes the Bearer token there).
# - jq for JSON parsing.

set -uo pipefail

token=$(python3 -c "
import json, sys
with open('${HOME}/.claude.json') as f:
    data = json.load(f)
servers = data.get('mcpServers') or {}
calyx = servers.get('calyx-ipc') or {}
hdrs = calyx.get('headers') or {}
auth = hdrs.get('Authorization', '')
print(auth.split()[1] if auth.startswith('Bearer ') else '')
")
if [[ -z "${token}" ]]; then
    echo "ERROR: could not extract calyx-ipc Bearer token from ~/.claude.json"
    echo "Enable AI Agent IPC in Calyx first."
    exit 1
fi

endpoint="http://127.0.0.1:41830/mcp"

post() {
    curl -s -X POST "${endpoint}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$1"
}

pass=0
fail=0

check() {
    local label="$1"
    local condition="$2"
    if eval "${condition}"; then
        echo "ok  - ${label}"
        pass=$((pass + 1))
    else
        echo "FAIL - ${label}"
        fail=$((fail + 1))
    fi
}

echo "== tools/list =="
list_resp=$(post '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
tool_count=$(echo "${list_resp}" | jq '.result.tools | length')
check "tools/list returns 77 entries" "[ \"${tool_count}\" = '77' ]"

names=$(echo "${list_resp}" | jq -r '.result.tools[].name' | sort)
echo "${names}" | grep -q '^lsp_hover$'
check "lsp_hover present" "[ $? -eq 0 ]"
echo "${names}" | grep -q '^lsp_session_status$'
check "lsp_session_status present" "[ $? -eq 0 ]"
echo "${names}" | grep -q '^lsp_check_installation$'
check "lsp_check_installation present" "[ $? -eq 0 ]"
echo "${names}" | grep -q '^lsp_notebook_did_open$'
check "lsp_notebook_did_open present" "[ $? -eq 0 ]"
echo "${names}" | grep -q '^register_peer$'
check "register_peer present (IPC tool)" "[ $? -eq 0 ]"

echo "== tools/call: lsp_session_status (no sessions yet) =="
status_resp=$(post '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lsp_session_status","arguments":{}}}')
is_error=$(echo "${status_resp}" | jq '.result.isError // false')
check "lsp_session_status isError=false" "[ \"${is_error}\" = 'false' ]"

echo "== tools/call: lsp_check_installation =="
check_resp=$(post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lsp_check_installation","arguments":{"language_id":"typescript"}}}')
text=$(echo "${check_resp}" | jq -r '.result.content[0].text')
check "lsp_check_installation returns languageId field" \
    "[ -n \"\$(echo '${text}' | jq -r '.languageId // empty')\" ]"

echo "== tools/call: unknown LSP tool =="
unknown_resp=$(post '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lsp_nonexistent","arguments":{}}}')
unknown_err=$(echo "${unknown_resp}" | jq '.result.isError // false')
check "unknown LSP tool surfaces isError=true" "[ \"${unknown_err}\" = 'true' ]"

echo "== tools/call: missing required argument =="
missing_resp=$(post '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"lsp_hover","arguments":{}}}')
missing_err=$(echo "${missing_resp}" | jq '.result.isError // false')
check "missing argument surfaces isError=true" "[ \"${missing_err}\" = 'true' ]"

echo
echo "== summary =="
echo "passed: ${pass}"
echo "failed: ${fail}"
if [[ ${fail} -gt 0 ]]; then
    exit 1
fi
