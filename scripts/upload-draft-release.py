#!/usr/bin/env python3
"""Upload checked binary assets without changing tags, public releases or existing assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request


def require(condition, message):
    if not condition:
        raise SystemExit(message)


class GitHub:
    def __init__(self, repository, token):
        self.base = f'https://api.github.com/repos/{repository}'
        self.token = token

    def request(self, path, *, payload=None, data=None, content_type='application/json'):
        url = path if path.startswith('https://') else self.base + path
        if payload is not None:
            data = json.dumps(payload).encode()
        request = urllib.request.Request(url, data=data, headers={
            'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': content_type})
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)

    def tag_commit(self, tag):
        obj = self.request('/git/ref/tags/' + urllib.parse.quote(tag, safe=''))['object']
        for _ in range(10):
            if obj['type'] == 'commit':
                return obj['sha']
            require(obj['type'] == 'tag', 'Tag does not identify a commit')
            obj = self.request('/git/tags/' + obj['sha'])['object']
        raise SystemExit('Too many nested annotated tags')


def upload(api, tag, directory):
    manifests = list(directory.glob('*.json'))
    require(len(manifests) == 1, 'Expected exactly one package manifest')
    manifest = json.loads(manifests[0].read_text())
    require(tag == manifest['tag'] == 'v' + manifest['version'], 'Tag/version mismatch')
    require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag), 'Invalid release tag')
    require(manifest['signing'] == 'adhoc-unnotarized', 'Unsupported signing mode')
    require(re.fullmatch(r'[a-f0-9]{40}', manifest['commit']), 'Invalid commit')
    archive_name = manifest['archive']
    require(Path(archive_name).name == archive_name and archive_name.endswith('.zip'), 'Invalid archive name')
    archive = directory / archive_name
    checksum = directory / archive.with_suffix('.sha256').name
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['sha256'], 'ZIP checksum mismatch')
    require(checksum.read_text() == f"{manifest['sha256']}  {archive_name}\n", 'Invalid checksum file')
    assets = [archive, checksum, manifests[0]]
    require(set(directory.iterdir()) == set(assets), 'Unexpected upload files')
    require(api.tag_commit(tag) == manifest['commit'], 'Remote tag moved or differs from built commit')
    marker = f"<!-- mox-binary-commit:{manifest['commit']} signing:adhoc-unnotarized -->"
    try:
        release = api.request('/releases/tags/' + tag)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        error.close()
        body = (f'{marker}\n\nExperimental Apple Silicon App, ad hoc signed and NOT notarized. '
                'Not a Developer ID installer. No model weights included.\n\n'
                f"Source commit: `{manifest['commit']}`. Minimum target: macOS 15 (not yet verified on macOS 15).\n\n"
                'Download the actual ZIP and matching SHA-256 file. Verify, extract and run real MLX '
                'and GUI acceptance on this same attachment before manually publishing. '
                'Repository rules and hosted build checks do not perform that acceptance. '
                'See docs/RELEASE.md and docs/VALIDATION.md at this tag. '
                'Retries add new assets; select one run/attempt and record its checksum.')
        release = api.request('/releases', payload={'tag_name': tag, 'target_commitish': manifest['commit'],
            'name': f'Mox {manifest["version"]} — experimental ad hoc', 'body': body,
            'draft': True, 'prerelease': True})
    require(release['draft'] and release['tag_name'] == tag and marker in (release.get('body') or ''),
            'Refusing a public or unrelated release')
    for asset in assets:
        # Recheck immediately before each write; never edit release state or delete attachments.
        current = api.request('/releases/' + str(release['id']))
        require(current['draft'] and current['tag_name'] == tag and marker in (current.get('body') or ''),
                'Release changed during upload')
        require(api.tag_commit(tag) == manifest['commit'], 'Remote tag changed during upload')
        existing = []
        page = 1
        while True:
            batch = api.request(f'/releases/{release["id"]}/assets?per_page=100&page={page}')
            existing.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        matches = [entry for entry in existing if entry['name'] == asset.name]
        data = asset.read_bytes()
        if matches:
            digest = 'sha256:' + hashlib.sha256(data).hexdigest()
            require(len(matches) == 1 and matches[0].get('digest') == digest and matches[0]['size'] == len(data),
                    f'Existing asset differs or has no verifiable digest: {asset.name}; rerun with a new attempt')
            continue
        url = release['upload_url'].split('{')[0] + '?name=' + urllib.parse.quote(asset.name, safe='')
        # Ensure credentials can only be sent to GitHub's upload host.
        require(urllib.parse.urlparse(url).netloc == 'uploads.github.com', 'Unexpected upload host')
        api.request(url, data=data, content_type='application/octet-stream')
    print(release['html_url'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    token = os.environ.get('GH_TOKEN')
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    require(token, 'Missing environment-scoped DRAFT_RELEASE_TOKEN; no fallback to GITHUB_TOKEN')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid repository')
    upload(GitHub(repository, token), args.tag, args.directory.resolve())


if __name__ == '__main__':
    main()
