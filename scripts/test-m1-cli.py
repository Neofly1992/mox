#!/usr/bin/env python3
"""Real CLI acceptance checks. No third-party Python dependencies; dev tooling only."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import subprocess
import tempfile
import termios
import time

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--model', required=True)
args = parser.parse_args()
binary = str(Path(args.binary).resolve())
model = Path(args.model).resolve()
base = [binary, 'chat', '--model-path', str(model)]

def fingerprint():
    return {str(p.relative_to(model)): (p.stat().st_size, p.stat().st_mtime_ns)
            for p in model.iterdir() if p.is_file()}

before = fingerprint()
results = {}
with tempfile.TemporaryDirectory(prefix='mox-cli-') as cwd:
    for name, extra, expected in [
        ('invalid-tokens', ['--prompt', 'x', '--max-tokens', '0'], 2),
        ('nan-temperature', ['--prompt', 'x', '--temperature', 'nan'], 2),
        ('unknown-option', ['--unknown-m1-option'], 2),
        ('non-tty-input', [], 2),
    ]:
        process = subprocess.run(base + extra, stdin=subprocess.DEVNULL, capture_output=True, cwd=cwd, timeout=20)
        assert process.returncode == expected, (name, process.returncode, process.stderr)
        assert not process.stdout, (name, process.stdout)
        results[name] = process.returncode
    missing = subprocess.run([binary, 'chat', '--model-path', cwd + '/不存在', '--prompt', 'x'], capture_output=True, timeout=20)
    assert missing.returncode == 1 and b'invalidModel' in missing.stderr
    results['missing-model'] = missing.returncode
    alias = Path(cwd) / '模型 空格'
    alias.symlink_to(model, target_is_directory=True)
    unicode_base = [binary, 'chat', '--model-path', str(alias)]
    start = time.monotonic()
    one = subprocess.Popen(unicode_base + ['--prompt', '用一句话解释什么是海洋。', '--max-tokens', '48', '--temperature', '0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd)
    selector = selectors.DefaultSelector()
    selector.register(one.stdout, selectors.EVENT_READ, 'out')
    selector.register(one.stderr, selectors.EVENT_READ, 'err')
    data = {'out': b'', 'err': b''}
    first_byte = None
    chunks = 0
    while selector.get_map():
        assert time.monotonic() - start < 120
        for key, _ in selector.select(.1):
            chunk = os.read(key.fd, 8192)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            data[key.data] += chunk
            if key.data == 'out':
                chunks += 1
                if first_byte is None: first_byte = time.monotonic() - start
    selector.close()
    assert one.wait(timeout=10) == 0, data
    assert data['out'].strip() and b'finished=' in data['err'] and b'output_tokens=' in data['err']
    assert chunks > 1, 'CLI did not stream multiple writes'
    assert '用一句话解释什么是海洋。'.encode() not in data['err']
    results['outside-source-one-shot'] = {'seconds': time.monotonic() - start, 'first_output_seconds': first_byte, 'stdout_reads': chunks, 'stdout': data['out'].decode(), 'stderr': data['err'].decode()}

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    master, slave = pty.openpty()
    process = subprocess.Popen(base + ['--max-tokens', '2048', '--temperature', '0'], stdin=slave,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, preexec_fn=controlling_terminal)
    os.close(slave)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, 'out')
    selector.register(process.stderr, selectors.EVENT_READ, 'err')
    captured = {'out': b'', 'err': b''}

    def until(predicate, timeout=120):
        deadline = time.monotonic() + timeout
        while not predicate():
            assert time.monotonic() < deadline, ('timeout', captured)
            for key, _ in selector.select(.1):
                chunk = os.read(key.fd, 8192)
                if chunk:
                    captured[key.data] += chunk
                else:
                    selector.unregister(key.fileobj)
            if process.poll() is not None and not predicate():
                raise AssertionError(('early exit', process.returncode, captured))

    try:
        until(lambda: captured['err'].count(b'You>') >= 1)
        os.write(master, b'Remember the word ocean. Reply only OK.\n')
        until(lambda: captured['err'].count(b'You>') >= 2)
        os.write(master, b'Write a very long story with one thousand numbered paragraphs.\n')
        until(lambda: captured['err'].count(b'phase=decode') >= 2)
        start = time.monotonic()
        os.write(master, b'\x03')  # actual terminal Ctrl-C, not a mock cancel
        until(lambda: captured['err'].count(b'You>') >= 3)
        assert b'finished=cancelled' in captured['err'], captured
        results['interactive-cancel-wait-seconds'] = time.monotonic() - start
        os.write(master, b'What word did I ask you to remember? Reply briefly.\n')
        until(lambda: captured['err'].count(b'You>') >= 4)
        os.write(master, b'\x04')  # idle EOF
        process.wait(timeout=20)
        assert process.returncode == 0, captured
        assert captured['err'].count(b'phase=loading') == 1, captured
        results['interactive-reuse'] = {k: v.decode(errors='replace') for k, v in captured.items()}
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
        selector.close(); os.close(master)

    for number, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143)]:
        process = subprocess.Popen(base + ['--prompt', 'Write a very long story with one thousand numbered paragraphs.', '--max-tokens', '8192'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        selector.register(process.stderr, selectors.EVENT_READ)
        deadline = time.monotonic() + 120
        seen = b''
        try:
            while b'phase=decode' not in seen:
                assert time.monotonic() < deadline
                for key, _ in selector.select(.1):
                    data = os.read(key.fd, 8192)
                    assert data, ('terminated before decode', seen)
                    if key.fileobj is process.stderr:
                        seen += data
            process.send_signal(number)
            out, err = process.communicate(timeout=30)
            assert process.returncode == expected, (number, process.returncode, seen + err)
            results[signal.Signals(number).name] = process.returncode
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            selector.close()
    # Fill a pipe before handing it to the CLI; leave its read end open but unread.
    # This deterministically exercises real pipe backpressure without depending on prose length.
    for stream_name in ['stderr', 'stdout']:
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True: os.write(write_fd, b'x' * 4096)
        except BlockingIOError:
            pass
        kwargs = {stream_name: write_fd, ('stdout' if stream_name == 'stderr' else 'stderr'): subprocess.PIPE}
        started = time.monotonic()
        process = subprocess.Popen(base + ['--prompt', 'Say hello.', '--max-tokens', '4', '--temperature', '0'], cwd=cwd, **kwargs)
        try:
            out, err = process.communicate(timeout=20)
            expected = 0 if stream_name == 'stderr' else 1
            assert process.returncode == expected, (stream_name, process.returncode, out, err)
            if stream_name == 'stdout': assert b'slowConsumer' in err
            results['full-' + stream_name + '-pipe'] = {'exit': process.returncode, 'seconds': time.monotonic() - started}
        finally:
            if process.poll() is None: process.kill(); process.wait()
            os.close(read_fd); os.close(write_fd)

    offline = subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)'] + base + ['--prompt', 'Say hello.', '--max-tokens', '4', '--temperature', '0'], capture_output=True, cwd=cwd, timeout=60)
    assert offline.returncode == 0 and offline.stdout.strip(), offline.stderr
    results['network-denied'] = offline.returncode
assert fingerprint() == before, 'Local model assets were modified'
results['model-assets-unchanged'] = True
print(json.dumps(results, ensure_ascii=False, indent=2))
