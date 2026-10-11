#!/usr/bin/env python3
"""Bundle source and the already-built app; exclude local data and git history."""
from release_notes import notes, check_zip, check_packages
from pathlib import Path
import hashlib, zipfile
ROOT=Path(__file__).resolve().parents[1];VERSION, NOTES_PATH, NOTES = notes(ROOT);OUT=ROOT/'dist'
app=OUT/f'ClamAV-Installer-{VERSION}-Apple-Silicon.zip'
if not app.is_file():raise SystemExit('Run scripts/build.py first')
check_zip(app, {NOTES_PATH.name: NOTES, **{n: (ROOT/'docs'/n).read_bytes() for n in ['Instructions-English.txt', 'Anleitung-Deutsch.txt']}})
source=OUT/f'ClamAV-Installer-{VERSION}-Source.zip'
files=sorted(p for p in ROOT.rglob('*') if p.is_file() and not any(x in ['.git','dist','__pycache__','.DS_Store'] for x in p.relative_to(ROOT).parts))
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
 for p in files:z.write(p,'clamav-macos-installer/'+str(p.relative_to(ROOT)))
complete=OUT/f'ClamAV-Installer-{VERSION}-Complete.zip'
with zipfile.ZipFile(complete,'w',zipfile.ZIP_DEFLATED) as z:
 for p in files:z.write(p,'Source/clamav-macos-installer/'+str(p.relative_to(ROOT)))
 with zipfile.ZipFile(app) as application:
  for item in application.infolist():z.writestr(item,application.read(item.filename))
checks=OUT/'SHA256SUMS.txt'
checks.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in [app,source,complete]))
print(checks.read_text())

check_packages(ROOT)
