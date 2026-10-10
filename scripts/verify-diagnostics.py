#!/usr/bin/env python3
"""Real worker/doctor/MLX checks with explicit model and isolated data roots."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
binary = str(Path(args.binary).resolve())
model = str(Path(args.model).resolve())
evidence = {'version': subprocess.check_output([binary, '--version'], text=True).strip()}
source = Path(model) / 'source.json'
evidence['modelSource'] = json.loads(source.read_text()) if source.exists() else {'revision': 'unknown'}
evidence['localWeightSHA256'] = {}
for weight in Path(model).glob('*.safetensors'):
    digest = hashlib.sha256()
    with weight.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    evidence['localWeightSHA256'][weight.name] = digest.hexdigest()


def run(*arguments, expected=0):
    result = subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=90)
    assert result.returncode == expected, (result.returncode, result.stderr)
    return result


def doctor(root, *options):
    result = run('doctor', '--data-root', str(root), '--json', *options)
    report = json.loads(result.stdout)
    serialized = json.dumps(report)
    assert str(root) not in serialized and str(model) not in serialized
    return report


def state(discovery):
    request = urllib.request.Request(discovery['privateEndpoint'] + '/mox/v1/state',
        headers={'Authorization': 'Bearer ' + discovery['token']})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def verify_public_api(root, limited):
    endpoint = run('api', 'enable', '--data-root', str(root)).stdout.strip().split(' ', 1)[1]
    key = run('api', 'key', '--data-root', str(root)).stdout.strip()
    for path in ('/v1/chat/completions', '/v1/messages'):
        for streaming in (False, True):
            expected_error = b'resource_exhausted' if path.endswith('completions') else b'overloaded_error'
            body = {'model': 'diagnostic-fixture', 'max_tokens': 8, 'stream': streaming,
                    'messages': [{'role': 'user', 'content': 'Say hello briefly.'}]}
            request = urllib.request.Request(endpoint + path, data=json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + key, 'x-api-key': key,
                         'anthropic-version': '2023-06-01', 'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(request, timeout=90) as response:
                    payload = response.read()
                    if limited:
                        # Existing stream contract reports post-header failures as SSE errors.
                        assert streaming and expected_error in payload
                        assert b'text_delta' not in payload and b'"content":' not in payload
                        continue
                    if streaming:
                        assert b'data:' in payload
                        assert b'[DONE]' in payload if path.endswith('completions') else b'message_stop' in payload
                    else:
                        result = json.loads(payload)
                        assert result.get('choices') or result.get('content')
            except urllib.error.HTTPError as error:
                payload = error.read()
                assert limited and error.code == 503
                assert expected_error in payload
    run('api', 'disable', '--data-root', str(root))


with tempfile.TemporaryDirectory(prefix='mox-diagnostics-') as folder:
    base = Path(folder)
    offline = base / 'not-created'
    report = doctor(offline)
    assert not offline.exists()
    assert next(item for item in report['results'] if item['id'] == 'service.identity')['status'] == 'skipped'
    evidence['offlineReadOnly'] = True
    for limited in (False, True):
        root = base / ('low-budget' if limited else 'normal-budget')
        root.mkdir()
        with (root / 'worker.log').open('w') as log:
            command = [binary, 'serve', '--data-root', str(root)]
            if limited:
                command += ['--budget-bytes', str(64 * 1024 * 1024)]
            worker = subprocess.Popen(command, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 25
                while not (root / 'run/discovery.json').exists():
                    assert worker.poll() is None, 'worker exited before readiness'
                    assert time.monotonic() < deadline, 'worker readiness deadline exceeded'
                    time.sleep(0.05)
                discovery = json.loads((root / 'run/discovery.json').read_text())
                run('models', 'import', '--data-root', str(root), model, '--alias', 'diagnostic-fixture')
                report = doctor(root, '--model', 'diagnostic-fixture')
                assert next(item for item in report['results'] if item['id'] == 'model.integrity')['status'] == 'passed'
                assert next(item for item in report['results'] if item['id'] == 'service.identity')['status'] == 'passed'
                assert discovery['token'] not in json.dumps(report)
                result = run('chat', '--data-root', str(root), '--model', 'diagnostic-fixture',
                    '--prompt', 'Say hello briefly.', '--max-tokens', '8', '--temperature', '0',
                    expected=1 if limited else 0)
                snapshot = state(discovery)
                assert snapshot['activeLeases'] == 0 and snapshot['queued'] == 0
                if limited:
                    assert 'resourceLimit' in result.stderr and not result.stdout.strip()
                    assert snapshot['residentModels'] == 0 and snapshot['reservedBytes'] == 0
                    evidence['beforeLoadBudgetRejection'] = True
                else:
                    assert result.stdout.strip()
                    assert snapshot['residentModels'] == 1
                    assert snapshot['backendMemory']['activeBytes'] > 0
                    evidence['normalMLXGeneration'] = True
                    evidence['doctor'] = report
                verify_public_api(root, limited)
                if limited:
                    snapshot = state(discovery)
                    assert snapshot['residentModels'] == 0 and snapshot['reservedBytes'] == 0
                evidence['publicAPIRejectedBeforeLoad' if limited else 'publicAPITextAndStreams'] = True
            finally:
                worker.terminate()
                try:
                    worker.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait(timeout=5)
                    raise AssertionError('worker did not complete graceful shutdown')
                assert not (root / 'run/discovery.json').exists()
Path(args.output).write_text(json.dumps(evidence, indent=2))
print('Real doctor, read-only offline root, integrity, MLX generation and budget rejection passed.')
