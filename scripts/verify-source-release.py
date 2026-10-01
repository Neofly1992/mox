#!/usr/bin/env python3
"""Final artifact verification; creates only a new repository .build test root.

Runs real HF/MS downloads, pause/restart/resume, CLI configuration/identity,
active deletion protection and the separately installed official SDK probe.
No management token or API key is written to output.
"""
import argparse
import concurrent.futures
import json
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--data-root', type=Path, required=True)
parser.add_argument('--sdk-python', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
root = args.data_root.resolve()
if root.parent != (repo / '.build').resolve() or root.exists():
    parser.error('Use a NEW direct child of this repository .build; existing roots are never modified.')
# Keep the virtualenv executable path: resolving its symlink selects the system Python.
subprocess.run([str(args.sdk_python.absolute()), '-c', 'import openai, anthropic'], check=True)
root.mkdir()
worker = args.app.resolve() / 'Contents/Helpers/MoxWorker.app/Contents/MacOS/mox'
evidence = {'buildID': subprocess.check_output([str(worker), '--version'], text=True).split()[0],
            'dataRoot': str(root), 'checks': []}
process = None
discovery = None
log = args.evidence.with_suffix('.worker.log').open('w')

def mark(name, **values):
    evidence['checks'].append({'name': name, **values})
    args.evidence.write_text(json.dumps(evidence, indent=2))
    print(name, json.dumps(values), flush=True)

def start():
    global process, discovery
    process = subprocess.Popen([str(worker), 'serve', '--data-root', str(root)], stdout=log, stderr=log)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('Owned worker exited during startup; inspect worker log.')
        path = root / 'run/discovery.json'
        if path.exists():
            discovery = json.loads(path.read_text())
            return
        time.sleep(.1)
    raise TimeoutError('Owned worker readiness deadline exceeded.')

def stop():
    global process
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=40)
    process = None

def request(path, value=None, method=None, expected=200, timeout=900):
    req = urllib.request.Request(discovery['privateEndpoint'] + '/mox/v1' + path,
        data=json.dumps(value).encode() if value is not None else None,
        method=method or ('POST' if value is not None else 'GET'),
        headers={'Authorization': 'Bearer ' + discovery['token'], 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status, data = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    assert status == expected, f'{path}: HTTP {status}, expected {expected}'
    return json.loads(data)

def wait_download(identifier):
    deadline = time.monotonic() + 1800
    last = None
    while time.monotonic() < deadline:
        item = request('/downloads/' + identifier)
        if item['phase'] != last:
            mark('download.phase', id=identifier, phase=item['phase'], verifiedBytes=item['verifiedBytes'])
            last = item['phase']
        if item['phase'] == 'installed':
            return item
        assert item['phase'] not in ('failed', 'cancelled', 'interrupted'), item.get('errorCode')
        time.sleep(.5)
    raise TimeoutError('Download deadline exceeded; test root preserved.')

def command(*parts):
    result = subprocess.run([str(worker), *parts, '--data-root', str(root)], capture_output=True, text=True, timeout=900)
    assert result.returncode == 0, f'CLI {parts[0]} failed: {result.stderr[-1000:]}'
    return result

def rejected_bodies():
    address = urlsplit(discovery['privateEndpoint'])
    for path, header, body, expected in [
        ('/models/import', 'Transfer-Encoding: chunked', b'4001\r\n' + b'x' * 16385 + b'\r\n', 413),
        ('/downloads', 'Content-Length: 16385', b'', 413),
        ('/models/00000000-0000-0000-0000-000000000001/sampling', 'Transfer-Encoding: chunked', b'', 404)]:
        with socket.create_connection((address.hostname, address.port), timeout=3) as peer:
            peer.settimeout(3)
            peer.sendall((f'POST /mox/v1{path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' + discovery['token'] + '\r\n' + header + '\r\n\r\n').encode() + body)
            response = b''
            while True:
                part = peer.recv(65536)
                if not part:
                    break
                response += part
            assert f' {expected} '.encode() in response.split(b'\r\n')[0]
            assert b'connection: close' in response.lower()
    mark('release.unread-body-close', cases=3)

try:
    start()
    assert discovery['identity']['buildID'] == evidence['buildID']
    rejected_bodies()
    configuration = request('/library')['configuration']
    hf = {'registryID': configuration['defaultRegistryID'], 'provider': 'huggingFace',
          'endpoint': 'https://huggingface.co', 'repository': 'mlx-community/Qwen3-0.6B-4bit',
          'selector': '73e3e38d981303bc594367cd910ea6eb48349da8', 'variant': ''}
    plan = request('/downloads/plan', hf)
    mark('hf.plan', plan=plan)
    operation = request('/downloads', hf, expected=202)['id']
    request('/downloads/' + operation + '/pause', method='POST')
    assert request('/downloads/' + operation)['phase'] == 'paused'
    stop(); start()
    assert request('/downloads/' + operation)['phase'] == 'paused'
    def resume():
        try:
            request('/downloads/' + operation + '/resume', method='POST')
            return 'accepted'
        except AssertionError as error:
            assert 'HTTP 409' in str(error)
            return 'busy'
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = sorted(pool.map(lambda _: resume(), range(2)))
    assert outcomes == ['accepted', 'busy']
    configuration = request('/library')['configuration']
    request('/config/sampling', {'expectedRevision': configuration['revision'],
        'settings': {'temperature': 0, 'maxTokens': 14}})
    mark('hf.pause-restart-concurrent-resume', outcomes=outcomes)
    wait_download(operation)
    library = request('/library')
    item = next(value for value in library['installations'] if value['origin']['repository'] == hf['repository'])
    request('/models/' + item['id'] + '/sampling', {'expectedRevision': library['configuration']['revision'],
        'settings': {'maxTokens': 12}})
    configuration = request('/library')['configuration']
    request('/models/' + item['id'] + '/pin', {'expectedRevision': configuration['revision'], 'pinned': True})
    effective = request('/config/effective', {'model': {'kind': 'installedAlias', 'path': item['alias']}, 'explicit': {'topP': .7}})
    assert effective['maxTokens'] == 12 and effective['maxTokensSource'] == 'model'
    assert effective['temperature'] == 0 and effective['temperatureSource'] == 'global'
    assert effective['topPSource'] == 'request'
    for identifier in [item['alias'], item['id']]:
        reply = command('chat', '--model', identifier, '--prompt', 'Say hello briefly.', '--top-p', '.7')
        assert reply.stdout.strip() and 'max_tokens=12 [model]' in reply.stderr
    mark('cli.alias-uuid-and-provenance', effective=effective)
    request_id = str(uuid.uuid4())
    body = {'requestID': request_id, 'model': {'kind': 'installedAlias', 'path': item['alias']},
            'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': 'Write a very long story about a city.'}]}],
            'sampling': {'maxTokens': 512}}
    req = urllib.request.Request(discovery['privateEndpoint'] + '/mox/v1/generations', data=json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + discovery['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as stream:
        request('/models/' + item['id'], method='DELETE', expected=409)
        request('/generations/' + request_id + '/cancel', method='POST', expected=202)
    deadline = time.monotonic() + 30
    while request('/state')['activeLeases'] and time.monotonic() < deadline:
        time.sleep(.1)
    assert request('/state')['activeLeases'] == 0
    mark('real.active-delete-rejected-and-cancel-recovered')
    events = request('/diagnostics')
    assert any(event['stage'] == 'model.action' and event['code'] == 'busy' for event in events)
    assert 'Bearer' not in json.dumps(events) and discovery['token'] not in json.dumps(events)
    mark('busy.failure-in-redacted-diagnostics')
    command('api', 'enable')
    sdk = subprocess.run([str(args.sdk_python.absolute()), str(repo / 'scripts/verify-m4-sdk.py'),
        '--app', str(args.app.resolve()), '--data-root', str(root), '--model', item['id']],
        stdout=args.evidence.with_suffix('.sdk.log').open('w'), stderr=subprocess.STDOUT, timeout=900)
    assert sdk.returncode == 0, 'Official SDK probe failed; inspect SDK log.'
    mark('official.openai-anthropic-text-stream-tools-errors')
    ms_registry = next(value for value in request('/library')['configuration']['registries'] if value['provider'] == 'modelScope')
    ms = {'registryID': ms_registry['id'], 'provider': 'modelScope', 'endpoint': 'https://modelscope.cn',
          'repository': 'mlx-community/Qwen2.5-0.5B-Instruct-4bit',
          'selector': '7b36975ed2397d6eb8fb55cb5a58437bd7ca5b10', 'variant': ''}
    mark('ms.plan', plan=request('/downloads/plan', ms))
    ms_operation = request('/downloads', ms, expected=202)['id']
    wait_download(ms_operation)
    ms_item = next(value for value in request('/library')['installations'] if value['origin']['registryID'] == ms_registry['id'])
    reply = command('chat', '--model', ms_item['id'], '--prompt', 'Say hello briefly.', '--max-tokens', '12')
    assert reply.stdout.strip()
    mark('ms.installed-real-chat', revision=ms_item['origin']['revision'])
    command('api', 'disable')
    stop(); start()
    restored = request('/models/' + item['id'])
    assert restored['pinned'] and restored['samplingSettings']['maxTokens'] == 12
    assert request('/state')['activeDownloads'] == 0
    mark('restart.settings-and-library-restored', installations=request('/library')['totalInstallations'])
    events = request('/diagnostics')
    assert 'Bearer' not in json.dumps(events)
    evidence['result'] = 'PASS'
finally:
    stop()
    log.close()
    args.evidence.write_text(json.dumps(evidence, indent=2))
