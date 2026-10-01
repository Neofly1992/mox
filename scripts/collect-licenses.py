#!/usr/bin/env python3
"""Copy upstream notices, including embedded dependencies, preserving their paths."""
import json
from pathlib import Path
import shutil
import sys
checkouts, destination = map(Path, sys.argv[1:])
root = Path(__file__).resolve().parent.parent
for pin in json.loads((root / 'Package.resolved').read_text())['pins']:
    name = pin['identity']
    source = checkouts / name
    if not source.is_dir():
        raise SystemExit('Missing locked checkout: ' + name)
    copied = 0
    for file in source.rglob('*'):
        relative = file.relative_to(source)
        if '.git' in relative.parts or not file.is_file():
            continue
        if file.name.upper().startswith(('LICENSE', 'NOTICE', 'COPYING')):
            target = destination / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
            copied += 1
    if not copied:
        raise SystemExit('Missing upstream license: ' + name)
