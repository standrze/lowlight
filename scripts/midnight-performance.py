#!/usr/bin/env python3
"""Measure a local Midnight endpoint with synthetic prompts and restore its model.

Model switching is opt-in: --model LABEL=/absolute/path may be repeated, and
requires --restore-model pointing to the currently loaded model. No model files
or real conversations are changed. Run separately from UI performance tests.
"""
import argparse
import http.client
import json
from pathlib import Path
import socket
import statistics
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='http://127.0.0.1:8080')
    parser.add_argument('--model', action='append', default=[])
    parser.add_argument('--restore-model', type=Path)
    parser.add_argument('--context-bytes', type=int, nargs='+', default=[0, 8192, 32768])
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--cancel-cycles', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    url = urllib.parse.urlsplit(args.base)
    if url.scheme != 'http' or url.hostname not in {'127.0.0.1', 'localhost', '::1'}:
        parser.error('use a local HTTP endpoint')
    if args.model and not args.restore_model:
        parser.error('model switching requires --restore-model')
    if args.repeat < 1 or args.cancel_cycles < 0 or any(n < 0 for n in args.context_bytes):
        parser.error('invalid repeat, cancellation count, or context size')
    return args


args = arguments()
args.output.mkdir(parents=True, exist_ok=False)
results = []


def record(value):
    results.append(value)
    (args.output / 'results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(value), flush=True)


def api(path, payload=None, timeout=90):
    req = urllib.request.Request(args.base + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


original = api('/v1/runtime')
(args.output / 'original-runtime.json').write_text(json.dumps(original, indent=2))
if original['phase'] != 'ready' or not original.get('loadedModel'):
    raise RuntimeError('Midnight must be ready with a model before testing')
instance = original['instanceID']
if args.model and args.restore_model.name != original['loadedModel']['id']:
    raise RuntimeError('restore model does not match the currently loaded model')


def load(label, path):
    if api('/v1/runtime')['instanceID'] != instance:
        raise RuntimeError('Midnight instance changed; refusing to change its model')
    begin = time.monotonic()
    state = api('/v1/runtime/load', {'model': str(path), 'maxTokens': 4096})
    deadline = begin + 120
    while state['phase'] != 'ready':
        if state.get('lastError') or time.monotonic() > deadline:
            raise RuntimeError(state)
        time.sleep(.25)
        state = api('/v1/runtime')
    if state['loadedModel']['id'] != path.name:
        raise RuntimeError(state)
    record({'kind': 'load', 'model': label, 'seconds': round(time.monotonic() - begin, 3),
            'memory': state.get('memory')})
    return state['loadedModel']['id']


def payload(model, context_bytes):
    context = ('A reference record contains an ordinary sentence about apples and books.\n'
               * (context_bytes // 72 + 2))[:context_bytes]
    prompt = (f'Reference text:\n{context}\n\n' if context else '') + 'Reply with exactly READY.'
    value = {'model': model, 'messages': [{'role': 'user', 'content': prompt}],
             'max_tokens': 256, 'temperature': 0, 'stream': True,
             'stream_options': {'include_usage': True}}
    if 'gpt-oss' in model.lower():
        value['reasoning_effort'] = 'low'
    return value


def trial(label, model, context_bytes, iteration):
    stop = threading.Event()
    polls = []
    def monitor():
        while not stop.is_set():
            begin = time.monotonic()
            try:
                state = api('/v1/runtime', timeout=2)
                polls.append({'seconds': time.monotonic() - begin, 'phase': state['phase']})
            except Exception as error:
                polls.append({'seconds': time.monotonic() - begin, 'error': str(error)})
            stop.wait(.5)
    worker = threading.Thread(target=monitor, daemon=True)
    worker.start()
    begin = time.monotonic()
    first = None
    answer = ''
    usage = None
    finish = None
    error = None
    done = False
    try:
        req = urllib.request.Request(args.base + '/v1/chat/completions',
            data=json.dumps(payload(model, context_bytes)).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=90) as response:
            for line in response:
                if not line.startswith(b'data:'):
                    continue
                event = line[5:].strip()
                if event == b'[DONE]':
                    done = True
                    break
                event = json.loads(event)
                if event.get('error'):
                    error = event['error']
                if event.get('usage'):
                    usage = event['usage']
                for choice in event.get('choices', []):
                    content = choice.get('delta', {}).get('content') or ''
                    if content and first is None:
                        first = time.monotonic() - begin
                    answer += content
                    finish = choice.get('finish_reason') or finish
    except Exception as failure:
        error = str(failure)
    elapsed = time.monotonic() - begin
    stop.set()
    worker.join(3)
    latencies = [p['seconds'] for p in polls]
    record({'kind': 'generation', 'model': label, 'context_bytes': context_bytes,
            'iteration': iteration, 'effort': 'low' if 'gpt-oss' in model.lower() else 'default',
            'seconds': round(elapsed, 3), 'first_text_s': None if first is None else round(first, 3),
            'answer': answer, 'usage': usage, 'finish': finish, 'done': done, 'error': error,
            'runtime_poll_count': len(polls),
            'runtime_poll_error_count': sum('error' in p for p in polls),
            'runtime_poll_max_s': round(max(latencies, default=0), 3),
            'runtime_poll_median_s': round(statistics.median(latencies), 3) if latencies else None,
            'memory_after': api('/v1/runtime').get('memory')})


def cancellation(model, iteration):
    url = urllib.parse.urlsplit(args.base)
    connection = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=90)
    value = payload(model, 0)
    value.pop('reasoning_effort', None)
    value['max_tokens'] = 4096
    value['messages'][0]['content'] = 'Write a complete Python library management application with documentation and tests.'
    response = None
    try:
        connection.request('POST', '/v1/chat/completions', body=json.dumps(value),
                           headers={'Content-Type': 'application/json'})
        transport = connection.sock
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f'cancel fixture rejected: {response.status}')
        response.readline()
        time.sleep(1)
        begin = time.monotonic()
        try:
            transport.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        response.close()
        connection.close()
        probe = payload(model, 0)
        probe['stream'] = False
        probe.pop('stream_options', None)
        busy = 0
        accepted = None
        reply = None
        deadline = begin + 10
        while time.monotonic() < deadline:
            attempted = time.monotonic()
            try:
                reply = api('/v1/chat/completions', probe, timeout=30)
                accepted = attempted - begin
                break
            except urllib.error.HTTPError as failure:
                body = failure.read().decode()
                if failure.code != 409 or 'model_busy' not in body:
                    raise RuntimeError(body) from failure
                busy += 1
                time.sleep(.1)
        record({'kind': 'cancellation', 'iteration': iteration, 'model': model,
                'accepted_after_s': None if accepted is None else round(accepted, 3),
                'completed_after_s': round(time.monotonic() - begin, 3), 'busy_probes': busy,
                'answer': reply['choices'][0]['message']['content'] if reply else None,
                'memory_after': api('/v1/runtime').get('memory')})
        if accepted is None:
            raise RuntimeError('Cancellation did not recover within ten seconds')
    finally:
        if response is not None:
            response.close()
        connection.close()


try:
    models = [(entry.split('=', 1)[0], Path(entry.split('=', 1)[1])) for entry in args.model]
    if not models:
        models = [(original['loadedModel']['id'], None)]
    for label, path in models:
        model = load(label, path) if path else original['loadedModel']['id']
        for context_bytes in args.context_bytes:
            for iteration in range(1, args.repeat + 1):
                trial(label, model, context_bytes, iteration)
        if 'gpt-oss' in model.lower():
            for iteration in range(1, args.cancel_cycles + 1):
                cancellation(model, iteration)
finally:
    if args.model:
        load('restored-original', args.restore_model)
    (args.output / 'final-runtime.json').write_text(json.dumps(api('/v1/runtime'), indent=2))

if any(r.get('error') or (r['kind'] == 'generation' and (not r['done'] or not r['answer'].strip())) for r in results):
    raise SystemExit(1)
