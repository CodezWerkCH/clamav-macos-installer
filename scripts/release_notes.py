"""Single source and package checks for bilingual releases (stdlib only)."""
from pathlib import Path
import argparse
import hashlib
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def notes(root=ROOT, tag=None):
    version = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version):
        raise ValueError('VERSION must be a stable numeric version, e.g. 1.1 or 1.1.0')
    if tag is not None and tag != 'v' + version:
        raise ValueError('Tag and VERSION disagree')
    path = root / 'docs' / f'RELEASE-{version}.md'
    data = path.read_bytes()
    text = data.decode('utf-8')
    headings = re.findall(r'^## (English|Deutsch)\s*$', text, re.M)
    if headings != ['English', 'Deutsch']:
        raise ValueError('Exactly one English section followed by one Deutsch section is required')
    for section in re.split(r'^## (?:English|Deutsch)\s*$', text, flags=re.M)[1:]:
        prose = re.sub(r'^#+.*$', '', section, flags=re.M).strip()
        if len(prose) < 80:
            raise ValueError('Both language sections need substantive release notes')
    if re.search(r'\b(?:TODO|TBD|PLACEHOLDER)\b|Describe the changes|Änderungen dieser Version beschreiben|Describe the checks|Tatsächlich durchgeführte Prüfungen und verbleibende Einschränkungen beschreiben|State the actual|Hier den tatsächlichen', text):
        raise ValueError('Replace release-template placeholders before publishing')
    return version, path, data

def check_zip(path, expected):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError(f'Duplicate archive entries: {path.name}')
        for name, data in expected.items():
            if archive.read(name) != data:
                raise ValueError(f'Stale or different documentation: {path.name}: {name}')

def check_packages(root=ROOT, directory=None):
    version, path, data = notes(root)
    directory = directory or root / 'dist'
    guides = {name: (root / 'docs' / name).read_bytes() for name in
              ['Instructions-English.txt', 'Anleitung-Deutsch.txt']}
    root_docs = {path.name: data, **guides}
    source_docs = {f'docs/{name}': value for name, value in root_docs.items()}
    names = []
    for kind, expected in [
        ('Apple-Silicon', root_docs),
        ('Source', {'clamav-macos-installer/' + k: v for k, v in source_docs.items()}),
        ('Complete', {**root_docs, **{'Source/clamav-macos-installer/' + k: v for k, v in source_docs.items()}}),
    ]:
        archive = directory / f'ClamAV-Installer-{version}-{kind}.zip'
        check_zip(archive, expected)
        names.append(archive)
    manifest = ''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in names)
    if (directory / 'SHA256SUMS.txt').read_text() != manifest:
        raise ValueError('Checksum manifest differs from the three packages')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag')
    parser.add_argument('--packages', action='store_true')
    args = parser.parse_args()
    notes(tag=args.tag)
    if args.packages:
        check_packages()
    print('Bilingual release documentation verified' + (' in all packages' if args.packages else ''))
