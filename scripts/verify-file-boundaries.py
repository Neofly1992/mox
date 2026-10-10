#!/usr/bin/env python3
"""Exceptional-file regressions using owned processes and disposable roots."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args = parser.parse_args()
binary = str(Path(args.binary).resolve())


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise AssertionError('Owned worker did not stop within five seconds')


with tempfile.TemporaryDirectory(prefix='mox-file-boundaries-') as folder:
    base = Path(folder)
    offline = base / 'offline'
    run = offline / 'run'
    run.mkdir(parents=True, mode=0o700)
    os.mkfifo(run / 'discovery.json', 0o600)
    result = subprocess.run([binary, 'doctor', '--data-root', str(offline), '--json',
                             '--timeout-seconds', '1'], capture_output=True, text=True, timeout=5)
    assert result.returncode == 1, (result.returncode, result.stderr)
    report = json.loads(result.stdout)
    assert next(r for r in report['results'] if r['id'] == 'service.identity')['status'] == 'failed'
    assert next(r for r in report['results'] if r['id'] == 'data.disk')['status'] in ('passed', 'warning')

    # SIGINT races with a quick rejection. Both a completed failure and a cancelled
    # report are valid; a hung process is not. Wait for the CLI's first progress item.
    process = subprocess.Popen([binary, 'doctor', '--data-root', str(offline), '--json',
                                '--timeout-seconds', '1'], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        import select
        assert select.select([process.stderr], [], [], 3)[0], 'No doctor progress'
        process.stderr.readline()
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode in (1, 130), (process.returncode, stderr)
        json.loads(stdout)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    root = base / 'service'
    root.mkdir()
    model = base / 'model'
    model.mkdir()
    (model / 'config.json').write_text(json.dumps({
        'model_type': 'qwen2', 'hidden_size': 16, 'intermediate_size': 64,
        'num_hidden_layers': 2, 'num_attention_heads': 2, 'num_key_value_heads': 1,
        'max_position_embeddings': 32768, 'vocab_size': 100}))
    for name in ('tokenizer.json', 'tokenizer_config.json'):
        (model / name).write_text('{}')
    os.mkfifo(model / 'model.safetensors', 0o600)
    with (base / 'worker.log').open('w') as log:
        worker = subprocess.Popen([binary, 'serve', '--data-root', str(root)], stdout=log, stderr=log)
        try:
            discovery_path = root / 'run' / 'discovery.json'
            deadline = time.monotonic() + 20
            while not discovery_path.exists() and time.monotonic() < deadline:
                assert worker.poll() is None, 'Worker exited before readiness'
                time.sleep(0.05)
            discovery = json.loads(discovery_path.read_text())

            def request(path, body):
                req = urllib.request.Request(discovery['privateEndpoint'] + '/mox/v1/' + path,
                    data=json.dumps(body).encode(), headers={
                        'Authorization': 'Bearer ' + discovery['token'], 'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=3) as response:
                    return json.load(response)

            body = {'model': {'kind': 'localDirectory', 'path': str(model)}, 'explicit': {}}
            assert request('resources', body)['status'] == 'unknown'
            assert request('config/effective', body)['maxTokens'] > 0
        finally:
            stop(worker)
        assert worker.returncode == 0, 'Worker did not shut down cleanly'
    assert not discovery_path.exists(), 'Worker retained its discovery after shutdown'
print('FIFO doctor deadline/signal, resource preview, sampling responsiveness and clean worker shutdown passed.')
