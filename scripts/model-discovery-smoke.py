#!/usr/bin/env python3
"""Exercise model discovery in the built TUI against an isolated loopback fixture.

Usage: python3 scripts/model-discovery-smoke.py /absolute/path/to/lowlight
Uses temporary workspaces, config, and sessions. No real model is contacted.
Artifacts are retained under the printed temporary directory, including on failure.
"""

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


root = pathlib.Path(tempfile.mkdtemp(prefix="lowlight-model-discovery-"))
config = root / "config.json"
config.write_text("{}\n")
binary = str(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/lowlight").resolve())
lock = threading.Lock()
fixture = {"models": [], "status": 200, "scenario": "startup", "context": 4096}
requests = []
catalog_requests = []
processes = []
output = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with lock:
            status = fixture["status"] if self.path == "/v1/models" else 404
            models = list(fixture["models"])
            context = fixture["context"]
            catalog_requests.append({"path": self.path, "scenario": fixture["scenario"], "status": status})
        payload = {"object": "list", "data": [
            {"id": name, "object": "model", "owned_by": "midnight", "context_length": context}
            for name in models
        ]} if status == 200 else {"error": {"message": "Route not found"}}
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock:
            requests.append({"path": self.path, "scenario": fixture["scenario"], "body": payload})
            number = len(requests)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for delta, finish in [({"content": "Fixture answer %d." % number}, None), ({}, "stop")]:
            event = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = "http://127.0.0.1:%d/v1" % server.server_port


def check(value, message):
    if not value:
        raise AssertionError(message)
    print("PASS", message, flush=True)


def configure(scenario, models=(), status=200, context=4096):
    with lock:
        fixture.update(scenario=scenario, models=list(models), status=status, context=context)


def read(master, seconds=0.5):
    data = bytearray()
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if select.select([master], [], [], max(0, end - time.monotonic()))[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data.extend(chunk)
    text = data.decode("utf-8", errors="replace")
    output.append(text)
    return text


def send(master, text, seconds=0.6):
    os.write(master, text.encode())
    return read(master, seconds)


def command(master, text, seconds=0.6):
    return send(master, text + "\r", seconds)


def wait_for(master, predicate, message, timeout=8):
    end = time.monotonic() + timeout
    while not predicate() and time.monotonic() < end:
        read(master, 0.1)
    check(predicate(), message)


def launch(name, model=None, resume=None):
    workspace = root / name
    workspace.mkdir(exist_ok=True)
    sessions = workspace / "sessions"
    sessions.mkdir(exist_ok=True)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 130, 0, 0))
    args = [binary, "--api", "chat-completions", "--config", str(config), "--endpoint", endpoint,
            "--api-key-env", "LOWLIGHT_SMOKE_UNUSED_KEY", "--context-window", "8192",
            "--workspace", str(workspace), "--sessions-directory", str(sessions)]
    if model is not None:
        args += ["--model", model]
    if resume:
        args += ["--resume", resume]
    env = dict(os.environ, TERM="xterm-256color")
    env.pop("LOWLIGHT_SMOKE_UNUSED_KEY", None)
    before = len(catalog_requests)
    proc = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                            env=env, cwd=workspace, start_new_session=True)
    os.close(slave)
    processes.append((proc, master))
    wait_for(master, lambda: len(catalog_requests) > before,
             name + " queries /v1/models at startup")
    read(master, 0.6)
    check(proc.poll() is None, name + " TUI remains running")
    return proc, master, sessions


def stop(proc, master):
    send(master, "\x03", 0.5)
    send(master, "\x03", 0.5)
    # Keep draining the PTY while SwiftTUI finishes its final render and save.
    wait_for(master, lambda: proc.poll() is not None, "TUI exits", timeout=5)
    check(proc.returncode == 0, "TUI exits cleanly")


def latest(sessions):
    records = [json.loads(path.read_text()) for path in sessions.glob("*.json")]
    return max(records, key=lambda record: record["updatedAt"]) if records else None


def prompt(master, text, expected_model):
    before = len(requests)
    command(master, text)
    wait_for(master, lambda: len(requests) > before, "prompt reaches fixture endpoint")
    read(master, 0.3)
    check(len(requests) == before + 1, "prompt sends exactly one completion request")
    check(requests[-1]["path"] == "/v1/chat/completions"
          and requests[-1]["body"]["model"] == expected_model,
          "completion uses " + expected_model)


def blocked_prompt(master, text):
    before = len(requests)
    command(master, text)
    check(len(requests) == before, "no completion is sent without a usable model")
    send(master, "\x7f" * len(text), 0.2)


try:
    configure("automatic", ["active-first"])
    proc, master, sessions = launch("automatic")
    prompt(master, "discovery first turn", "active-first")
    wait_for(master, lambda: latest(sessions) is not None, "discovered model conversation is saved")
    original_id = latest(sessions)["id"]
    check(latest(sessions)["model"] == "active-first", "saved conversation records discovered model")

    check(latest(sessions)["contextWindowTokens"] == 4096, "server context replaces configured 8192-token window")

    configure("reconnect", ["active-second"], context=16384)
    before = len(catalog_requests)
    command(master, "/connection reconnect")
    wait_for(master, lambda: len(catalog_requests) > before, "reconnect refreshes the server model")
    prompt(master, "turn after reconnect", "active-second")
    check(latest(sessions)["contextWindowTokens"] == 16384, "reconnect picks up increased server context")
    stop(proc, master)

    configure("resume", ["active-third"])
    proc, master, sessions = launch("automatic", resume=original_id)
    saved = latest(sessions)
    check(saved["contextWindowTokens"] == 4096, "resume picks up decreased server context")
    check(saved["model"] == "active-third", "resume replaces unavailable saved model")
    contents = [message["text"] for message in saved["transcript"]["messages"]]
    check("discovery first turn" in contents and "turn after reconnect" in contents
          and any("Fixture answer" in text for text in contents),
          "resume preserves earlier user and assistant transcript")
    prompt(master, "resumed turn", "active-third")
    history = [message.get("content") for message in requests[-1]["body"]["messages"]]
    check("discovery first turn" in history and "turn after reconnect" in history,
          "resumed completion retains earlier conversation context")
    stop(proc, master)

    configure("multiple", ["choice-one", "choice-two"])
    proc, master, _ = launch("multiple")
    send(master, "\x1b", 0.3)  # Close the automatically opened model picker.
    blocked_prompt(master, "must wait for selection")
    command(master, "/model choice-two")
    prompt(master, "selected model turn", "choice-two")
    stop(proc, master)

    configure("empty")
    proc, master, _ = launch("empty")
    blocked_prompt(master, "no loaded model")
    stop(proc, master)

    configure("explicit-missing", ["available-model"])
    proc, master, _ = launch("explicit-missing", model="missing-model")
    send(master, "\x1b", 0.3)
    blocked_prompt(master, "explicit missing must not fall back")
    stop(proc, master)

    configure("explicit-valid", ["first-model", "explicit-model"])
    proc, master, _ = launch("explicit-valid", model="explicit-model")
    prompt(master, "honor explicit selection", "explicit-model")
    stop(proc, master)

    configure("unsupported-list", status=404)
    proc, master, sessions = launch("unsupported-list")
    draft = "draft waiting for explicit model"
    before = len(requests)
    send(master, draft, 0.8)
    wait_for(master, lambda: latest(sessions) is not None, "model-less draft autosaves")
    saved = latest(sessions)
    check(saved["model"] == "" and saved.get("draft") == draft,
          "model-less draft stores an empty model instead of a display label")
    stop(proc, master)
    proc, master, sessions = launch("unsupported-list", resume=saved["id"])
    check(latest(sessions).get("draft") == draft, "resume restores model-less draft")
    command(master, "")
    check(len(requests) == before, "404 model listing and resumed draft cannot trigger guessed model")
    send(master, "\x7f" * len(draft), 0.2)
    command(master, "/model manual-model")
    prompt(master, "explicit after resume", "manual-model")
    stop(proc, master)

    configure("unsupported-list-explicit", status=404)
    proc, master, _ = launch("unsupported-list-explicit", model="manual-direct")
    prompt(master, "explicit model without listing", "manual-direct")
    stop(proc, master)
    check(all(request["path"] == "/v1/models" for request in catalog_requests),
          "discovery uses the compatible model-list route only")
    print("SUCCESS", root, flush=True)
finally:
    (root / "terminal.log").write_text("".join(output))
    (root / "requests.json").write_text(json.dumps(requests, indent=2))
    (root / "catalog-requests.json").write_text(json.dumps(catalog_requests, indent=2))
    for proc, master in processes:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        os.close(master)
    server.shutdown()
    server.server_close()
    print("Artifacts:", root, flush=True)
