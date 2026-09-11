#!/usr/bin/env python3
"""Check a silent reasoning interval, reasoning display controls, and saved context.

Usage: python3 scripts/reasoning-smoke.py /path/to/lowlight [silent-seconds]
Default 65 seconds reproduces the former URLSession idle timeout.
Uses a mock loopback server and temporary sessions, never a real model.
"""
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

root = Path(tempfile.mkdtemp(prefix='lowlight-reasoning-'))
(root / 'settings.json').write_text('{}')
quiet = float(sys.argv[2]) if len(sys.argv) > 2 else 65
stop = threading.Event()
started = threading.Event()
requests = []

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"test","context_window":8192}]}')
    def do_POST(self):
        requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        def event(delta, finish=None):
            data = {'choices':[{'index':0, 'delta':delta, 'finish_reason':finish}]}
            self.wfile.write(('data: '+json.dumps(data)+'\r\n\r\n').encode())
            self.wfile.flush()
        try:
            event({'role':'assistant'})
            started.set()
            if stop.wait(quiet): return
            event({'reasoning_content':'Checking the request.'})
            if stop.wait(.5): return
            event({'content':'Here is the answer.'}, 'stop')
            self.wfile.write(b'data: [DONE]\r\n\r\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',40,180,0,0))
sessions = root/'sessions'
proc = subprocess.Popen([str(Path(sys.argv[1]).resolve()), '--api', 'chat-completions', '--endpoint',
    f'http://127.0.0.1:{server.server_port}/v1', '--config',str(root/'settings.json'),
    '--sessions-directory',str(sessions)],stdin=slave,stdout=slave,stderr=slave,
    env=dict(os.environ,TERM='xterm-256color'), start_new_session=True)
os.close(slave)
output = bytearray()
def read(seconds=.2):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if select.select([master],[],[],max(0,end-time.monotonic()))[0]:
            try: data=os.read(master,65536)
            except OSError: break
            if not data: break
            output.extend(data)
def send(text):
    os.write(master,text.encode()); read(.5)
def latest():
    files=list(sessions.glob('*.json'))
    return json.loads(max(files,key=lambda p:p.stat().st_mtime).read_text()) if files else None
try:
    read(1.5)
    send('/thinking off\r')
    send('/thinking on\r')
    send('hello\r')
    assert started.wait(3), 'request did not start'
    end=time.monotonic()+quiet+15
    saved=None
    answers=[]
    while time.monotonic()<end:
        read(.2)
        saved=latest()
        if saved:
            answers=[m for m in saved['transcript']['messages'] if m['role']=='assistant']
            if answers and answers[-1]['state']!='streaming': break
    assert answers and answers[-1]['state']=='complete', answers
    assert answers[-1]['text']=='Here is the answer.'
    assert answers[-1]['reasoning']=='Checking the request.'
    assert saved['context']['turns'][-1]['responses'][0]['content']=='Here is the answer.'
    notices=[m['text'] for m in saved['transcript']['messages'] if m['role']=='notice']
    assert any('Thinking display: off.' in text for text in notices), notices
    assert any('Thinking display: on.' in text for text in notices), notices
    assert b'\x1b[3m' in output or any(b'3' in part.split(b'm',1)[0].split(b';') for part in output.split(b'\x1b[')[1:] if b'm' in part), 'italic styling absent'
    send('\x14')
    send('\x14')
    send('/exit\r')
    assert proc.wait(timeout=5)==0
    print(f'PASS {quiet}s silent interval, CRLF stream, thinking controls, italic display, and answer-only context',flush=True)
finally:
    stop.set()
    if proc.poll() is None: proc.kill(); proc.wait()
    os.close(master)
    (root/'terminal.log').write_bytes(output)
    server.shutdown()
    print('Artifacts:',root,flush=True)
