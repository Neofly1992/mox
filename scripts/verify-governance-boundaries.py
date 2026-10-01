#!/usr/bin/env python3
"""G1-G3 final artifact probe. Only repository .build test roots are accepted.

Clones previously verified test artifacts into a NEW root, recovers their index,
tests UUID aliases and real inference, then stops its own parent-controlled worker.
Does not read the default user root or emit credentials. Tests retain their files.
"""
import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--source-root', type=Path, required=True)
parser.add_argument('--data-root', type=Path, required=True)
parser.add_argument('--sdk-python', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--check-prior-store', action='store_true', help='Also reopen the prior isolated test database and assert its saved pin/settings.')
args = parser.parse_args()
build = (Path(__file__).resolve().parent.parent / '.build').resolve()
root, source = args.data_root.resolve(), args.source_root.resolve()
if root.parent != build or source.parent != build or root.exists():
    parser.error('Source and NEW destination must be direct repository .build children.')
subprocess.run([str(args.sdk_python.absolute()), '-c', 'import openai, anthropic'], check=True)
root.mkdir()
(root / 'models').mkdir()
subprocess.run(['cp', '-cR', str(source / 'models/artifacts'), str(root / 'models/artifacts')], check=True)
worker = args.app.absolute() / 'Contents/Helpers/MoxWorker.app/Contents/MacOS/mox'
evidence = {'buildID': subprocess.check_output([str(worker), '--version'], text=True).split()[0], 'checks': []}
log = args.evidence.with_suffix('.worker.log').open('w')
process = None

def mark(name, **values):
    evidence['checks'].append({'name': name, **values})
    args.evidence.write_text(json.dumps(evidence, indent=2))
    print(name, json.dumps(values), flush=True)

def start():
    global process, discovery
    before = time.monotonic()
    process = subprocess.Popen([str(worker), 'serve', '--data-root', str(root), '--ownership', 'appOwned', '--parent-control'], stdin=subprocess.PIPE, stdout=log, stderr=log)
    deadline = before + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('Owned worker exited before readiness; inspect worker log.')
        path = root / 'run/discovery.json'
        if path.exists():
            discovery = json.loads(path.read_text())
            assert discovery['identity']['buildID'] == evidence['buildID']
            request('/identity')
            mark('health.ready', seconds=time.monotonic() - before)
            return
        time.sleep(.02)
    raise TimeoutError('Service health not published within original readiness bound.')

def stop():
    global process
    if process is not None and process.poll() is None:
        before = time.monotonic()
        process.stdin.close()
        process.wait(timeout=30)
        assert process.returncode == 0
        mark('owned.parent-eof-stopped', seconds=time.monotonic() - before)
    process = None

def request(path, value=None, method=None, expected=200):
    req = urllib.request.Request(discovery['privateEndpoint'] + '/mox/v1' + path,
        data=json.dumps(value).encode() if value is not None else None,
        method=method or ('POST' if value is not None else 'GET'),
        headers={'Authorization': 'Bearer ' + discovery['token'], 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            status, data = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    assert status == expected, f'{path}: HTTP {status}, expected {expected}'
    return json.loads(data)

def command(*parts):
    result = subprocess.run([str(worker), *parts, '--data-root', str(root)], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, f'CLI {parts[0]} failed: {result.stderr[-1000:]}'
    return result.stdout

try:
    start()
    deadline = time.monotonic() + 120
    phases = set()
    while True:
        state = request('/state')
        phases.add(state['libraryRecovery']['phase'])
        assert state['serviceState'] == 'running'
        if state['libraryRecovery']['phase'] == 'ready':
            break
        assert state['libraryRecovery']['phase'] != 'failed', state['libraryRecovery']
        if time.monotonic() > deadline:
            raise TimeoutError('Recovery did not finish; test root retained.')
        time.sleep(.02)
    library = request('/library')
    assert library['totalInstallations'] == 2
    assert all(item['availability'] == 'ready' for item in library['installations'])
    mark('committed.unindexed-dual-source-recovered', phases=sorted(phases), inspected=state['libraryRecovery']['inspected'])
    qwen = next(item for item in library['installations'] if item['origin']['repository'] == 'mlx-community/Qwen3-0.6B-4bit')
    for name in ['uuid-reference', 'conflict-reference']:
        subprocess.run(['cp', '-cR', qwen['path'], str(root / name)], check=True)
    alias = 'abcdefab-cdef-abcd-efab-cdefabcdefab'
    imported = request('/models/import', {'path': str(root / 'uuid-reference'), 'alias': alias})
    for identifier in [alias, alias.upper(), imported['id']]:
        request('/config/effective', {'model': {'kind': 'installedAlias', 'path': identifier}, 'explicit': {}})
        assert command('chat', '--model', identifier, '--prompt', 'Say hello briefly.', '--max-tokens', '12').strip()
    request('/models/import', {'path': str(root / 'conflict-reference'), 'alias': imported['id']}, expected=409)
    mark('uuid.alias-case-id-cli-inference-and-conflict')
    configuration = request('/library')['configuration']
    request('/models/' + qwen['id'] + '/sampling', {'expectedRevision': configuration['revision'], 'settings': {'maxTokens': 12}})
    configuration = request('/library')['configuration']
    request('/models/' + qwen['id'] + '/pin', {'expectedRevision': configuration['revision'], 'pinned': True})
    command('api', 'enable')
    sdk = subprocess.run([str(args.sdk_python.absolute()), str(Path(__file__).with_name('verify-m4-sdk.py')), '--app', str(args.app.absolute()), '--data-root', str(root), '--model', qwen['id']], stdout=args.evidence.with_suffix('.sdk.log').open('w'), stderr=subprocess.STDOUT, timeout=900)
    assert sdk.returncode == 0, 'SDK regression failed; inspect SDK log.'
    command('api', 'disable')
    mark('official-sdk-verification-and-protocol-regression')
    stop(); start()
    assert request('/models/' + qwen['id'])['pinned']
    assert request('/models/' + qwen['id'])['samplingSettings']['maxTokens'] == 12
    assert command('chat', '--model', qwen['id'], '--prompt', 'Say hello.', '--max-tokens', '12').strip()
    mark('restart.settings-and-managed-on-demand-inference')
    if args.check_prior_store:
        stop()
        root = source
        start()
        deadline = time.monotonic() + 120
        while request('/state')['libraryRecovery']['phase'] == 'recovering':
            if time.monotonic() > deadline:
                raise TimeoutError('Prior test store verification deadline exceeded.')
            time.sleep(.02)
        prior = request('/library')
        assert prior['totalInstallations'] == 2
        prior_qwen = next(item for item in prior['installations'] if item['origin']['repository'] == 'mlx-community/Qwen3-0.6B-4bit')
        assert prior_qwen['pinned'] and prior_qwen['samplingSettings']['maxTokens'] == 12
        assert all(item['availability'] == 'ready' for item in prior['installations'])
        mark('prior-isolated-store-retains-installations-settings-pin')
    evidence['result'] = 'PASS' 
finally:
    stop()
    log.close()
    args.evidence.write_text(json.dumps(evidence, indent=2))
