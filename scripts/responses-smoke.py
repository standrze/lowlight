#!/usr/bin/env python3
"""Run the Lowlight TUI against an existing loopback Midnight Responses server.

Example: python3 scripts/responses-smoke.py --binary .build/release/lowlight \
    --endpoint http://127.0.0.1:18845/v1 --model smoke
Uses isolated config/workspace/sessions. Deletes only responses created by this
smoke run to exercise expiry recovery. Requires no Python dependencies.
"""
import argparse
import fcntl
import http.client
import http.server
import json
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
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='.build/release/lowlight')
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    upstream = urllib.parse.urlsplit(args.endpoint)
    if upstream.scheme != 'http' or upstream.hostname not in ('127.0.0.1', 'localhost') or upstream.query or upstream.fragment or upstream.username:
        parser.error('Use an unauthenticated HTTP loopback test endpoint.')
    root = Path(tempfile.mkdtemp(prefix='lowlight-responses-smoke-'))
    sessions = root / 'sessions'
    sessions.mkdir()
    (root / 'config.json').write_text('{}\n')
    records, output, created_ids, processes = [], bytearray(), [], []
    lock = threading.Lock()

    class Proxy(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def relay(self):
            connection = http.client.HTTPConnection(upstream.hostname, upstream.port or 80, timeout=120)
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            record = {'path': self.path, 'method': self.command}
            if body:
                record['body'] = json.loads(body)
            try:
                connection.request(self.command, self.path, body=body,
                                   headers={'Content-Type': 'application/json', 'Accept': self.headers.get('Accept', '*/*')})
                response = connection.getresponse()
                record['status'] = response.status
                with lock:
                    records.append(record)
                self.send_response(response.status)
                self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
                self.end_headers()
                captured = bytearray()
                while chunk := response.read1(65536):
                    captured.extend(chunk)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                for line in captured.decode('utf-8').splitlines():
                    if line.startswith('data: '):
                        event = json.loads(line[6:])
                        if event.get('type') == 'response.completed':
                            with lock:
                                created_ids.append(event['response']['id'])
            finally:
                connection.close()

        do_GET = relay
        do_POST = relay

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f'http://127.0.0.1:{server.server_port}{upstream.path.rstrip("/")}'

    def read(master, seconds=.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([master], [], [], max(0, end - time.monotonic()))[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                output.extend(chunk)

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        print('PASS', message, flush=True)

    def wait(master, predicate, message, timeout=90):
        end = time.monotonic() + timeout
        while not predicate() and time.monotonic() < end:
            read(master)
        check(predicate(), message)

    def latest():
        files = list(sessions.glob('*.json'))
        return max((json.loads(p.read_text()) for p in files), key=lambda item: item['updatedAt']) if files else {}

    def completed():
        return [m for m in latest().get('transcript', {}).get('messages', [])
                if m['role'] == 'assistant' and m['state'] == 'complete']

    def posts():
        with lock:
            return [r.copy() for r in records if r['method'] == 'POST']

    def launch(resume=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 130, 0, 0))
        command = [str(Path(args.binary).resolve()), '--config', str(root / 'config.json'),
                   '--endpoint', endpoint, '--model', args.model, '--max-tokens', '128',
                   '--api-key-env', 'LOWLIGHT_SMOKE_UNUSED_KEY', '--workspace', str(root),
                   '--sessions-directory', str(sessions)]
        if resume:
            command.extend(['--resume', resume])
        env = dict(os.environ, TERM='xterm-256color')
        env.pop('LOWLIGHT_SMOKE_UNUSED_KEY', None)
        before = len(records)
        proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, cwd=root,
                                env=env, start_new_session=True)
        os.close(slave)
        processes.append((proc, master))
        wait(master, lambda: len(records) > before, 'TUI discovers the model', timeout=15)
        read(master, .8)
        check(proc.poll() is None, 'TUI remains running')
        return proc, master

    def prompt(master, value, count):
        os.write(master, (value + '\r').encode())
        wait(master, lambda: len(completed()) == count, 'TUI saves completed answer ' + str(count))
        check(bool(completed()[-1]['text'].strip()), 'Answer contains text')
        read(master, .2)

    def stop(proc, master):
        for _ in range(2):
            if proc.poll() is None:
                os.write(master, b'\x03')
                read(master, .5)
        wait(master, lambda: proc.poll() is not None, 'TUI exits cleanly', timeout=10)
        check(proc.returncode == 0, 'TUI exit status is zero')

    try:
        proc, master = launch()
        prompt(master, 'Remember the word sapphire. Reply with exactly sapphire.', 1)
        prompt(master, 'What word did I ask you to remember? Reply with just the word.', 2)
        requests = posts()
        check(len(requests) == 2 and all(r['path'].endswith('/responses') for r in requests), 'Auto uses Responses')
        check(requests[1]['body'].get('previous_response_id') is not None, 'Second turn uses previous_response_id')
        check(len(requests[1]['body']['input']) == 1, 'Continuation sends only the new prompt')
        check('sapphire' in completed()[1]['text'].lower(), 'Real model remembers previous input')
        wait(master, lambda: len(created_ids) >= 2, 'Server response IDs captured')
        expired = created_ids[-1]
        connection = http.client.HTTPConnection(upstream.hostname, upstream.port or 80, timeout=10)
        connection.request('DELETE', upstream.path.rstrip('/') + '/responses/' + expired)
        check(connection.getresponse().status == 200, 'Remove this run\'s response to simulate expiry')
        connection.close()
        prompt(master, 'Repeat the remembered word again.', 3)
        requests = posts()
        check([r['status'] for r in requests[2:]] == [404, 200], 'Expired ID triggers one successful retry')
        check(requests[2]['body'].get('previous_response_id') == expired, 'Retry follows the expired response')
        check('previous_response_id' not in requests[3]['body'] and len(requests[3]['body']['input']) == len(requests[0]['body']['input']) + 4,
              'Recovery sends complete local history')
        saved = latest()
        check(saved.get('api') == 'auto' and 'previous_response_id' not in json.dumps(saved), 'Saved chat is portable')
        conversation_id = saved['id']
        stop(proc, master)
        proc, master = launch(resume=conversation_id)
        prompt(master, 'What is the remembered word?', 4)
        request = posts()[-1]['body']
        check('previous_response_id' not in request and len(request['input']) == len(requests[0]['body']['input']) + 6, 'Resumed chat sends full local history')
        check('sapphire' in completed()[3]['text'].lower(), 'Resumed chat retains conversation meaning')
        stop(proc, master)
        print('All real Midnight Responses TUI checks passed.', flush=True)
    finally:
        for proc, master in processes:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            os.close(master)
        server.shutdown()
        (root / 'terminal.txt').write_bytes(output)
        (root / 'requests.json').write_text(json.dumps(records, indent=2))
        # Clean up only response objects observed during this run.
        for response_id in set(created_ids):
            connection = http.client.HTTPConnection(upstream.hostname, upstream.port or 80, timeout=5)
            try:
                connection.request('DELETE', upstream.path.rstrip('/') + '/responses/' + response_id)
                connection.getresponse().read()
            except OSError:
                pass
            finally:
                connection.close()
        print('Artifacts:', root, flush=True)


if __name__ == '__main__':
    main()
