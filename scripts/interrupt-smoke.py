#!/usr/bin/env python3
"""Verify terminal cancellation and warning deduplication with a local fixture."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

root = Path(tempfile.mkdtemp(prefix='lowlight-interrupt-'))
(root / 'settings.json').write_text('{}')
release = threading.Event()
started = threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"test","context_window":4096,"supported_reasoning_efforts":["low"]}]}')
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        started.set()
        try:
            if request['messages'][-1]['content'] == 'wait':
                release.wait(15)
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(b'data: {"choices":[{"index":0,"delta":{"content":"Partial reply"}}]}\n\n')
            self.wfile.flush()
            release.wait(15)
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
processes = []
outputs = {}
def launch(name, context=4096):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 130, 0, 0))
    sessions = root / name
    proc = subprocess.Popen([str(Path(sys.argv[1]).resolve()), '--endpoint',
        f'http://127.0.0.1:{server.server_port}/v1', '--model', 'test',
        '--context-window', str(context), '--sessions-directory', str(sessions),
        '--config', str(root / 'settings.json')], stdin=slave, stdout=slave, stderr=slave,
        env=dict(os.environ, TERM='xterm-256color'), start_new_session=True)
    os.close(slave)
    processes.append((proc, master))
    outputs[master] = root / (name + ".terminal.log")
    read(master, 1.5)
    return proc, master, sessions

def read(master, duration=.3):
    end = time.monotonic() + duration
    while time.monotonic() < end:
        if select.select([master], [], [], max(0, end-time.monotonic()))[0]:
            try: data = os.read(master, 65536)
            except OSError: break
            if not data: break
            with outputs[master].open("ab") as log: log.write(data)

def send(master, data, duration=.3):
    os.write(master, data)
    read(master, duration)

def record(sessions):
    files = list(sessions.glob('*.json'))
    return json.loads(max(files, key=lambda p:p.stat().st_mtime).read_text()) if files else None

try:
    for prompt in ('wait', 'stream'):
        started.clear()
        proc, master, sessions = launch(prompt)
        send(master, prompt.encode()+b'\r', .5)
        assert started.wait(2), 'generation did not start'
        start = time.monotonic()
        send(master, b'\x03', .1)
        while time.monotonic()-start < 3:
            saved = record(sessions)
            if saved and any(m['state']=='stopped' for m in saved['transcript']['messages']): break
            read(master, .05)
        else: raise AssertionError(f'{prompt}: Ctrl-C did not stop generation within 3 seconds')
        assert proc.poll() is None, 'interrupt exited the app'
        if prompt == 'stream':
            assert any(m['text']=='Partial reply' for m in saved['transcript']['messages']), 'partial answer lost'
        # Cancellation must not arm the exit prompt. The next Ctrl-C only arms it.
        send(master, b'\x03')
        assert proc.poll() is None, 'generation interrupt armed exit confirmation'
        send(master, b'\x1b')
        send(master, b'\x04')
        assert proc.wait(timeout=5)==0
        print(f'PASS {prompt}: stopped, preserved chat, and exited cleanly', flush=True)
    proc, master, sessions = launch('warnings', 8192)
    send(master, b'/effort high', .3)
    send(master, b'\r', .6)
    send(master, b'hello', .6)
    for _ in range(3): send(master, b'\r', .3)
    # Let draft autosave persist the final warning state before inspecting it.
    send(master, b' ', .1)
    send(master, b'\x7f', .7)
    send(master, b'\x04')
    assert proc.wait(timeout=5)==0
    saved = record(sessions)
    warnings = [m for m in saved['transcript']['messages'] if "does not advertise 'high' effort" in m['text']]
    assert len(warnings)==1, f'expected one warning, got {len(warnings)}'
    assert saved['draft']=='hello', 'blocked send lost the draft'
    print('PASS repeated blocked sends retain one warning and preserve draft', flush=True)
finally:
    release.set()
    for proc, master in processes:
        if proc.poll() is None: proc.kill(); proc.wait()
        os.close(master)
    server.shutdown()
    print('Artifacts:', root, flush=True)
