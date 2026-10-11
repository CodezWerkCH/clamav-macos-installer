#!/usr/bin/env python3
"""Run isolated regressions in a disposable checkout, never the real installation."""
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
def run(*args, cwd=None):subprocess.run([str(x) for x in args],cwd=cwd,check=True)
with tempfile.TemporaryDirectory(prefix='clamav-tests-') as tmp:
 root=Path(tmp).resolve();shutil.copytree(ROOT/'src',root/'src');g=root/'src/gui'
 run('/bin/bash','-n',root/'src/backend/install.sh')
 run('xcrun','clang','-arch','arm64','-std=c11','-Wall','-Wextra','-Werror','-O2',g/'pty_bridge.c','-o',g/'backend-tests/pty-bridge')
 run('xcrun','swiftc','-D','ARCHIVE_TEST','-module-cache-path',g/'cache',g/'package_archive.swift','-o',g/'package-archive-test')
 for folder,source in [('prompt-tests','InputPromptState.swift'),('scan-ui-tests','ScanSnapshot.swift')]:
  run('xcrun','swiftc','-module-cache-path',g/'cache',g/source,g/folder/'main.swift','-o',g/folder/'tests')
  run(g/folder/'tests')
 for file in ['archive-tests/test_archive.py','permission-helper-tests/test_helper.py','backend-v11-tests/test_backend.py','package-removal-tests/test_repair.py','package-removal-tests/test_package_removal.py','legacy-tests/run-tests.py','brew-prompt-tests/test_brew_prompt.py','version-tests/test_versions.py','progress-backend-tests/test_progress.py','backend-tests/test_bridge.py','prompt-tests/test_gui_bridge.py','live-pipe-tests/run.py']:
  print('\nTEST '+file,flush=True);run('python3',g/file,cwd=root)
print('All isolated suites passed. No live install or TCC permissions were changed.')
