#!/usr/bin/env python3
"""Measure transcript responsiveness using isolated sessions and a mock endpoint.

Defaults: 0/40 prior 4KiB replies, 12 seconds of streaming, 20 chunks/second.
Terminal-write gaps measure PTY activity, not individual answer paint times.
RSS is sampled for the test child only; it is not an exact lifetime maximum.
"""

import argparse
from dataclasses import dataclass, field
import fcntl
import http.server
import json
import math
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time
import uuid


class Timeline:
    def __init__(self):
        self.started = time.monotonic()
        self.started_unix = time.time()
        self.events = []
        self.lock = threading.Lock()

    def record(self, event, **details):
        with self.lock:
            now = time.monotonic()
            self.events.append({"event": event, "at_s": now - self.started, **details})
        return now

    def write(self, destination, metadata):
        with self.lock:
            events = list(self.events)
        destination.write_text(json.dumps({
            "started_unix_s": self.started_unix,
            "started_monotonic_s": self.started,
            "metadata": metadata,
            "events": events,
        }, indent=2) + "\n")


@dataclass
class StreamState:
    timeline: Timeline
    rate: float
    stream_format: str
    started: threading.Event = field(default_factory=threading.Event)
    stop: threading.Event = field(default_factory=threading.Event)
    request_at: float | None = None
    sent: list = field(default_factory=list)
    content_bytes_sent: int = 0


def stream_delta(sequence, stream_format):
    if stream_format == "markdown":
        content = (f"**STRESS-{sequence:05d}** with *emphasis* and `inline_code`.\n"
                   "```python\nprint('stream content')\n```\n")
    else:
        content = f"STRESS-{sequence:05d} " + "stream content " * 5 + "\n"
    key = "reasoning_content" if stream_format == "reasoning" else "content"
    return {key: content}, len(content.encode())


def make_server(active):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"data":[{"id":"stress-mock","context_window":131072}]}')

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state = active[payload["messages"][-1]["content"]]
            state.request_at = state.timeline.record(
                "request_received", message_count=len(payload["messages"])
            )
            state.started.set()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            state.timeline.record("response_headers_sent")
            try:
                while not state.stop.is_set():
                    sequence = len(state.sent)
                    delta, byte_count = stream_delta(sequence, state.stream_format)
                    event = {"choices": [{"index": 0, "delta": delta}]}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()
                    state.content_bytes_sent += byte_count
                    sent_at = state.timeline.record(
                        "chunk_sent", sequence=sequence, content_bytes=byte_count
                    )
                    state.sent.append(sent_at)
                    state.stop.wait(1 / state.rate)
            except (BrokenPipeError, ConnectionResetError):
                state.timeline.record("client_disconnected")
            finally:
                state.timeline.record("mock_stream_ended")
                self.close_connection = True

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.block_on_close = False
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    worker.start()
    return server, worker


def make_fixture(turn_count, folder, root, endpoint, reply_bytes):
    folder.mkdir()
    identifier = str(uuid.uuid4()).upper()
    now = time.time() * 1000
    unit = ('A **clear explanation** with an *important point* and `inline_code`.\n\n'
            '```python\ndef greet(name):\n    return f"Hello {name}"\n```\n\n')
    # This fixture is ASCII, so character truncation produces the exact byte size.
    reply = (unit * math.ceil(reply_bytes / len(unit)))[:reply_bytes]
    messages, turns = [], []
    for index in range(turn_count):
        prompt = f"Previous prompt {index}"
        for role, content in [("user", prompt), ("assistant", reply)]:
            messages.append({"id": str(uuid.uuid4()).upper(), "role": role,
                             "text": content, "state": "complete"})
        turns.append({"user": {"role": "user", "content": prompt},
                      "responses": [{"role": "assistant", "content": reply}]})
    record = {
        "schemaVersion": 1, "id": identifier, "title": "UI stress fixture",
        "createdAt": now, "updatedAt": now, "model": "stress-mock", "endpoint": endpoint,
        "api": "chat-completions",
        "workspacePath": str(root), "maximumTokens": 4096, "contextWindowTokens": 131072,
        "contextSafetyReserveTokens": 1024, "contextCompactAtPercent": 90,
        "contextStrategy": "slidingWindow", "activeSkills": [],
        "context": {"turns": turns, "totalOmittedTurns": 0},
        "transcript": {"messages": messages}, "inputHistory": [],
    }
    destination = folder / (identifier + ".json")
    destination.write_text(json.dumps(record))
    return destination


class RSSSampler:
    def __init__(self, pid, timeline):
        self.pid, self.timeline = pid, timeline
        self.stop = threading.Event()
        self.peak_kib = None
        self.samples = 0
        self.error = None
        self.latest_sample = None
        self.sample_lock = threading.Lock()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            cycle_started = time.monotonic()
            try:
                result = subprocess.run(
                    ["ps", "-o", "rss=", "-p", str(self.pid)],
                    capture_output=True, text=True, timeout=1, check=False,
                )
                if result.returncode or not result.stdout.strip():
                    self.error = result.stderr.strip() or "Process no longer available to ps."
                    self.timeline.record("rss_unavailable", detail=self.error)
                    return
                rss_kib = int(result.stdout.strip())
                self.peak_kib = max(self.peak_kib or 0, rss_kib)
                self.samples += 1
                sampled_at = self.timeline.record("rss_sample", pid=self.pid, rss_kib=rss_kib)
                with self.sample_lock:
                    self.latest_sample = (rss_kib, sampled_at)
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                self.error = str(error)
                self.timeline.record("rss_unavailable", detail=self.error)
                return
            self.stop.wait(max(0, 0.5 - (time.monotonic() - cycle_started)))

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=2)

    def latest(self):
        with self.sample_lock:
            return self.latest_sample


class TerminalReader:
    def __init__(self, master, snapshot, timeline):
        self.master, self.snapshot, self.timeline = master, snapshot, timeline
        self.output = bytearray()
        self.reads = []
        self.snapshot_version = None
        self.latest_record = {}
        self.observe_snapshot()

    def observe_snapshot(self):
        try:
            stat = self.snapshot.stat()
            version = (stat.st_mtime_ns, stat.st_size)
            if version == self.snapshot_version:
                return self.latest_record
            record = json.loads(self.snapshot.read_text())
        except (OSError, json.JSONDecodeError):
            return self.latest_record
        previous = self.snapshot_version
        self.snapshot_version, self.latest_record = version, record
        messages = record.get("transcript", {}).get("messages", [])
        assistant = next((m for m in reversed(messages) if m["role"] == "assistant"), None)
        self.timeline.record(
            "snapshot_written" if previous else "initial_snapshot",
            file_mtime_unix_ns=stat.st_mtime_ns, size_bytes=stat.st_size,
            message_count=len(messages), assistant_state=assistant["state"] if assistant else None,
            updated_at_unix_ms=record.get("updatedAt"),
        )
        return record

    def drain(self, duration):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            timeout = min(0.025, max(0, deadline - time.monotonic()))
            if select.select([self.master], [], [], timeout)[0]:
                try:
                    data = os.read(self.master, 262144)
                except OSError:
                    return
                if not data:
                    return
                self.output.extend(data)
                self.reads.append(self.timeline.record("pty_read", bytes=len(data)))
            self.observe_snapshot()


def percentile95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)] if ordered else None


def terminal_gaps(reads, start, end):
    # Include both edges: no writes during an entire stream is one full-length gap.
    times = [start] + [t for t in reads if start <= t <= end] + [end]
    return [right - left for left, right in zip(times, times[1:])]


def record_rss_boundary(result, name, sampler):
    # Reuse the 0.5s sampler so boundary measurements do not change the workload.
    sample = sampler.latest()
    result[f"rss_at_{name}_kib"] = sample[0] if sample else None
    result[f"rss_at_{name}_sample_age_s"] = round(time.monotonic() - sample[1], 6) if sample else None


def run_case(args, root, endpoint, active, turn_count, repetition, case_index):
    key = f"run-{case_index:03d}-turns-{turn_count}-repeat-{repetition}"
    timeline = Timeline()
    metadata = {"label": args.label, "prior_turns": turn_count, "repetition": repetition,
                "seconds": args.seconds, "rate": args.rate, "columns": args.columns,
                "rows": args.rows, "reply_bytes": args.reply_bytes,
                "stream_format": args.stream_format, "thinking": args.thinking,
                "idle_after_stop": args.idle_after_stop,
                "binary": str(args.binary)}
    folder = root / key
    snapshot = make_fixture(turn_count, folder, root, endpoint, args.reply_bytes)
    initial_fixture_bytes = snapshot.stat().st_size
    state = StreamState(timeline, args.rate, args.stream_format)
    active[key] = state
    master, slave = pty.openpty()
    process = sampler = reader = None
    result = {"variant": args.label, "case": key, **metadata,
              "rss_at_stop_kib": None, "rss_at_idle_end_kib": None}
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.columns, 0, 0))
        environment = dict(os.environ, TERM="xterm-256color")
        environment.pop("OPENAI_API_KEY", None)
        process = subprocess.Popen(
            [str(args.binary), "--config", str(root / "config.json"),
             "--sessions-directory", str(folder), "--resume", "last"],
            stdin=slave, stdout=slave, stderr=slave, env=environment, start_new_session=True,
        )
        os.close(slave)
        slave = None
        timeline.record("process_launched", pid=process.pid)
        sampler = RSSSampler(process.pid, timeline)
        reader = TerminalReader(master, snapshot, timeline)
        reader.drain(2)

        if args.thinking is not None:
            setting = "on" if args.thinking else "off"
            timeline.record("thinking_command_sent", value=setting)
            os.write(master, f"/thinking {setting}\r".encode())
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                reader.drain(0.025)
                messages = reader.observe_snapshot().get("transcript", {}).get("messages", [])
                if any(f"Thinking display: {setting}." in m["text"] for m in messages):
                    timeline.record("thinking_setting_confirmed", value=setting)
                    break
            else:
                raise RuntimeError("Thinking setting was not confirmed within 5 seconds.")

        sent_at = timeline.record("prompt_sent")
        os.write(master, key.encode() + b"\r")
        deadline = sent_at + 15
        while not state.started.is_set() and time.monotonic() < deadline:
            reader.drain(0.025)
            if process.poll() is not None:
                raise RuntimeError(f"Application exited before the request (code {process.returncode}).")
        if not state.started.is_set():
            raise RuntimeError("Request did not begin within 15 seconds.")
        start = state.request_at
        while time.monotonic() < start + args.seconds:
            reader.drain(min(0.025, max(0, start + args.seconds - time.monotonic())))
            if process.poll() is not None:
                raise RuntimeError(f"Application exited during streaming (code {process.returncode}).")

        stop_at = timeline.record("interrupt_sent")
        os.write(master, b"\x03")
        stopped_at = None
        deadline = stop_at + 6
        while time.monotonic() < deadline:
            reader.drain(0.01)
            messages = reader.observe_snapshot().get("transcript", {}).get("messages", [])
            assistant = next((m for m in reversed(messages) if m["role"] == "assistant"), None)
            if assistant and assistant["state"] == "stopped":
                stopped_at = timeline.record("stopped_snapshot_observed")
                record_rss_boundary(result, "stop", sampler)
                break
            if process.poll() is not None:
                break
        state.stop.set()
        reader.drain(0.1)
        if stopped_at is not None and args.idle_after_stop > 0:
            idle_started = timeline.record("idle_started", requested_seconds=args.idle_after_stop)
            deadline = idle_started + args.idle_after_stop
            while time.monotonic() < deadline and process.poll() is None:
                reader.drain(min(0.025, max(0, deadline - time.monotonic())))
            record_rss_boundary(result, "idle_end", sampler)
            timeline.record("idle_ended", elapsed_s=time.monotonic() - idle_started,
                            process_alive=process.poll() is None)
        final_messages = reader.observe_snapshot().get("transcript", {}).get("messages", [])
        final_assistant = next((m for m in reversed(final_messages) if m["role"] == "assistant"), None)
        gaps = terminal_gaps(reader.reads, start, stop_at)
        reads = [t for t in reader.reads if start <= t <= stop_at]
        sent_times = list(state.sent)
        send_gaps = [b - a for a, b in zip(sent_times, sent_times[1:])]
        result.update({
            "initial_fixture_bytes": initial_fixture_bytes, "fixture_bytes": snapshot.stat().st_size,
            "request_start_delay_s": round(start - sent_at, 6),
            "stream_interval_s": round(stop_at - start, 6),
            "mock_sent_chunks": len(sent_times), "mock_content_bytes": state.content_bytes_sent,
            "mock_max_gap_s": round(max(send_gaps), 6) if send_gaps else None,
            "pty_read_events": len(reads), "pty_max_gap_s": round(max(gaps), 6),
            "pty_p95_gap_s": round(percentile95(gaps), 6),
            "pty_first_write_delay_s": round(reads[0] - start, 6) if reads else None,
            "ctrl_c_to_saved_stopped_s": round(stopped_at - stop_at, 6) if stopped_at else None,
            "process_alive_after_stop": process.poll() is None, "output_bytes": len(reader.output),
            "final_assistant_content_bytes": len(final_assistant.get("text", "").encode()) if final_assistant else None,
            "final_assistant_reasoning_bytes": len((final_assistant.get("reasoning") or "").encode()) if final_assistant else None,
            "final_assistant_state": final_assistant.get("state") if final_assistant else None,
        })
        if stopped_at is None:
            result["error"] = "Ctrl-C did not produce a stopped snapshot within 6 seconds."
        elif process.poll() is not None:
            result["error"] = f"Application exited after interrupt (code {process.returncode})."
    except (OSError, RuntimeError) as error:
        result["error"] = str(error)
        timeline.record("case_failed", detail=str(error))
    finally:
        state.stop.set()
        if sampler:
            sampler.finish()
            result.update(peak_rss_kib=sampler.peak_kib, rss_samples=sampler.samples,
                          rss_error=sampler.error)
        if reader:
            (root / (key + ".terminal.log")).write_bytes(reader.output)
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if process:
            timeline.record("process_cleaned_up", returncode=process.returncode)
        os.close(master)
        if slave is not None:
            os.close(slave)
        timeline.write(root / (key + ".timeline.json"), metadata)
    return result


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--turns", type=int, nargs="+", default=[0, 40])
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--idle-after-stop", type=float, default=0,
                        help="Seconds to drain and sample RSS after a verified stop; boundary RSS uses the latest 0.5s sample.")
    parser.add_argument("--repeat", type=int, default=1, help="Repetitions of every requested history size.")
    parser.add_argument("--rate", type=float, default=20, help="Requested mock chunks/second; actual timestamps are recorded.")
    parser.add_argument("--columns", type=int, default=180)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--reply-bytes", type=int, default=4096, help="Bytes in each prior completed assistant reply.")
    parser.add_argument("--label", default="lowlight", help="Label saved in results and timelines.")
    parser.add_argument("--thinking", action=argparse.BooleanOptionalAction, default=None,
                        help="Explicitly show reasoning (--no-thinking hides it); otherwise keep app default.")
    parser.add_argument("--stream-format", choices=["plain", "markdown", "reasoning"], default="plain",
                        help="Format of live deltas; prior completed replies remain markdown fixtures.")
    parser.add_argument("--output-directory", type=Path, help="An empty directory for all artifacts; default is a new temp directory.")
    args = parser.parse_args()
    if any(n < 0 for n in args.turns) or args.reply_bytes <= 0 or args.repeat <= 0:
        parser.error("turns must be nonnegative; reply-bytes and repeat must be positive")
    if not math.isfinite(args.seconds) or not math.isfinite(args.rate) or args.seconds <= 0 or args.rate <= 0:
        parser.error("seconds and rate must be finite positive numbers")
    if not math.isfinite(args.idle_after_stop) or args.idle_after_stop < 0:
        parser.error("idle-after-stop must be finite and nonnegative")
    if not 1 <= args.rows <= 65535 or not 1 <= args.columns <= 65535:
        parser.error("rows and columns must be between 1 and 65535")
    args.binary = args.binary.resolve()
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error("binary must be an executable file")
    if args.output_directory:
        args.output_directory = args.output_directory.resolve()
        args.output_directory.mkdir(parents=True, exist_ok=True)
        if any(args.output_directory.iterdir()):
            parser.error("output-directory must be empty to preserve existing artifacts")
    return args


def main():
    args = parse_args()
    root = args.output_directory or Path(tempfile.mkdtemp(prefix="lowlight-ui-stress-"))
    (root / "config.json").write_text("{}\n")
    active, results = {}, []
    server, worker = make_server(active)
    endpoint = f"http://127.0.0.1:{server.server_port}/v1"
    try:
        for repetition in range(1, args.repeat + 1):
            for turns in args.turns:
                result = run_case(args, root, endpoint, active, turns, repetition, len(results) + 1)
                results.append(result)
                print(json.dumps(result), flush=True)
                (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    finally:
        for state in active.values():
            state.stop.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        print("Artifacts:", root, flush=True)
    return int(any(result.get("error") for result in results))


if __name__ == "__main__":
    raise SystemExit(main())
