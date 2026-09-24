#!/usr/bin/env python3
"""Stdio MCP fixture server for MCPAppsE2ETests.

Speaks the legacy 2025-11-25 handshake over newline-delimited JSON
(one JSON-RPC message per line on stdin/stdout). Standard library only,
no network, single-threaded: `slow_tool` is implemented by simply never
writing a response line for its request id until either the process
exits or a `notifications/cancelled` for that id arrives, at which point
the pending id is discarded without an answer.

Invocation: mcp_apps_fixture_server.py --event-log <path>

`record_event` (an app-only tool, invoked only by the view's own bridge,
never by an agent) appends its `text` argument as one line to
`<event-log>` so the test can observe what the view saw without reaching
into the WKWebView's accessibility tree.

`crash` exits the process immediately after leaving a marker file
`<event-log>.crashed` next to the event log. On the NEXT startup (the
restarted child Calyx spawns), if that marker exists this script deletes
it and sleeps 5 seconds before answering `initialize`, so a test polling
the Settings row has a real window to observe a non-ready state
(Calyx's own restart backoff, then its connecting state during this
sleep) before the reconnect makes the row ready again.

Every UI tool's `tools/call` result carries
`_meta: {"ui": {"resourceUri": <that tool's own upstream resourceUri>}}`
(the same URI its `tools/list` definition declares), so the test can
observe Calyx exporting a result's `ui://` URI into the
`ui://<alias>/<upstream host>/...` namespace on the way to the agent.
"""
import base64
import json
import os
import sys
import time

RESOURCE_HOST = "fixture"

COUNTER_HTML = """<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MCP Apps Fixture Counter</title></head>
<body>
<div id="count">0</div>
<button id="incrementButton" type="button">Increment</button>
<button id="messageButton" type="button">Send ui/message</button>
<button id="modelOnlyButton" type="button">Call model_only</button>
<script>
(function () {
  "use strict";
  var nextId = 1;
  var pending = {};
  var counter = 0;
  var initializedSent = false;
  var eventBuffer = [];
  var eventChain = Promise.resolve();

  function countEl() { return document.getElementById("count"); }

  function callHost(method, params) {
    return new Promise(function (resolve, reject) {
      var id = nextId++;
      pending[id] = { resolve: resolve, reject: reject };
      window.parent.postMessage({ jsonrpc: "2.0", id: id, method: method, params: params || {} }, "*");
    });
  }

  function notifyHost(method, params) {
    window.parent.postMessage({ jsonrpc: "2.0", method: method, params: params || {} }, "*");
  }

  function sendRecordEvent(token) {
    return callHost("tools/call", { name: "record_event", arguments: { text: token } });
  }

  // Every observed event is funneled through this single promise chain
  // so record_event calls land at the fixture process in the same
  // order the view observed them, even though callHost itself is
  // async. Events before `ui/notifications/initialized` is sent are
  // buffered locally (the view must not talk to record_event, an
  // app-only tool routed the same way as any other tools/call, before
  // its own handshake completes) and flushed once it does.
  function logEvent(token) {
    if (!initializedSent) {
      eventBuffer.push(token);
      return;
    }
    eventChain = eventChain.then(function () { return sendRecordEvent(token); });
  }

  function flushBufferedEvents() {
    eventBuffer.forEach(function (token) {
      eventChain = eventChain.then(function () { return sendRecordEvent(token); });
    });
    eventBuffer = [];
  }

  function updateCounterDisplay() {
    countEl().textContent = String(counter);
  }

  function onToolResult(params) {
    counter += 1;
    updateCounterDisplay();
    var action = params && params.structuredContent && params.structuredContent.action;
    if (action === "message") {
      callHost("ui/message", {
        role: "user",
        content: [{ type: "text", text: "hello from view" }]
      }).then(function () {
        logEvent("view:message_sent");
      }, function () {
        logEvent("view:message_error");
      });
    } else if (action === "call_model_only") {
      callHost("tools/call", { name: "model_only", arguments: {} }).then(function () {
        logEvent("view:model_only_unexpected_success");
      }, function (err) {
        var code = err && err.code;
        logEvent("view:model_only_error:" + code);
      });
    }
  }

  window.addEventListener("message", function (event) {
    if (event.source !== window.parent) { return; }
    var msg = event.data;
    if (!msg || typeof msg !== "object") { return; }
    if (msg.id !== undefined && msg.id !== null && (msg.result !== undefined || msg.error !== undefined)) {
      var entry = pending[msg.id];
      if (!entry) { return; }
      delete pending[msg.id];
      if (msg.error) { entry.reject(msg.error); } else { entry.resolve(msg.result); }
      return;
    }
    if (msg.method === "ui/notifications/tool-input") {
      logEvent("host:tool-input");
    } else if (msg.method === "ui/notifications/tool-result") {
      logEvent("host:tool-result");
      onToolResult(msg.params);
    } else if (msg.method === "ui/notifications/tool-cancelled") {
      logEvent("host:tool-cancelled");
    } else if (msg.method === "ui/notifications/host-context-changed") {
      logEvent("host:context-changed");
    } else if (msg.method === "ui/resource-teardown") {
      logEvent("host:resource-teardown");
    }
  });

  document.getElementById("incrementButton").addEventListener("click", function () {
    counter += 1;
    updateCounterDisplay();
  });
  document.getElementById("messageButton").addEventListener("click", function () {
    callHost("ui/message", {
      role: "user",
      content: [{ type: "text", text: "hello from view" }]
    }).then(function () {
      logEvent("view:message_sent");
    }, function () {
      logEvent("view:message_error");
    });
  });
  document.getElementById("modelOnlyButton").addEventListener("click", function () {
    callHost("tools/call", { name: "model_only", arguments: {} }).then(function () {
      logEvent("view:model_only_unexpected_success");
    }, function (err) {
      var code = err && err.code;
      logEvent("view:model_only_error:" + code);
    });
  });

  async function main() {
    logEvent("view:ui/initialize-sent");
    await callHost("ui/initialize", {
      protocolVersion: "2026-01-26",
      appInfo: { name: "mcp-apps-fixture-view", version: "1.0.0" },
      appCapabilities: {}
    });
    logEvent("view:ui/initialize-result");
    initializedSent = true;
    notifyHost("ui/notifications/initialized", {});
    flushBufferedEvents();
    logEvent("view:initialized");
  }

  main();
})();
</script>
</body>
</html>
"""


def tool_def(name, description, resource_uri=None, visibility=None, mime_type="text/html;profile=mcp-app"):
    meta = {}
    if resource_uri is not None:
        ui = {"resourceUri": resource_uri, "mimeType": mime_type}
        if visibility is not None:
            ui["visibility"] = visibility
        meta["ui"] = ui
    elif visibility is not None:
        meta["ui"] = {"visibility": visibility}
    definition = {
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": True},
    }
    if meta:
        definition["_meta"] = meta
    return definition


TOOLS = [
    tool_def("show_counter", "Shows the fixture counter view.", resource_uri="ui://fixture/counter.html"),
    tool_def("slow_tool", "Sleeps until cancelled.", resource_uri="ui://fixture/counter.html"),
    tool_def("record_event", "Appends an observed view event to the event log.", visibility=["app"]),
    tool_def("model_only", "Model-only tool; must never be callable from a view.", visibility=["model"]),
    tool_def("crash", "Exits the server process immediately."),
    tool_def("show_bad_mime", "UI resource with the wrong MIME type.", resource_uri="ui://fixture/bad-mime.html"),
    tool_def("show_multi_content", "UI resource with two content items.", resource_uri="ui://fixture/multi-content.html"),
    tool_def("show_oversized", "UI resource over 10 MiB.", resource_uri="ui://fixture/oversized.html"),
    tool_def("show_bad_base64", "UI resource with an invalid base64 blob.", resource_uri="ui://fixture/bad-base64.html"),
    tool_def("show_non_ui_uri", "UI resource whose resourceUri is not ui://.", resource_uri="https://fixture.example/not-ui.html"),
]


def tool_resource_uri(name):
    """The `_meta.ui.resourceUri` the tool named `name` declares in TOOLS."""
    for definition in TOOLS:
        if definition["name"] == name:
            return definition["_meta"]["ui"]["resourceUri"]
    raise KeyError(name)


def write_message(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def respond(request_id, result):
    write_message({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id, code, message):
    write_message({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def resource_contents(uri, event_log_path):
    if uri == "ui://fixture/counter.html":
        return {"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": COUNTER_HTML}
    if uri == "ui://fixture/bad-mime.html":
        return {"uri": uri, "mimeType": "text/html", "text": COUNTER_HTML}
    if uri == "ui://fixture/oversized.html":
        padding = "A" * (11 * 1024 * 1024)
        return {"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": COUNTER_HTML + "<!--" + padding + "-->"}
    if uri == "ui://fixture/bad-base64.html":
        return {"uri": uri, "mimeType": "text/html;profile=mcp-app", "blob": "not-valid-base64!!!"}
    return None


def resource_contents_multi(uri):
    if uri == "ui://fixture/multi-content.html":
        return [
            {"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": COUNTER_HTML},
            {"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": "<html><body>second</body></html>"},
        ]
    return None


def handle_tools_call(request_id, params, event_log_path, crash_marker_path):
    name = params.get("name")
    arguments = params.get("arguments") or {}

    if name == "record_event":
        text = arguments.get("text", "")
        with open(event_log_path, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
        respond(request_id, {"content": [{"type": "text", "text": "recorded"}]})
        return

    if name == "model_only":
        respond(request_id, {"content": [{"type": "text", "text": "model-only result"}]})
        return

    if name == "crash":
        with open(crash_marker_path, "w", encoding="utf-8") as handle:
            handle.write("crashed\n")
        sys.stdout.flush()
        os._exit(1)

    if name == "slow_tool":
        # No response is written; PENDING_SLOW_CALLS remembers the id so
        # a later notifications/cancelled can be matched and discarded.
        PENDING_SLOW_CALLS.add(request_id)
        return

    if name in (
        "show_counter", "show_bad_mime", "show_multi_content",
        "show_oversized", "show_bad_base64", "show_non_ui_uri",
    ):
        action = arguments.get("action", "none")
        respond(request_id, {
            "content": [{"type": "text", "text": "shown"}],
            "structuredContent": {"action": action},
            "_meta": {"ui": {"resourceUri": tool_resource_uri(name)}},
        })
        return

    respond_error(request_id, -32602, "unknown tool: " + str(name))


PENDING_SLOW_CALLS = set()


def handle_resources_read(request_id, params, event_log_path):
    uri = params.get("uri")
    multi = resource_contents_multi(uri)
    if multi is not None:
        respond(request_id, {"contents": multi})
        return
    single = resource_contents(uri, event_log_path)
    if single is not None:
        respond(request_id, {"contents": [single]})
        return
    respond_error(request_id, -32602, "unknown resource: " + str(uri))


def main():
    event_log_path = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--event-log" and i + 1 < len(args):
            event_log_path = args[i + 1]
            i += 2
        else:
            i += 1
    if event_log_path is None:
        sys.exit("mcp_apps_fixture_server.py requires --event-log <path>")

    crash_marker_path = event_log_path + ".crashed"
    if os.path.exists(crash_marker_path):
        os.remove(crash_marker_path)
        time.sleep(5)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue

        method = message.get("method")
        request_id = message.get("id")

        if method == "initialize":
            respond(request_id, {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {"listChanged": True}, "resources": {}},
                "serverInfo": {"name": "mcp-apps-fixture", "version": "1.0.0"},
            })
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            respond(request_id, {"tools": TOOLS})
        elif method == "tools/call":
            handle_tools_call(request_id, message.get("params") or {}, event_log_path, crash_marker_path)
        elif method == "resources/read":
            handle_resources_read(request_id, message.get("params") or {}, event_log_path)
        elif method == "resources/list":
            respond(request_id, {"resources": []})
        elif method == "resources/templates/list":
            respond(request_id, {"resourceTemplates": []})
        elif method == "prompts/list":
            respond(request_id, {"prompts": []})
        elif method == "notifications/cancelled":
            cancelled_id = (message.get("params") or {}).get("requestId")
            PENDING_SLOW_CALLS.discard(cancelled_id)
        elif request_id is not None:
            respond_error(request_id, -32601, "method not found: " + str(method))


if __name__ == "__main__":
    main()
