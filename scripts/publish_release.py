#!/usr/bin/env python3
"""Publish only a new release, verifying uploaded bytes while still a draft."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from release_notes import ROOT, notes, check_packages

def gh(*args):
    return subprocess.check_output(['gh', *map(str, args)], text=True)

def main(tag):
    version, path, data = notes(tag=tag)
    check_packages()
    # gh create refuses existing releases: never overwrite published versions.
    assets = [ROOT / 'dist' / f'ClamAV-Installer-{version}-{kind}.zip'
              for kind in ['Apple-Silicon', 'Source', 'Complete']]
    assets.append(ROOT / 'dist/SHA256SUMS.txt')
    gh('release', 'create', tag, '--verify-tag', '--draft', '--title',
       f'ClamAV Installer {version}', '--notes-file', path, *assets)
    release = json.loads(gh('release', 'view', tag, '--json', 'body,isDraft,assets'))
    if not release['isDraft'] or release['body'].replace('\r\n', '\n') != data.decode().replace('\r\n', '\n'):
        raise ValueError('Uploaded release description differs; release left as draft')
    if sorted(a['name'] for a in release['assets']) != sorted(p.name for p in assets):
        raise ValueError('Unexpected uploaded assets; release left as draft')
    with tempfile.TemporaryDirectory(prefix='release-download-') as tmp:
        gh('release', 'download', tag, '--dir', tmp)
        check_packages(directory=Path(tmp))
        for asset in assets:
            if asset.read_bytes() != (Path(tmp) / asset.name).read_bytes():
                raise ValueError('Uploaded bytes differ; release left as draft')
    gh('release', 'edit', tag, '--draft=false')
    print(f'Published {tag}: bilingual description and all packages verified')

if __name__ == '__main__':
    main(sys.argv[1])
