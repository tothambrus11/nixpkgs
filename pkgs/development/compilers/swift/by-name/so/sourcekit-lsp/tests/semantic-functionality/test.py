#!/usr/bin/env python3
"""Checks semantic functionality of SourceKit-LSP in a package with two modules that use Foundation.

Usage: test.py <package directory>
"""

import json
import os
import subprocess
import sys
import threading
import time

project = os.path.abspath(sys.argv[1])
document = os.path.join(project, "Sources", "App", "main.swift")
uri = "file://" + document
text = open(document).read()

server = subprocess.Popen(
    ["sourcekit-lsp", "--experimental-feature", "synchronize-for-build-system-updates"],
    cwd=project,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)
responses = {}
condition = threading.Condition()


def send(message):
    body = json.dumps({"jsonrpc": "2.0", **message}).encode()
    server.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    server.stdin.flush()


def read_messages():
    while True:
        headers = {}
        while (line := server.stdout.readline().decode().strip()) != "":
            key, value = line.split(":", 1)
            headers[key.lower()] = value.strip()
        if not headers:
            return
        message = json.loads(server.stdout.read(int(headers["content-length"])))
        if "id" in message and "method" in message:
            send({"id": message["id"], "result": None})
        elif "id" in message:
            with condition:
                responses[message["id"]] = message
                condition.notify_all()


threading.Thread(target=read_messages, daemon=True).start()
next_id = 0


def request(method, params):
    global next_id
    next_id += 1
    send({"id": next_id, "method": method, "params": params})
    with condition:
        if not condition.wait_for(lambda: next_id in responses, timeout=900):
            sys.exit(f"{method} timed out")
        response = responses.pop(next_id)
    if "error" in response:
        sys.exit(f"{method} failed: {response['error']}")
    return response["result"]


def position(line, before, word=""):
    """Returns the position of `word` following `before` on `line`."""
    character = text.splitlines()[line].index(before + word) + len(before)
    return {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}}


request("initialize", {"processId": os.getpid(), "rootUri": "file://" + project, "capabilities": {}})
send({"method": "initialized", "params": {}})
send({"method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "swift", "version": 1, "text": text}}})
request("workspace/synchronize", {"buildServerUpdates": True, "index": True})

failures = []


def check(description, condition, actual):
    print(f"{'PASS' if condition else 'FAIL'}: {description}: {actual!r}")
    if not condition:
        failures.append(description)


diagnostics = [item["message"] for item in request("textDocument/diagnostic", {"textDocument": {"uri": uri}})["items"]]
check("semantic diagnostics are reported", any("Cannot convert value of type" in d for d in diagnostics), diagnostics)

for line, before, word, expected in [
    (3, "= ", "URL", "struct URL"),
    (4, "= ", "Greeter", "struct Greeter"),
    (5, "greeter.", "greet", "func greet"),
]:
    hover = request("textDocument/hover", position(line, before, word))
    value = hover["contents"]["value"] if hover else None
    check(f"hover shows the declaration of {word}", value is not None and expected in value, value)

completion = request("textDocument/completion", position(5, "greeter."))
labels = [item["label"] for item in (completion["items"] if isinstance(completion, dict) else completion or [])]
check(
    "completion lists the members of Greeter",
    "home" in labels and any(label.startswith("greet") for label in labels),
    labels,
)

request("shutdown", None)
send({"method": "exit", "params": None})
sys.exit(1 if failures else 0)
