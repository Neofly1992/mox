#!/usr/bin/env python3
"""Exercise release upload refusal and retry behavior without GitHub writes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location('draft', Path(__file__).with_name('upload-draft-release.py'))
draft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(draft)


package_spec = importlib.util.spec_from_file_location('package', Path(__file__).with_name('package-release.py'))
package = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(package)


class PackageDirectoryTests(unittest.TestCase):
    def test_build_directories_are_rejected_case_insensitively(self):
        for name in ('Release', 'release', 'RELEASE', 'Debug', 'debug/nested'):
            with self.subTest(name=name), self.assertRaisesRegex(SystemExit, 'separate'):
                package.validate_output_directory(package.ROOT / '.build' / name)

    def test_only_fresh_or_empty_output_is_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'release-assets'
            package.validate_output_directory(output)
            output.mkdir()
            package.validate_output_directory(output)
            (output / 'unexpected.txt').write_text('preserve this file')
            with self.assertRaisesRegex(SystemExit, 'empty directory'):
                package.validate_output_directory(output)
            self.assertEqual((output / 'unexpected.txt').read_text(), 'preserve this file')


class FakeGitHub:
    def __init__(self, *, public=False, missing=False, moved=False, conflict=False):
        self.commit = 'a' * 40
        self.moved = moved
        self.missing = missing
        self.conflict = conflict
        self.writes = []
        self.assets = []
        self.release = {'id': 1, 'draft': not public, 'tag_name': 'v0.1.0',
            'body': f'<!-- mox-binary-commit:{self.commit} signing:adhoc-unnotarized -->',
            'upload_url': 'https://uploads.github.com/repos/test/mox/releases/1/assets{?name,label}',
            'html_url': 'https://github.com/test/mox/releases/tag/v0.1.0'}

    def tag_commit(self, tag):
        return 'b' * 40 if self.moved else self.commit

    def request(self, path, *, payload=None, data=None, content_type=None):
        if path.startswith('/releases/tags/') and self.missing:
            raise urllib.error.HTTPError(path, 404, 'Missing', {}, __import__('io').BytesIO())
        if payload is not None:
            self.writes.append(payload)
            self.missing = False
            return self.release
        if data is not None:
            from urllib.parse import parse_qs, urlparse
            name = parse_qs(urlparse(path).query)['name'][0]
            self.writes.append(name)
            self.assets.append({'name': name, 'digest': 'sha256:' + hashlib.sha256(data).hexdigest(), 'size': len(data)})
            return {}
        if '/assets?' in path:
            if self.conflict:
                return [{'name': 'app.zip', 'digest': 'sha256:wrong', 'size': 1}]
            return self.assets
        return self.release


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        data = b'isolated test archive'
        digest = hashlib.sha256(data).hexdigest()
        (self.directory / 'app.zip').write_bytes(data)
        (self.directory / 'app.sha256').write_text(f'{digest}  app.zip\n')
        self.manifest = {'tag': 'v0.1.0', 'version': '0.1.0', 'commit': 'a' * 40,
            'signing': 'adhoc-unnotarized', 'archive': 'app.zip', 'sha256': digest}
        self.save_manifest()

    def save_manifest(self):
        (self.directory / 'app.json').write_text(json.dumps(self.manifest))

    def test_create_is_draft_prerelease_and_retry_preserves_assets(self):
        api = FakeGitHub(missing=True)
        draft.upload(api, 'v0.1.0', self.directory)
        self.assertTrue(api.writes[0]['draft'])
        self.assertTrue(api.writes[0]['prerelease'])
        self.assertEqual(len(api.writes), 4)
        draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(len(api.writes), 4)

    def test_partial_upload_can_retry_without_overwriting(self):
        class InterruptedGitHub(FakeGitHub):
            interrupted = False

            def request(self, path, **kwargs):
                if kwargs.get('data') is not None and len(self.writes) == 1 and not self.interrupted:
                    self.interrupted = True
                    raise TimeoutError('simulated upload failure')
                return super().request(path, **kwargs)

        api = InterruptedGitHub()
        with self.assertRaises(TimeoutError):
            draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, ['app.zip'])
        draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(len(api.writes), 3)
        self.assertEqual(api.writes.count('app.zip'), 1)

    def test_starter_asset_requires_new_build_and_preserves_original(self):
        api = FakeGitHub()
        starter = {'name': 'app.zip', 'state': 'starter', 'digest': None, 'size': 0}
        api.assets.append(starter)
        # Upload-only retries keep the immutable artifact and its original names.
        for _ in range(2):
            with self.assertRaisesRegex(SystemExit, 'Re-run all jobs'):
                draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])
        self.assertEqual(api.assets, [starter])

        # A full rebuild gets fresh names; no deletion or replacement is needed.
        archive = self.directory / 'app.zip'
        archive.rename(self.directory / 'app-new-build.zip')
        (self.directory / 'app.sha256').unlink()
        (self.directory / 'app.json').unlink()
        self.manifest['archive'] = 'app-new-build.zip'
        (self.directory / 'app-new-build.sha256').write_text(
            f"{self.manifest['sha256']}  app-new-build.zip\n")
        (self.directory / 'app-new-build.json').write_text(json.dumps(self.manifest))
        draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes,
            ['app-new-build.zip', 'app-new-build.sha256', 'app-new-build.json'])
        self.assertEqual(api.assets[0], starter)
        draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(len(api.writes), 3)

    def test_becoming_public_stops_remaining_uploads(self):
        class PublishedGitHub(FakeGitHub):
            def request(self, path, **kwargs):
                result = super().request(path, **kwargs)
                if kwargs.get('data') is not None:
                    self.release['draft'] = False
                return result

        api = PublishedGitHub()
        with self.assertRaises(SystemExit):
            draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, ['app.zip'])

    def test_public_release_is_never_modified(self):
        api = FakeGitHub(public=True)
        with self.assertRaises(SystemExit):
            draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])

    def test_moved_tag_is_rejected_before_creation(self):
        api = FakeGitHub(missing=True, moved=True)
        with self.assertRaises(SystemExit):
            draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])

    def test_existing_conflicting_asset_is_never_deleted_or_overwritten(self):
        api = FakeGitHub(conflict=True)
        with self.assertRaises(SystemExit):
            draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])

    def test_mismatched_version_and_tampering_are_rejected(self):
        api = FakeGitHub()
        for change in ('version', 'bytes'):
            if change == 'version':
                self.manifest['version'] = '0.2.0'
                self.save_manifest()
            else:
                self.manifest['version'] = '0.1.0'
                self.save_manifest()
                (self.directory / 'app.zip').write_bytes(b'changed')
            with self.assertRaises(SystemExit):
                draft.upload(api, 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])

    def test_unrelated_draft_and_extra_files_are_rejected(self):
        api = FakeGitHub()
        api.release['body'] = 'Unrelated user draft'
        with self.assertRaises(SystemExit):
            draft.upload(api, 'v0.1.0', self.directory)
        (self.directory / 'private.txt').write_text('fixture')
        with self.assertRaises(SystemExit):
            draft.upload(FakeGitHub(), 'v0.1.0', self.directory)
        self.assertEqual(api.writes, [])


if __name__ == '__main__':
    unittest.main()
