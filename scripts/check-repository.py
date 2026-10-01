#!/usr/bin/env python3
"""Portable repository hygiene checks; never claim to run MLX."""
import ast
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors = []
version = (ROOT / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    errors.append('Invalid VERSION')
for name in ('CHANGELOG.md', 'README.md', 'docs/RELEASE.md'):
    if version not in (ROOT / name).read_text():
        errors.append(f'{name}: product version missing')
subprocess.run(['python3', 'scripts/stamp-build.py', '--check'], cwd=ROOT, check=True)
project = (ROOT / 'Mox.xcodeproj/project.pbxproj').read_text()
for field in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'):
    values = re.findall(rf'{field} = ([^;]+);', project)
    if not values or any(value != version for value in values):
        errors.append(f'{field} differs from VERSION')
files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
for name in sorted(set(files)):
    path = ROOT / name
    if not name or not path.is_file():
        continue
    if path.suffix in {'.safetensors', '.gguf', '.dylib', '.metallib', '.pyc', '.a', '.o'} or '.app/' in name or name.startswith('.build/'):
        errors.append(f'{name}: generated binary or model tracked')
    data = path.read_bytes()
    if b'\0' in data:
        errors.append(f'{name}: binary content tracked')
        continue
    source = data.decode('utf-8')
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}', source):
        errors.append(f'{name}: possible credential; inspect privately')
    if path.suffix == '.py':
        ast.parse(source, filename=name)
    if path.suffix == '.sh':
        subprocess.run(['bash', '-n', str(path)], check=True)
    if path.suffix == '.md':
        for target in re.findall(r'\]\(([^)]+)\)', source):
            target = target.split('#')[0].strip('<>')
            if not target or '://' in target or target.startswith('mailto:'):
                continue
            if not (path.parent / target).exists():
                errors.append(f'{name}: broken link {target}')
    if name != 'scripts/check-repository.py' and re.search(r'scripts/(?:build|test|stamp|verify|benchmark|collect)-m[1-4]|\.build/m[1-4][-/]', source):
        errors.append(f'{name}: obsolete milestone entry or output path')
if errors:
    raise SystemExit('\n'.join(errors))
print('Repository links, syntax, version, source identity and tracked-file hygiene passed (no MLX execution).')
