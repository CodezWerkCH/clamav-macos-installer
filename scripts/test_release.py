#!/usr/bin/env python3
"""Isolated release guard tests; no network, installation or publishing."""
from pathlib import Path
import hashlib
import tempfile
import unittest
import zipfile
import json
import shutil
from unittest.mock import patch
import publish_release
from release_notes import notes, check_packages

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'docs').mkdir()
        (self.root/'dist').mkdir()
        (self.root/'VERSION').write_text('2.0\n')
        self.text = '## English\n\n' + 'A meaningful release description. ' * 5 + '\n\n## Deutsch\n\n' + 'Eine vollständige Versionsbeschreibung. ' * 5 + '\n'
        self.note = self.root/'docs/RELEASE-2.0.md'
        self.note.write_text(self.text)
        for name in ['Instructions-English.txt', 'Anleitung-Deutsch.txt']:
            (self.root/'docs'/name).write_text(name)

    def packages(self):
        docs = {p.name: p.read_bytes() for p in (self.root/'docs').iterdir()}
        self.archives = []
        for kind, entries in [
            ('Apple-Silicon', docs),
            ('Source', {'clamav-macos-installer/docs/'+k:v for k,v in docs.items()}),
            ('Complete', {**docs, **{'Source/clamav-macos-installer/docs/'+k:v for k,v in docs.items()}}),
        ]:
            p = self.root/'dist'/f'ClamAV-Installer-2.0-{kind}.zip'
            with zipfile.ZipFile(p,'w') as z:
                for name, data in entries.items(): z.writestr(name,data)
            self.archives.append(p)
        (self.root/'dist/SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in self.archives))

    def test_valid_source_and_packages(self):
        notes(self.root, 'v2.0')
        self.packages()
        check_packages(self.root)

    def test_wrong_tag(self):
        with self.assertRaises(ValueError): notes(self.root, 'v2.1')

    def test_missing_file(self):
        self.note.unlink()
        with self.assertRaises(FileNotFoundError): notes(self.root)

    def test_missing_empty_reversed_duplicate_languages(self):
        for text in [self.text.split('## Deutsch')[0], self.text.split('## Deutsch')[0]+'## Deutsch\n', self.text.replace('English','TEMP').replace('Deutsch','English').replace('TEMP','Deutsch'), self.text+'\n## English\nextra']:
            with self.subTest(text=text):
                self.note.write_text(text)
                with self.assertRaises(ValueError): notes(self.root)

    def test_placeholder(self):
        self.note.write_text(self.text+'TODO')
        with self.assertRaises(ValueError): notes(self.root)

    def test_stale_app(self):
        self.packages()
        self.note.write_text(self.text+'Updated notes\n')
        with self.assertRaises(ValueError): check_packages(self.root)

    def test_checksum_mismatch(self):
        self.packages()
        (self.root/'dist/SHA256SUMS.txt').write_text('invalid\n')
        with self.assertRaises(ValueError): check_packages(self.root)

    def test_missing_guide(self):
        self.packages()
        with zipfile.ZipFile(self.archives[0], 'w') as z:
            z.writestr(self.note.name, self.note.read_bytes())
        with self.assertRaises(KeyError): check_packages(self.root)

    def test_publish_only_after_download_verification(self):
        self.packages()
        calls = []
        def fake_gh(*args):
            calls.append(args)
            if args[:2] == ('release', 'view'):
                return json.dumps({'isDraft': True, 'body': self.text,
                    'assets': [{'name': p.name} for p in (self.root/'dist').iterdir()]})
            if args[:2] == ('release', 'download'):
                for p in (self.root/'dist').iterdir(): shutil.copy(p, args[-1])
            return ''
        with patch.object(publish_release, 'ROOT', self.root), patch.object(publish_release, 'notes', lambda tag: notes(self.root, tag)), patch.object(publish_release, 'check_packages', lambda **kw: check_packages(self.root, **kw)), patch.object(publish_release, 'gh', fake_gh):
            publish_release.main('v2.0')
        self.assertEqual(calls[-1], ('release', 'edit', 'v2.0', '--draft=false'))

    def test_bad_uploaded_notes_never_publish(self):
        self.packages()
        calls = []
        def fake_gh(*args):
            calls.append(args)
            return json.dumps({'isDraft': True, 'body': 'wrong', 'assets': []})
        with patch.object(publish_release, 'ROOT', self.root), patch.object(publish_release, 'notes', lambda tag: notes(self.root, tag)), patch.object(publish_release, 'check_packages', lambda **kw: check_packages(self.root, **kw)), patch.object(publish_release, 'gh', fake_gh):
            with self.assertRaises(ValueError): publish_release.main('v2.0')
        self.assertFalse(any(c[:2] == ('release', 'edit') for c in calls))

if __name__ == '__main__': unittest.main()
