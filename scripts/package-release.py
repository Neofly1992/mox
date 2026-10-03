#!/usr/bin/env python3
"""Check a complete ad hoc App and archive only its bundle, never the build root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def validate_app(app, version, identity):
    worker = app / 'Contents/Helpers/MoxWorker.app'
    for bundle, executable in ((app, 'Mox'), (worker, 'mox')):
        with (bundle / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == version,
                f'Incorrect version: {bundle}')
        binary = bundle / 'Contents/MacOS' / executable
        require(run('lipo', '-archs', str(binary)) == 'arm64', f'Incorrect architecture: {binary}')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        signature = subprocess.run(['codesign', '-d', '-vv', str(bundle)], capture_output=True, text=True, check=True)
        require('Signature=adhoc' in signature.stderr, 'This packager only accepts explicitly ad hoc builds.')
    reported = run(str(worker / 'Contents/MacOS/mox'), '--version')
    require(reported == f'{version} {identity} (Release)', f'Worker identity mismatch: {reported}')
    resources = worker / 'Contents/Resources'
    staged = ROOT / '.build/Release'
    expected_bundles = {p.name for p in staged.glob('*.bundle')}
    require('mlx-swift_Cmlx.bundle' in expected_bundles, 'Missing staged MLX bundle')
    require({p.name for p in resources.glob('*.bundle')} == expected_bundles, 'Worker resource bundles differ')
    for source in [*staged.glob('*.bundle'), staged / 'licenses']:
        for original in source.rglob('*'):
            if original.is_file():
                copied = resources / original.relative_to(staged)
                require(copied.is_file() and original.read_bytes() == copied.read_bytes(), f'Missing/changed resource: {copied}')
    libraries = list(app.rglob('default.metallib'))
    require(len(libraries) == 1 and libraries[0].stat().st_size > 0, 'Missing or ambiguous Metal library')
    require((resources / 'licenses/Mox-LICENSE').is_file(), 'Missing Mox license')
    for pin in json.loads((ROOT / 'Package.resolved').read_text())['pins']:
        notices = resources / 'licenses' / pin['identity']
        require(notices.is_dir() and any(p.is_file() for p in notices.rglob('*')),
                f'Missing dependency notices: {pin["identity"]}')
    # The App bundle is the allowlisted payload. Reject unexpected private/runtime material.
    for path in app.rglob('*'):
        require(not path.is_symlink(), f'Unexpected symlink: {path}')
        require(path.suffix.lower() not in {'.safetensors', '.gguf', '.sqlite', '.sqlite3', '.db', '.pem', '.p12', '.xcresult'}
                and path.name not in {'.env', 'HANDOFF.md', 'discovery.json'}, f'Forbidden payload: {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', help='Existing vVERSION tag; omit only for branch build verification')
    parser.add_argument('--output', default='.build/release')
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Invalid VERSION')
    commit = run('git', 'rev-parse', 'HEAD')
    if args.tag:
        require(args.tag == f'v{version}', 'Tag must exactly match VERSION')
        require(run('git', 'rev-parse', f'refs/tags/{args.tag}^{{commit}}') == commit, 'HEAD is not the requested tag commit')
    identity = run('python3', str(ROOT / 'scripts/stamp-build.py'), '--check')
    app = ROOT / '.build/Release/Mox.app'
    validate_app(app, version, identity)
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    run_id = os.environ.get('GITHUB_RUN_ID', 'local')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '1')
    require(re.fullmatch(r'(local|[0-9]+)', run_id) and re.fullmatch(r'[0-9]+', attempt), 'Invalid build identifier')
    stem = f'Mox-v{version}-macos-arm64-adhoc-{run_id}-{attempt}'
    archive = output / f'{stem}.zip'
    checksum = output / f'{stem}.sha256'
    metadata_path = output / f'{stem}.json'
    require(not any(p.exists() for p in (archive, checksum, metadata_path)), 'Refusing to overwrite a package; use a fresh output directory')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix='Mox release check ') as folder:
        subprocess.run(['ditto', '-x', '-k', str(archive), folder], check=True)
        validate_app(Path(folder) / 'Mox.app', version, identity)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum.write_text(f'{digest}  {archive.name}\n')
    metadata_path.write_text(json.dumps({'version': version, 'tag': args.tag, 'commit': commit,
        'identity': identity, 'signing': 'adhoc-unnotarized', 'archive': archive.name, 'sha256': digest,
        'run_id': run_id, 'run_attempt': attempt}, indent=2) + '\n')
    print(metadata_path.read_text())


if __name__ == '__main__':
    main()
