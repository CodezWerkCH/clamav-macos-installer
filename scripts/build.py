#!/usr/bin/env python3
"""Build the complete ARM64 app from this checkout. Does not install ClamAV."""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
GUI=ROOT/'src/gui'; OUT=ROOT/'dist'; OUT.mkdir(exist_ok=True)
VERSION=(ROOT/'VERSION').read_text().strip()
def run(*args): subprocess.run([str(a) for a in args],check=True)
with tempfile.TemporaryDirectory(prefix='clamav-build-') as tmp:
 stage=Path(tmp).resolve(); package=stage/'package';package.mkdir()
 app=package/'ClamAV Installer.app'; mac=app/'Contents/MacOS';res=app/'Contents/Resources'
 mac.mkdir(parents=True);res.mkdir();cache=stage/'cache'
 shutil.copyfile(ROOT/'assets/AppIcon.icns',res/'AppIcon.icns')
 shutil.copytree(GUI/'i18n',res/'i18n')
 shutil.copyfile(ROOT/'src/backend/install.sh',res/'install.sh')
 shutil.copyfile(ROOT/'docs/Anleitung-Deutsch.txt',res/'Anleitung.txt')
 shutil.copyfile(ROOT/'docs/Anleitung-Deutsch.txt',package/'Anleitung-Deutsch.txt')
 info={'CFBundleExecutable':'ClamAVInstaller','CFBundleIdentifier':'local.clamav.automatik.installer','CFBundleName':'ClamAV Installer','CFBundleDisplayName':'ClamAV Installer','CFBundlePackageType':'APPL','CFBundleShortVersionString':VERSION,'CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon','LSApplicationCategoryType':'public.app-category.utilities'}
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 run('xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx14.0','-module-cache-path',cache,'-O','-framework','AppKit',*[GUI/n for n in ['Localization.swift','LivePipeReader.swift','InputPromptState.swift','ScanSnapshot.swift','main.swift']],'-o',mac/'ClamAVInstaller')
 for source,target in [('pty_bridge.c','pty-bridge'),('package_repair.c','package-repair')]:
  run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-std=c11','-Wall','-Wextra','-Werror','-O2',GUI/source,'-o',mac/target)
 run('xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx14.0','-module-cache-path',cache,'-O',GUI/'package_archive.swift','-o',mac/'package-archive')
 for file in mac.iterdir():file.chmod(0o755)
 (res/'install.sh').chmod(0o700)
 readmes=package/'Languages';readmes.mkdir()
 master=json.loads((GUI/'i18n/de.json').read_text())
 keys=[next(k for k in master if k.startswith(prefix)) for prefix in ['1. Sprache wählen','In Systemeinstellungen','Native Oberfläche']]
 for file in (GUI/'i18n').glob('*.json'):
  table=json.loads(file.read_text())
  (readmes/('README-'+file.stem+'.txt')).write_text('ClamAV Installer '+VERSION+'\nApple Silicon · macOS 14+\n\n'+'\n\n'.join(table[k].replace('{scanner}','/opt/homebrew/opt/clamav/bin/clamdscan') for k in keys)+'\n')
 run('/bin/bash','-n',res/'install.sh')
 for target in [mac/'pty-bridge',mac/'package-repair',mac/'package-archive',app]:run('/usr/bin/codesign','--force','--sign','-',target)
 run('/usr/bin/codesign','--verify','--deep','--strict',app)
 run(mac/'ClamAVInstaller','--self-test')
 archive=OUT/('ClamAV-Installer-'+VERSION+'-Apple-Silicon.zip')
 run('/usr/bin/ditto','-c','-k','--norsrc','--noextattr',package,archive)
 verify=stage/'verify';run('/usr/bin/ditto','-x','-k',archive,verify)
 verified=verify/'ClamAV Installer.app'
 run('/usr/bin/codesign','--verify','--deep','--strict',verified)
 run(verified/'Contents/MacOS/ClamAVInstaller','--self-test')
 assert (verified/'Contents/Resources/install.sh').read_bytes()==(ROOT/'src/backend/install.sh').read_bytes()
 digest=hashlib.sha256(archive.read_bytes()).hexdigest()
 (OUT/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
 print(json.dumps({'version':VERSION,'file':str(archive),'sha256':digest},indent=2))
