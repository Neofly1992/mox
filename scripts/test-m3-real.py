#!/usr/bin/env python3
"""Exercise the built worker through its authenticated private API with public models."""
import argparse, json, os, pathlib, subprocess, sys, time, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--provider', choices=['huggingFace', 'modelScope'], required=True)
parser.add_argument('--root', required=True)
parser.add_argument('--output', required=True)
a = parser.parse_args()
root = pathlib.Path(a.root).resolve()
root.mkdir(parents=True, exist_ok=True)
log = root / 'worker.log'
worker_output = log.open('w')
worker = subprocess.Popen([str(pathlib.Path(a.binary).resolve()), 'serve', '--data-root', str(root)],
    stdout=worker_output, stderr=subprocess.STDOUT)
started = time.monotonic()
discovery_path = root / 'run' / 'discovery.json'
try:
    while not discovery_path.exists() and time.monotonic() - started < 30:
        if worker.poll() is not None:
            raise RuntimeError(f'worker exited {worker.returncode}; log: {log}')
        time.sleep(0.1)
    discovery = json.loads(discovery_path.read_text())
    endpoint = discovery['privateEndpoint'] + '/mox/v1'
    token = discovery['token']
    def call(path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(endpoint + path, data=data,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
            method='POST' if body is not None else 'GET')
        with urllib.request.urlopen(request, timeout=45) as response:
            return json.load(response)
    library = call('/library')
    registry = next(r for r in library['configuration']['registries'] if r['provider'] == a.provider)
    operation = call('/downloads', dict(provider=a.provider, endpoint=registry['origin'],
        registryID=registry['id'], repository='mlx-community/Qwen2.5-0.5B-Instruct-4bit',
        selector='main' if a.provider == 'huggingFace' else 'master', variant=''))
    operation_id = operation['id']
    deadline = time.monotonic() + 600
    phase = None
    while time.monotonic() < deadline:
        library = call('/library')
        download = next(o for o in library['operations'] if o['id'] == operation_id)
        if phase != download['phase']:
            phase = download['phase']
            print(f"{a.provider}: {phase}, verifiedBytes={download['verifiedBytes']}", flush=True)
        if phase in ('installed', 'failed', 'cancelled'):
            break
        time.sleep(1)
    assert phase == 'installed', download
    installation = next(i for i in library['installations'] if i['manifest'] and
        i['manifest']['origin']['repository'] == 'mlx-community/Qwen2.5-0.5B-Instruct-4bit')
    binary = str(pathlib.Path(a.binary).resolve())
    chat = subprocess.run([binary, 'chat', '--data-root', str(root),
        '--model-path', installation['path'], '--prompt', 'Say hello in one sentence.',
        '--max-tokens', '24'], capture_output=True, text=True, timeout=120)
    result = dict(provider=a.provider, revision=download['manifest']['origin']['revision'],
        files=len(download['manifest']['files']), verifiedBytes=download['verifiedBytes'],
        installationPath=installation['path'], chatExit=chat.returncode,
        replyCharacters=len(chat.stdout.strip()), elapsedSeconds=round(time.monotonic()-started, 2))
    pathlib.Path(a.output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    assert chat.returncode == 0 and chat.stdout.strip(), chat.stderr[-1000:]
finally:
    worker.terminate()
    try: worker.wait(timeout=20)
    except subprocess.TimeoutExpired:
        worker.kill(); worker.wait()
    worker_output.close()
