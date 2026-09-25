#!/usr/bin/env python3
"""Real HF download: pause, stop the service, reopen, and resume the fixed snapshot."""
import argparse
import json
import pathlib
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--root', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
root = pathlib.Path(args.root).resolve()
root.mkdir(parents=True, exist_ok=True)
binary = str(pathlib.Path(args.binary).resolve())


def start():
    log = (root / 'recovery-worker.log').open('a')
    process = subprocess.Popen([binary, 'serve', '--data-root', str(root)],
                               stdout=log, stderr=subprocess.STDOUT)
    discovery = root / 'run' / 'discovery.json'
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'worker exited {process.returncode}')
        if discovery.exists():
            data = json.loads(discovery.read_text())
            if data['identity']['pid'] == process.pid:
                return process, log, data
        time.sleep(.1)
    raise TimeoutError('service discovery did not appear')


def stop(process, log):
    process.terminate()
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()


def call(discovery, path, body=None, post=False):
    data = json.dumps(body).encode() if body is not None else (b'' if post else None)
    request = urllib.request.Request(
        discovery['privateEndpoint'] + '/mox/v1' + path, data=data,
        headers={'Authorization': 'Bearer ' + discovery['token'],
                 'Content-Type': 'application/json'},
        method='POST' if post or body is not None else 'GET')
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


process, log, discovery = start()
try:
    library = call(discovery, '/library')
    registry = next(value for value in library['configuration']['registries']
                    if value['provider'] == 'huggingFace')
    created = call(discovery, '/downloads', dict(
        provider='huggingFace', endpoint=registry['origin'], registryID=registry['id'],
        repository='mlx-community/Qwen2.5-0.5B-Instruct-4bit', selector='main', variant=''))
    operation_id = created['id']
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        operation = next(value for value in call(discovery, '/library')['operations']
                         if value['id'] == operation_id)
        if operation['phase'] == 'downloading' and operation['verifiedBytes'] > 0:
            break
        if operation['phase'] in ('failed', 'installed'):
            raise AssertionError(f'could not pause a partial download: {operation["phase"]}')
        time.sleep(.2)
    else:
        raise TimeoutError('no file completed before pause')
    paused = call(discovery, f'/downloads/{operation_id}/pause', post=True)
    paused_operation = next(value for value in paused['operations'] if value['id'] == operation_id)
    assert paused_operation['phase'] == 'paused', paused_operation
    verified_before_restart = paused_operation['verifiedBytes']
finally:
    stop(process, log)

process, log, discovery = start()
try:
    operation = next(value for value in call(discovery, '/library')['operations']
                     if value['id'] == operation_id)
    assert operation['phase'] == 'paused', operation
    assert operation['verifiedBytes'] == verified_before_restart, operation
    call(discovery, f'/downloads/{operation_id}/resume', post=True)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        library = call(discovery, '/library')
        operation = next(value for value in library['operations'] if value['id'] == operation_id)
        if operation['phase'] in ('installed', 'failed'):
            break
        time.sleep(1)
    assert operation['phase'] == 'installed', operation
    result = dict(operationID=operation_id, revision=operation['manifest']['origin']['revision'],
                  verifiedBeforeRestart=verified_before_restart,
                  verifiedAfterResume=operation['verifiedBytes'],
                  installations=len(library['installations']))
    pathlib.Path(args.output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
finally:
    stop(process, log)
