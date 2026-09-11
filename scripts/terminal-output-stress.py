#!/usr/bin/env python3
"""Measure Experimental Lowlight while its embedded terminal produces output.

Usage: python3 scripts/terminal-output-stress.py /path/to/experimental/release/lowlight
Defaults to 80/180 columns, a silent foreground baseline and bounded output at
20 ticks/s, 20 lines/tick, and 100 columns/line. Each producer self-terminates
after 15 seconds; chat streams for 6 seconds before Ctrl-C. Both interruptions
are measured independently. Use --producer-seconds 25 --stream-seconds 12 to
cross an autosave interval. All HTTP traffic uses an isolated loopback fixture.

Artifacts include JSON results, resource samples, producer timestamps, rendered
screens, and capped raw PTY logs. Marker latency is producer-write to observed
rendered screen, including the harness's sampling delay; it is not GPU latency.
A hidden terminal at narrow widths cannot produce visible-marker measurements.
Only PIDs created by this harness are sampled or signaled during cleanup.
"""

import argparse
import codecs
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unicodedata

# The VT reader is copied from Experimental workspace-smoke.py. Importing that
# executable smoke script would start a second app and endpoint.
class Screen:
    """Small VT screen reader for assertions against rendered, non-stale cells."""

    def __init__(self, rows=42, columns=180):
        self.rows, self.columns = rows, columns
        self.cells = [[" "] * columns for _ in range(rows)]
        self.row = self.column = 0
        self.top, self.bottom = 0, rows - 1
        self.saved = (0, 0)
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    @property
    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.cells)

    def linefeed(self):
        if self.row == self.bottom:
            self.cells.pop(self.top)
            self.cells.insert(self.bottom, [" "] * self.columns)
        else:
            self.row = min(self.rows - 1, self.row + 1)

    def feed(self, data):
        text = self.pending + self.decoder.decode(data)
        self.pending = ""
        i = 0
        while i < len(text):
            char = text[i]
            if char == "\x1b":
                if i + 1 >= len(text):
                    break
                kind = text[i + 1]
                if kind == "[":
                    match = re.search(r"[\x40-\x7e]", text[i + 2:])
                    if not match:
                        break
                    end = i + 2 + match.start()
                    self.csi(text[i + 2:end], text[end])
                    i = end + 1
                    continue
                if kind in "]P_^":
                    match = re.search(r"\x07|\x1b\\", text[i + 2:])
                    if not match:
                        break
                    i += 2 + match.end()
                    continue
                if kind in "()#":
                    if i + 2 >= len(text):
                        break
                    i += 3
                    continue
                if kind == "7":
                    self.saved = self.row, self.column
                elif kind == "8":
                    self.row, self.column = self.saved
                elif kind == "D":
                    self.linefeed()
                elif kind == "E":
                    self.column = 0
                    self.linefeed()
                elif kind == "M":
                    if self.row == self.top:
                        self.cells.pop(self.bottom)
                        self.cells.insert(self.top, [" "] * self.columns)
                    else:
                        self.row = max(0, self.row - 1)
                i += 2
                continue
            if char == "\r":
                self.column = 0
            elif char == "\n":
                self.linefeed()
            elif char == "\b":
                self.column = max(0, self.column - 1)
            elif char == "\t":
                self.column = min(self.columns - 1, (self.column // 8 + 1) * 8)
            elif ord(char) >= 32 and char != "\x7f":
                if unicodedata.combining(char):
                    if self.column:
                        self.cells[self.row][self.column - 1] += char
                    i += 1
                    continue
                width = 2 if unicodedata.east_asian_width(char) in "WF" else 1
                if self.column >= self.columns:
                    self.column = 0
                    self.linefeed()
                self.cells[self.row][self.column] = char
                if width == 2 and self.column + 1 < self.columns:
                    self.cells[self.row][self.column + 1] = ""
                self.column += width
            i += 1
        self.pending = text[i:]

    def csi(self, parameters, final):
        private = parameters.startswith("?")
        numbers = [int(part) if part.isdigit() else 0
                   for part in parameters.lstrip("?<=>").split(";")]
        n = numbers[0] or 1
        if final in "Hf":
            self.row = min(self.rows - 1, n - 1)
            self.column = min(self.columns - 1, (numbers[1] or 1) - 1) if len(numbers) > 1 else 0
        elif final == "A":
            self.row = max(0, self.row - n)
        elif final == "B":
            self.row = min(self.rows - 1, self.row + n)
        elif final == "C":
            self.column = min(self.columns - 1, self.column + n)
        elif final == "D":
            self.column = max(0, self.column - n)
        elif final in "G`":
            self.column = min(self.columns - 1, n - 1)
        elif final == "d":
            self.row = min(self.rows - 1, n - 1)
        elif final in "EF":
            self.row = min(self.rows - 1, max(0, self.row + (n if final == "E" else -n)))
            self.column = 0
        elif final == "J":
            if numbers[0] in (2, 3):
                self.cells = [[" "] * self.columns for _ in range(self.rows)]
            else:
                for row in range(self.rows):
                    for column in range(self.columns):
                        if ((numbers[0] == 0 and (row, column) >= (self.row, self.column))
                                or (numbers[0] == 1 and (row, column) <= (self.row, self.column))):
                            self.cells[row][column] = " "
        elif final == "K":
            start = self.column if numbers[0] == 0 else 0
            end = self.column + 1 if numbers[0] == 1 else self.columns
            self.cells[self.row][start:end] = [" "] * (end - start)
        elif final == "X":
            end = min(self.columns, self.column + n)
            self.cells[self.row][self.column:end] = [" "] * (end - self.column)
        elif final in "@P":
            row = self.cells[self.row]
            if final == "@":
                row[self.column:self.column] = [" "] * n
                del row[self.columns:]
            else:
                del row[self.column:min(self.columns, self.column + n)]
                row.extend([" "] * (self.columns - len(row)))
        elif final == "r" and not private:
            self.top = min(self.rows - 1, n - 1)
            self.bottom = min(self.rows - 1, (numbers[1] or self.rows) - 1) if len(numbers) > 1 else self.rows - 1
        elif final in "STLM":
            top = self.row if final in "LM" else self.top
            if top <= self.bottom:
                for _ in range(min(n, self.bottom - top + 1)):
                    if final in "SM":
                        self.cells.pop(top)
                        self.cells.insert(self.bottom, [" "] * self.columns)
                    else:
                        self.cells.pop(self.bottom)
                        self.cells.insert(top, [" "] * self.columns)
        elif final == "s":
            self.saved = self.row, self.column
        elif final == "u":
            self.row, self.column = self.saved
        elif private and final == "h" and any(value in (1047, 1049) for value in numbers):
            self.cells = [[" "] * self.columns for _ in range(self.rows)]
            self.row = self.column = 0


PRODUCER_SOURCE = r'''
import argparse,json,os,signal,sys,time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,required=True)
p.add_argument('--mode',choices=['inactive','active'],required=True)
p.add_argument('--seconds',type=float,required=True)
p.add_argument('--hz',type=float,required=True)
p.add_argument('--lines',type=int,required=True)
p.add_argument('--width',type=int,required=True)
a=p.parse_args()
interrupted=False
def stop(*_):
    global interrupted
    interrupted=True
signal.signal(signal.SIGINT,stop)
signal.signal(signal.SIGTERM,stop)
start=time.monotonic()
(a.root/'producer.pid.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'started_at':start}))
markers=[]
written=0
try:
    tick=0
    while not interrupted and time.monotonic()-start<a.seconds:
        if a.mode=='active' or tick==0:
            marker='TSM%05d'%tick
            payload=('output %05d '%tick+'x'*a.width)[:a.width]+'\n'
            text=(payload*a.lines if a.mode=='active' else '')+marker+'\n'
            produced=time.monotonic()
            sys.stdout.write(text)
            sys.stdout.flush()
            written+=len(text.encode())
            markers.append({'marker':marker,'produced_at':produced})
        tick+=1
        time.sleep(max(0,min(1/a.hz,start+tick/a.hz-time.monotonic())))
finally:
    ended=time.monotonic()
    (a.root/'producer.result.json').write_text(json.dumps({'mode':a.mode,'interrupted':interrupted,'started_at':start,'ended_at':ended,'bytes_written':written,'markers':markers}))
    print('TERMINAL_PRODUCER_ENDED',flush=True)
'''


def read_json(path, fallback=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def cpu_seconds(value):
    days, clock = value.split('-', 1) if '-' in value else ('0', value)
    result = 0.0
    for component in clock.split(':'):
        result = result * 60 + float(component)
    return int(days) * 86400 + result


class ResourceSampler:
    def __init__(self):
        self.pids = {}
        self.samples = []
        self.errors = []
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def add(self, label, pid):
        with self.lock:
            self.pids[pid] = label

    def run(self):
        while not self.stop.wait(0.5):
            with self.lock:
                pids = dict(self.pids)
            if not pids:
                continue
            try:
                output = subprocess.run(
                    ['ps', '-p', ','.join(map(str, pids)), '-o', 'pid=,rss=,time='],
                    check=False, text=True, capture_output=True, timeout=2)
                if output.returncode not in (0, 1) or output.stderr.strip():
                    raise RuntimeError(output.stderr.strip() or 'ps failed')
                rows = []
                for line in output.stdout.splitlines():
                    pid, rss, cpu = line.split()
                    rows.append({'pid': int(pid), 'label': pids[int(pid)],
                                 'rss_kib': int(rss), 'cpu_s': cpu_seconds(cpu)})
                self.samples.append({'at': time.monotonic(), 'processes': rows})
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                if str(error) not in self.errors:
                    self.errors.append(str(error))

    def close(self):
        self.stop.set()
        self.thread.join(timeout=3)

    def summary(self, start, end):
        samples = [sample for sample in self.samples if start <= sample['at'] <= end]
        last = {}
        cpu = {}
        peak = {}
        owned_peak = 0
        for sample in samples:
            owned_peak = max(owned_peak, sum(row['rss_kib'] for row in sample['processes']))
            for row in sample['processes']:
                label = row['label']
                peak[label] = max(peak.get(label, 0), row['rss_kib'])
                if row['pid'] in last:
                    cpu[label] = cpu.get(label, 0) + max(0, row['cpu_s'] - last[row['pid']])
                last[row['pid']] = row['cpu_s']
        elapsed = samples[-1]['at'] - samples[0]['at'] if len(samples) > 1 else 0
        return {'samples': len(samples), 'sampled_window_s': round(elapsed, 3),
                'peak_rss_mib': {key: round(value / 1024, 2) for key, value in peak.items()},
                'owned_peak_rss_mib': round(owned_peak / 1024, 2),
                'mean_cpu_cores': {key: round(value / elapsed, 3) for key, value in cpu.items()} if elapsed else {},
                'errors': self.errors}


class StreamingFixture:
    def __init__(self, maximum_seconds):
        self.started = threading.Event()
        self.stop = threading.Event()
        self.disconnected = threading.Event()
        self.sent = []
        self.request = None
        self.request_at = None
        self.disconnected_at = None
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                payload = {'data': [{'id': 'terminal-stress', 'context_window': 32768}]}
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def do_POST(self):
                fixture.request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                fixture.request_at = time.monotonic()
                fixture.started.set()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                try:
                    for index in range(int(maximum_seconds / 0.05)):
                        if fixture.stop.is_set():
                            break
                        value = 'CHAT%05d: Streaming a small answer while the terminal works.\n' % index
                        chunk = {'choices': [{'index': 0, 'delta': {'content': value}}]}
                        self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                        self.wfile.flush()
                        fixture.sent.append(time.monotonic())
                        fixture.stop.wait(0.05)
                except (BrokenPipeError, ConnectionResetError):
                    fixture.disconnected_at = time.monotonic()
                    fixture.disconnected.set()

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = 'http://127.0.0.1:%d/v1' % self.server.server_port

    def close(self):
        self.stop.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class TerminalDriver:
    def __init__(self, master, screen, process, artifact):
        self.master, self.screen, self.process = master, screen, process
        self.log = artifact.open('wb')
        self.log_bytes = 0
        self.output_bytes = 0
        self.reads = []
        self.markers = {}
        self.log_limit = 32 * 1024 * 1024

    def drain(self, seconds=0.025):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not select.select([self.master], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            self.reads.append(time.monotonic())
            self.output_bytes += len(data)
            retained = data[:max(0, self.log_limit - self.log_bytes)]
            self.log.write(retained)
            self.log_bytes += len(retained)
            self.screen.feed(data)
            # A complete marker occupies a rendered output line, not command echo.
            for marker in re.findall(r'TSM\d{5}', self.screen.text):
                self.markers.setdefault(marker, time.monotonic())

    def wait(self, predicate, label, timeout=6):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Lowlight exited while waiting for ' + label)
            self.drain()
        if not predicate():
            raise RuntimeError('Timed out waiting for ' + label)

    def send(self, value):
        os.write(self.master, value.encode())

    def command(self, value):
        self.send(value)
        self.drain(0.06)
        self.send('\r')

    def focus_chat(self):
        self.send('\x0f')
        self.wait(lambda: 'Terminal focused' not in self.screen.text and
                  ('Chat focused' in self.screen.text or 'Type your message' in self.screen.text), 'chat focus')

    def focus_terminal(self):
        self.send('\x0f')
        self.wait(lambda: 'Terminal focused' in self.screen.text, 'terminal focus')

    def snapshot(self, path):
        path.write_text(self.screen.text)


def stopped_conversation(sessions):
    for path in sessions.glob('*.json'):
        record = read_json(path, {})
        messages = record.get('transcript', {}).get('messages', [])
        if messages and messages[-1].get('role') == 'assistant' and messages[-1].get('state') == 'stopped':
            return True
    return False


def percentile(values, fraction):
    return sorted(values)[min(len(values) - 1, int(len(values) * fraction))] if values else None


def rounded(value):
    return round(value, 4) if value is not None else None


def run_case(args, root, columns, mode):
    folder = root / ('%d-%s' % (columns, mode))
    folder.mkdir()
    workspace, sessions = folder / 'workspace', folder / 'sessions'
    workspace.mkdir()
    sessions.mkdir()
    (folder / 'settings.json').write_text('{}\n')
    producer = folder / 'producer.py'
    producer.write_text(PRODUCER_SOURCE)
    fixture = StreamingFixture(args.producer_seconds + 15)
    sampler = ResourceSampler()
    sampler.add('harness', os.getpid())
    groups, own_pids = set(), set()
    result = {'columns': columns, 'rows': args.rows, 'terminal_output': mode}
    driver = process = None
    master = slave = None
    def remember(label, pid):
        own_pids.add(pid)
        sampler.add(label, pid)
        try:
            pgid = os.getpgid(pid)
            if pgid != os.getpgrp():
                groups.add(pgid)
        except ProcessLookupError:
            pass
    try:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', args.rows, columns, 0, 0))
        environment = dict(os.environ, TERM='xterm-256color', SHELL='/bin/sh')
        for key in ['LINES', 'COLUMNS', 'ENV', 'BASH_ENV', 'LOWLIGHT_STRESS_UNUSED_KEY']:
            environment.pop(key, None)
        command = [str(args.binary.resolve()), '--api', 'chat-completions', '--config', str(folder / 'settings.json'),
                   '--endpoint', fixture.endpoint, '--model', 'terminal-stress',
                   '--api-key-env', 'LOWLIGHT_STRESS_UNUSED_KEY', '--context-window', '32768',
                   '--max-tokens', '4096', '--workspace', str(workspace), '--sessions-directory', str(sessions)]
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                   cwd=workspace, env=environment, start_new_session=True)
        os.close(slave)
        slave = None
        remember('lowlight', process.pid)
        driver = TerminalDriver(master, Screen(args.rows, columns), process, folder / 'terminal.log')
        driver.wait(lambda: 'Type your message' in driver.screen.text, 'initial composer', timeout=12)
        driver.command('/terminal')
        driver.wait(lambda: 'Terminal focused' in driver.screen.text, 'embedded shell')
        shell_file = folder / 'shell.pid'
        driver.command("printf '%s\\n' \"$$\" > " + shlex.quote(str(shell_file)))
        driver.wait(shell_file.exists, 'shell PID')
        shell_pid = int(shell_file.read_text().strip())
        remember('shell', shell_pid)
        producer_command = [sys.executable, str(producer), '--root', str(folder), '--mode', mode,
                            '--seconds', str(args.producer_seconds), '--hz', str(args.tick_hz),
                            '--lines', str(args.lines_per_tick), '--width', str(args.line_width)]
        driver.command(shlex.join(producer_command))
        pid_file = folder / 'producer.pid.json'
        driver.wait(lambda: read_json(pid_file) is not None, 'bounded output producer')
        producer_pid = read_json(pid_file)['pid']
        remember('producer', producer_pid)
        driver.wait(lambda: bool(driver.markers), 'initial rendered terminal marker')
        terminal_hidden_at = time.monotonic() if columns < 100 else None
        driver.focus_chat()
        send_at = time.monotonic()
        driver.command('Measure terminal output responsiveness.')
        driver.wait(fixture.started.is_set, 'mock chat request', timeout=10)
        start = fixture.request_at
        while time.monotonic() < start + args.stream_seconds:
            driver.drain()
        driver.snapshot(folder / 'streaming.screen.txt')
        stop_at = time.monotonic()
        driver.send('\x03')
        driver.wait(lambda: stopped_conversation(sessions), 'saved chat stop')
        saved_stop = time.monotonic()
        result['chat_ctrl_c_to_saved_stop_s'] = rounded(saved_stop - stop_at)
        result['request_start_delay_s'] = rounded(start - send_at)
        if mode == 'active' and (folder / 'producer.result.json').exists():
            raise RuntimeError('Producer ended before the interruption measurement; increase --producer-seconds')
        driver.focus_terminal()
        terminal_visible_at = time.monotonic()
        driver.drain(0.2)
        driver.snapshot(folder / 'before-terminal-interrupt.screen.txt')
        foreground_interrupt = time.monotonic()
        driver.send('\x03')
        producer_result_path = folder / 'producer.result.json'
        driver.wait(lambda: read_json(producer_result_path) is not None, 'foreground interrupt result')
        production = read_json(producer_result_path)
        if not production['interrupted'] or production['ended_at'] < foreground_interrupt:
            raise RuntimeError('Producer reached its deadline before Ctrl-C; foreground timing is invalid')
        result['terminal_ctrl_c_to_producer_stop_s'] = rounded(production['ended_at'] - foreground_interrupt)
        driver.wait(lambda: not alive(producer_pid), 'foreground process exit')
        result['terminal_ctrl_c_to_child_exit_observed_s'] = rounded(time.monotonic() - foreground_interrupt)
        marker_start = time.monotonic()
        driver.command("printf 'SHELL_%s\\n' 'READY'")
        driver.wait(lambda: any(re.search(r'SHELL_READY\s*(?:[│┃┤]|$)', line)
                                for line in driver.screen.text.splitlines()), 'shell marker after interrupt')
        result['shell_marker_roundtrip_s'] = rounded(time.monotonic() - marker_start)
        driver.snapshot(folder / 'after-terminal-interrupt.screen.txt')
        result['app_alive_after_interrupts'] = process.poll() is None
        result['shell_alive_after_interrupts'] = alive(shell_pid)
        result['producer_interrupted'] = production['interrupted']
        result['producer_bytes_written'] = production['bytes_written']
        visible_markers = [item for item in production['markers']
                           if terminal_hidden_at is None or
                           not terminal_hidden_at <= item['produced_at'] <= terminal_visible_at]
        marker_latencies = [driver.markers[item['marker']] - item['produced_at']
                            for item in visible_markers if item['marker'] in driver.markers]
        result['terminal_markers_written'] = len(production['markers'])
        result['terminal_markers_written_while_visible'] = len(visible_markers)
        result['terminal_markers_observed'] = len(marker_latencies)
        result['marker_latency_p50_s'] = rounded(percentile(marker_latencies, 0.50))
        result['marker_latency_p95_s'] = rounded(percentile(marker_latencies, 0.95))
        result['marker_latency_max_s'] = rounded(max(marker_latencies, default=0))
        result['marker_scope'] = 'markers produced while terminal visible; hidden narrow-pane interval excluded'
        reads = [at for at in driver.reads if start <= at <= stop_at]
        gaps = [later - earlier for earlier, later in zip([start] + reads, reads + [stop_at])]
        result['pty_max_gap_during_stream_s'] = rounded(max(gaps, default=0))
        result['pty_p95_gap_during_stream_s'] = rounded(percentile(gaps, 0.95))
        result['mock_sent_chunks'] = len(fixture.sent)
        result['mock_max_gap_s'] = rounded(max([b - a for a, b in zip(fixture.sent, fixture.sent[1:])], default=0))
        result['resources_during_stream'] = sampler.summary(start, stop_at)
        result['pty_output_bytes'] = driver.output_bytes
        result['raw_log_capped'] = driver.output_bytes > driver.log_limit
        driver.focus_chat()
        driver.send('\x04')
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            driver.drain()
        result['clean_app_exit'] = process.poll() == 0
        if not result['clean_app_exit']:
            raise RuntimeError('Lowlight did not exit cleanly after the interruptions')
    except Exception as error:
        result['error'] = str(error)
        if driver:
            driver.snapshot(folder / 'failure.screen.txt')
    finally:
        fixture.close()
        sampler.close()
        # Recover children even if a UI timeout happened before their PID was
        # consumed. Descendant lookup is scoped to this harness's known roots.
        shell_file = folder / 'shell.pid'
        if shell_file.exists():
            try:
                remember('shell', int(shell_file.read_text().strip()))
            except (OSError, ValueError):
                pass
        producer_identity = read_json(folder / 'producer.pid.json', {})
        if isinstance(producer_identity.get('pid'), int):
            remember('producer', producer_identity['pid'])
        queue, checked = list(own_pids), set()
        while queue:
            pid = queue.pop()
            if pid in checked:
                continue
            checked.add(pid)
            try:
                children = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True,
                                          text=True, timeout=1)
                for child in children.stdout.split():
                    child_pid = int(child)
                    remember('descendant', child_pid)
                    queue.append(child_pid)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
        # Embedded shells have separate sessions/process groups. Signal only
        # groups observed from our app's PID or PID files inside this fixture.
        for signum in [signal.SIGHUP, signal.SIGTERM, signal.SIGKILL]:
            for pgid in groups:
                try:
                    os.killpg(pgid, signum)
                except ProcessLookupError:
                    pass
            if process:
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
            if all(not alive(pid) for pid in own_pids):
                break
            time.sleep(0.1)
        if driver:
            driver.log.close()
        for descriptor in [master, slave]:
            if descriptor is not None:
                os.close(descriptor)
        result['cleanup_live_owned_pids'] = sorted(pid for pid in own_pids if alive(pid))
        (folder / 'resources.json').write_text(json.dumps({'samples': sampler.samples, 'errors': sampler.errors}, indent=2))
        (folder / 'mock.json').write_text(json.dumps({'request': fixture.request, 'request_at': fixture.request_at,
            'sent_at': fixture.sent, 'disconnected_at': fixture.disconnected_at}, indent=2))
        (folder / 'result.json').write_text(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path, help='Experimental lowlight release executable')
    parser.add_argument('--columns', type=int, nargs='+', default=[80, 180])
    parser.add_argument('--rows', type=int, default=40)
    parser.add_argument('--modes', choices=['inactive', 'active'], nargs='+', default=['inactive', 'active'])
    parser.add_argument('--producer-seconds', type=float, default=15)
    parser.add_argument('--stream-seconds', type=float, default=6)
    parser.add_argument('--tick-hz', type=float, default=20)
    parser.add_argument('--lines-per-tick', type=int, default=20)
    parser.add_argument('--line-width', type=int, default=100)
    args = parser.parse_args()
    if not args.binary.is_file():
        parser.error('binary must name an existing Experimental executable')
    if any(not 72 <= width <= 260 for width in args.columns) or not 24 <= args.rows <= 100:
        parser.error('columns must be 72..260 and rows 24..100')
    if not 1 <= args.stream_seconds <= args.producer_seconds - 5 or not 6 <= args.producer_seconds <= 60:
        parser.error('producer seconds must be 6..60, with at least five seconds beyond the positive stream duration')
    if not 1 <= args.tick_hz <= 60 or not 0 <= args.lines_per_tick <= 100 or not 20 <= args.line_width <= 240:
        parser.error('rate bounds: 1..60 Hz, 0..100 lines/tick, 20..240 columns/line')
    root = Path(tempfile.mkdtemp(prefix='lowlight-terminal-output-stress-')).resolve()
    print('Artifacts:', root, flush=True)
    results = []
    for columns in args.columns:
        for mode in args.modes:
            result = run_case(args, root, columns, mode)
            results.append(result)
            print(json.dumps(result), flush=True)
            (root / 'results.json').write_text(json.dumps(results, indent=2))
    if any(result.get('error') or result.get('cleanup_live_owned_pids') or
           result.get('resources_during_stream', {}).get('errors') for result in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
