#!/usr/bin/env python3
"""Measure history reads in fresh processes, independently of fixture construction."""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--binary', default='.build/m2-tests/debug/MoxTestSupport')
parser.add_argument('--output', default='.build/m2-history.json')
args = parser.parse_args()
binary = str(pathlib.Path(args.binary).resolve())
results = []
for conversations in (12, 120):
    with tempfile.TemporaryDirectory(prefix='mox-history-benchmark-') as root:
        subprocess.run([binary, 'history-benchmark-seed', root, str(conversations)],
                       check=True, capture_output=True, timeout=180)
        samples = []
        for _ in range(3):
            read = subprocess.run([binary, 'history-benchmark-read', root],
                                  check=True, capture_output=True, text=True, timeout=30)
            sample = json.loads(read.stdout.strip().splitlines()[-1])
            assert sample['summaryDecodedBytes'] == 0
            assert sample['visibleAttempts'] == 8
            assert sample['visibleSummaries'] <= 100
            assert sample['detailDecodedBytes'] < 4 * 1024 * 1024
            samples.append(sample)
        results.append({'conversations': conversations, 'attempts': conversations * 20,
                        'replyBytes': conversations * 20 * 128 * 1024, 'samples': samples})
pathlib.Path(args.output).write_text(json.dumps(results, indent=2) + '\n')
print('PASS history pages: 30/300 MiB histories, 3 fresh readers each, summaries/create decode no bodies')
