#!/usr/bin/env python3
"""Exercise the real Bash 3.2 error/EXIT traps using a fake brew executable.

All fixtures live beside this file. No HOME override, real packages, launchd
jobs, permissions, or existing archives are changed.
"""
from pathlib import Path
import ast
import hashlib
import json
import os
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "src/backend/install.sh"
LIB = HERE / "backend-functions.sh"
LIB.write_text(SOURCE.read_text().rsplit('\nmain "$@"', 1)[0] + '\n')
tree = ast.parse((HERE.parent / "backend-v11-tests/test_backend.py").read_text())
fixture = next(ast.literal_eval(node.value) for node in tree.body
               if isinstance(node, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == "PREAMBLE" for t in node.targets))
# Reuse the tested launchd mocks but exercise the production brew_cmd wrapper.
brew_start = fixture.index('\nbrew_cmd() {')
brew_end = fixture.index('\nlaunchctl_cmd() {', brew_start)
fixture = fixture[:brew_start] + fixture[brew_end:]
variables = fixture[:fixture.index('\n/bin/mkdir -p')]
functions = fixture[fixture.index('\nnotify_user() {'):]
retry_fixture = variables + functions

BREW = r'''#!/bin/bash
set -eu
printf 'brew %s\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$1" in
    --prefix) printf '%s/homebrew\n' "$FIXTURE_ROOT" ;;
    list) [ -f "$FIXTURE_ROOT/package-installed" ] || exit 1; printf 'clamav 1.5.4\n' ;;
    uses)
        if [ -f "$FIXTURE_ROOT/dependency-error" ]; then exit 71; fi
        if [ -f "$FIXTURE_ROOT/dependent" ]; then printf 'other-package\n'; fi ;;
    uninstall)
        [ "${HOMEBREW_NO_AUTO_UPDATE:-}" = 1 ] || exit 81
        [ "${HOMEBREW_NO_INSTALL_CLEANUP:-}" = 1 ] || exit 82
        [ "${HOMEBREW_NO_AUTOREMOVE:-}" = 1 ] || exit 83
        mode=$(/bin/cat "$FIXTURE_ROOT/package-mode")
        case "$mode" in
            fail)
                printf 'Error: Could not remove clamav keg!\n' >&2
                exit "$(/bin/cat "$FIXTURE_ROOT/package-status")" ;;
            false-success) exit 0 ;;
            success) /bin/rm "$FIXTURE_ROOT/package-installed"; /bin/rm -r "$FIXTURE_ROOT/homebrew/opt/clamav" ;;
            *) exit 99 ;;
        esac ;;
    *) exit 98 ;;
esac
'''

results = []


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def execute(root, body, first=False):
    script = root / ('first.sh' if first else 'retry.sh')
    script.write_text((fixture if first else retry_fixture) + '\n' + body + '\n')
    return subprocess.run(['/bin/bash', str(script)],
                          env=dict(os.environ, BACKEND_LIB=str(LIB), FIXTURE_ROOT=str(root)),
                          text=True, capture_output=True)


def record(name, result, expected, required=(), forbidden=(), checks=()):
    output = result.stdout + result.stderr
    issues = []
    if result.returncode != expected:
        issues.append(f'exit {result.returncode}, expected {expected}')
    issues += [f'missing {s}' for s in required if s not in output]
    issues += [f'unexpected {s}' for s in forbidden if s in output]
    issues += [description for ok, description in checks if not ok]
    results.append(dict(name=name, passed=not issues, exit_code=result.returncode, issues=issues))
    print(('PASS ' if not issues else 'FAIL ') + name + (': ' + '; '.join(issues) if issues else ''))
    if issues:
        print(output)


def make_root(name, mode='fail', status=43, body=''):
    root = Path(tempfile.mkdtemp(prefix=name + '-', dir=HERE))
    # The shared fixture writes a dummy brew first; replace it before execution.
    (root / 'fake-brew').write_text(BREW)
    (root / 'package-mode').write_text(mode)
    (root / 'package-status').write_text(str(status))
    (root / 'package-installed').touch()
    bootstrap = r'''
/bin/cp "$FIXTURE_ROOT/fake-brew" "$PREFIX/bin/brew"
/bin/chmod 700 "$PREFIX/bin/brew"
make_fixture_jobs
/bin/mkdir -p "$BASE/quarantine/one" "$BASE/quarantine/two"
printf 'sample one\000' > "$BASE/quarantine/one/same-name"
printf 'sample two\377' > "$BASE/quarantine/two/same-name"
printf 'private settings\n' > "$BASE/etc/custom.conf"
printf 'saved log\n' > "$LOGS/keep.log"
'''
    outcome = execute(root, bootstrap + '\n' + body, first=True)
    return root, outcome


PARTIAL = ('@@CLAMAV:PACKAGE:REMOVAL_FAILED', '@@CLAMAV:RESULT:PARTIAL_UNINSTALL')
NO_SUCCESS = ('@@CLAMAV:RESULT:UNINSTALLED', '@@CLAMAV:RESULT:NOT_INSTALLED',
              '@@CLAMAV:PACKAGE:REMOVED', 'FEHLER in Zeile', '@@CLAMAV:ERROR:command_failed')

for status in (1, 43):
    root, outcome = make_root('committed-failure', status=status, body='uninstall yes')
    archived = list((root / 'archives').glob('*/installation'))
    checks = [
        (len(archived) == 1, 'exactly one archive must survive'),
        (not (root / 'installation').exists(), 'committed removal was incorrectly rolled back'),
        (not list((root / 'agents').glob('*.plist')), 'owned jobs remain'),
        (not list(root.glob('loaded-*')), 'owned jobs were restarted'),
        ((root / 'package-installed').exists(), 'failed package removal changed installed state'),
        ((root / 'logs/keep.log').read_bytes() == b'saved log\n', 'log lost'),
    ]
    if archived:
        checks += [
            ((archived[0] / 'quarantine/one/same-name').read_bytes() == b'sample one\0', 'first quarantine sample lost'),
            ((archived[0] / 'quarantine/two/same-name').read_bytes() == b'sample two\xff', 'second same-name sample lost'),
            ((archived[0] / 'etc/custom.conf').read_bytes() == b'private settings\n', 'settings lost'),
        ]
    record(f'committed_failure_status_{status}', outcome, status,
           PARTIAL + ('@@CLAMAV:ARCHIVE:',), NO_SUCCESS, checks)
    before = snapshot(root / 'archives')
    retry = execute(root, 'uninstall yes')
    record(f'package_only_retry_failure_status_{status}', retry, status, PARTIAL,
           NO_SUCCESS + ('@@CLAMAV:ARCHIVE:',),
           [(snapshot(root / 'archives') == before, 'retry modified the saved archive'),
            (not (root / 'installation').exists(), 'retry recreated the installation')])
    (root / 'package-mode').write_text('success')
    retry = execute(root, 'uninstall yes')
    record(f'package_only_retry_success_after_status_{status}', retry, 0,
           ('@@CLAMAV:PACKAGE:REMOVED', '@@CLAMAV:RESULT:NOT_INSTALLED'), PARTIAL,
           [(snapshot(root / 'archives') == before, 'successful retry modified archive'),
            (not (root / 'package-installed').exists(), 'package not removed')])
    retry = execute(root, 'uninstall yes')
    record(f'already_removed_retry_after_status_{status}', retry, 0,
           ('@@CLAMAV:PACKAGE:NOT_INSTALLED', '@@CLAMAV:RESULT:NOT_INSTALLED'), PARTIAL,
           [(snapshot(root / 'archives') == before, 'idempotent retry modified archive')])

root, outcome = make_root('false-success', mode='false-success', body='uninstall yes')
record('homebrew_success_but_package_remains', outcome, 2, PARTIAL, NO_SUCCESS,
       [(len(list((root / 'archives').glob('*/installation'))) == 1, 'archive lost')])

root, outcome = make_root('successful-package-removal', mode='success', body='uninstall yes')
record('successful_managed_and_package_removal', outcome, 0,
       ('@@CLAMAV:ARCHIVE:', '@@CLAMAV:PACKAGE:REMOVED', '@@CLAMAV:RESULT:UNINSTALLED'), PARTIAL,
       [(not (root / 'package-installed').exists(), 'package not removed')])

for name, body in [
    ('dependent_blocks_removal', ': > "$FIXTURE_ROOT/dependent"; uninstall yes'),
    ('dependency_query_error_blocks_removal', ': > "$FIXTURE_ROOT/dependency-error"; uninstall yes'),
    ('foreign_use_blocks_removal', 'TEST_FOREIGN=1; uninstall yes'),
]:
    root, outcome = make_root(name, body=body)
    record(name, outcome, 2, ('@@CLAMAV:ERROR:',), PARTIAL + ('@@CLAMAV:ARCHIVE:',),
           [((root / 'installation/.owner').exists(), 'preflight failure removed installation'),
            (len(list((root / 'agents').glob('*.plist'))) == 3, 'preflight failure removed owned jobs'),
            ('brew uninstall' not in (root / 'calls').read_text(), 'preflight failure reached package removal')])

(HERE / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
