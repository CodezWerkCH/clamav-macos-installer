#!/usr/bin/env python3
"""Isolated tests for the explicit GUI-only package repair action.

The helper, privilege request, Homebrew, processes, and launchd are mocked.
No real elevated process, ownership change, service, or package is involved.
"""
from pathlib import Path
import ast
import json
import os
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / 'src/backend/install.sh'
LIBRARY = SOURCE.read_text().rsplit('\nmain "$@"', 1)[0] + '\n'
tree = ast.parse((HERE.parent / 'backend-v11-tests/test_backend.py').read_text())
FIXTURE = next(ast.literal_eval(node.value) for node in tree.body
               if isinstance(node, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'PREAMBLE' for t in node.targets))
start = FIXTURE.index('\nbrew_cmd() {')
end = FIXTURE.index('\nlaunchctl_cmd() {', start)
FIXTURE = FIXTURE[:start] + FIXTURE[end:]

MOCKS = r'''
/bin/cp "$FIXTURE_ROOT/fake-brew" "$PREFIX/bin/brew"
/bin/chmod 700 "$PREFIX/bin/brew"
/bin/mkdir -p "$PREFIX/Cellar/clamav/1.5.4/bin" "$FIXTURE_ROOT/archives"
printf 'untouched sample\377' > "$BASE/quarantine/sample"
/bin/mv "$BASE" "$FIXTURE_ROOT/archives/existing-installation"
printf 'retained log\n' > "$LOGS/keep.log"
: > "$FIXTURE_ROOT/package-installed"
package_process_listing() {
    [ ! -f "$FIXTURE_ROOT/process-read-error" ] || return 63
    if [ -f "$FIXTURE_ROOT/process-active" ]; then printf '/opt/homebrew/Cellar/clamav/1.5.4/sbin/clamd\n'; fi
    printf '/bin/bash\n'
}
launchctl_cmd() {
    printf 'launchctl %s\n' "$*" >> "$CALLS"
    [ "$1" = print ] || return 99
    case "$2" in
        "$DOMAIN") return 0 ;;
        system)
            [ ! -f "$FIXTURE_ROOT/system-read-error" ] || return 64
            if [ -f "$FIXTURE_ROOT/system-listed" ]; then printf '42 = sh.brew.clamav\n'; fi
            return 0 ;;
        system/homebrew.mxcl.clamav) [ -f "$FIXTURE_ROOT/system-registered" ] ;;
        user/0/sh.brew.clamav) [ -f "$FIXTURE_ROOT/root-registered" ] ;;
        "$DOMAIN/$LABEL.clamd") [ -f "$FIXTURE_ROOT/own-registered" ] ;;
        *) return 1 ;;
    esac
}
package_repair_sudo() {
    printf 'sudo %s\n' "$*" >> "$CALLS"
    [ ! -f "$FIXTURE_ROOT/sudo-denied" ] || return 71
    [ ! -f "$FIXTURE_ROOT/sudo-cancelled" ] || return 130
    "$@"
}
'''

BREW = r'''#!/bin/bash
set -eu
printf 'brew %s\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$1" in
    --prefix) printf '%s/homebrew\n' "$FIXTURE_ROOT" ;;
    list) if [ -f "$FIXTURE_ROOT/real-archive" ] && [ ! -d "$FIXTURE_ROOT/homebrew/Cellar/clamav" ]; then exit 1; fi; [ -f "$FIXTURE_ROOT/package-installed" ] || exit 1; printf 'clamav 1.5.4\n' ;;
    uses)
        if [ -f "$FIXTURE_ROOT/dependency-read-error" ]; then exit 72; fi
        if [ -f "$FIXTURE_ROOT/dependent" ]; then printf 'other-package\n'; fi ;;
    uninstall)
        [ ! -f "$FIXTURE_ROOT/package-failure" ] || exit 43
        /bin/rm "$FIXTURE_ROOT/package-installed"
        if [ -e "$FIXTURE_ROOT/homebrew/opt/clamav" ]; then /bin/rm -r "$FIXTURE_ROOT/homebrew/opt/clamav"; fi
        if [ ! -f "$FIXTURE_ROOT/retain-keg" ]; then
            # Only isolated test fixture paths are deleted by this fake brew.
            /bin/rm -r "$FIXTURE_ROOT/homebrew/Cellar/clamav"
        fi ;;
    *) exit 98 ;;
esac
'''

HELPER = r'''#!/bin/bash
set -eu
printf 'helper %s\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$1" in
    --check)
        [ ! -f "$FIXTURE_ROOT/reject-$2" ] || exit 65
        if [ -f "$FIXTURE_ROOT/malformed-helper-reply" ]; then printf 'unexpected answer\n'; exit 0; fi
        if [ -f "$FIXTURE_ROOT/no-repair" ]; then printf 'REPAIR:NOT_NEEDED\n'; else printf 'REPAIR:NEEDED\n'; fi ;;
    --repair) printf 'REPAIR:COMPLETE\n' ;;
    *) exit 99 ;;
esac
'''

CASES = [
    ('orphan_after_brew_failure', ': > "$FIXTURE_ROOT/package-failure"', 0, True, True),
    ('orphan_after_brew_success', ': > "$FIXTURE_ROOT/retain-keg"', 0, True, True),
    ('orphan_not_listed', '/bin/rm "$FIXTURE_ROOT/package-installed"', 0, True, False),
    ('repair_then_uninstall', '', 0, True, True),
    ('healthy_keg_no_sudo', ': > "$FIXTURE_ROOT/no-repair"', 0, False, True),
    ('own_directory_blocks', '/bin/mkdir "$BASE"', 2, False, False),
    ('own_job_file_blocks', ': > "$AGENTS/$LABEL.scan.plist"', 2, False, False),
    ('own_loaded_job_blocks', ': > "$FIXTURE_ROOT/own-registered"', 2, False, False),
    ('process_read_error_blocks', ': > "$FIXTURE_ROOT/process-read-error"', 2, False, False),
    ('active_scanner_blocks', ': > "$FIXTURE_ROOT/process-active"', 2, False, False),
    ('system_read_error_blocks', ': > "$FIXTURE_ROOT/system-read-error"', 2, False, False),
    ('historical_unloaded_label_does_not_block', ': > "$FIXTURE_ROOT/system-listed"', 0, True, True),
    ('system_registered_job_blocks', ': > "$FIXTURE_ROOT/system-registered"', 2, False, False),
    ('root_registered_job_blocks', ': > "$FIXTURE_ROOT/root-registered"', 2, False, False),
    ('foreign_jobs_block', 'TEST_FOREIGN=1', 2, False, False),
    ('dependent_blocks', ': > "$FIXTURE_ROOT/dependent"', 2, False, False),
    ('dependency_read_error_blocks', ': > "$FIXTURE_ROOT/dependency-read-error"', 2, False, False),
    ('symlink_keg_blocks', '/bin/ln -s "$FIXTURE_ROOT/archives" "$PREFIX/Cellar/clamav/1.6.0"', 2, False, False),
    ('hidden_entry_blocks', ': > "$PREFIX/Cellar/clamav/.unexpected"', 2, False, False),
    ('nonnumeric_version_blocks', '/bin/mkdir "$PREFIX/Cellar/clamav/malicious"', 2, False, False),
    ('all_versions_checked_before_sudo', '/bin/mkdir "$PREFIX/Cellar/clamav/1.6.0"; : > "$FIXTURE_ROOT/reject-1.6.0"', 2, False, False),
    ('helper_symlink_blocks', '/bin/mv "$HELPER_FILE" "$FIXTURE_ROOT/real-helper"; /bin/ln -s "$FIXTURE_ROOT/real-helper" "$HELPER_FILE"', 2, False, False),
    ('helper_writable_by_others_blocks', '/bin/chmod 777 "$HELPER_FILE"', 2, False, False),
    ('standalone_script_cannot_repair', '', 2, False, False),
    ('malformed_helper_reply_blocks', ': > "$FIXTURE_ROOT/malformed-helper-reply"', 2, False, False),
    ('admin_denied_keeps_archive', ': > "$FIXTURE_ROOT/sudo-denied"', 71, True, False),
    ('admin_cancelled_keeps_archive', ': > "$FIXTURE_ROOT/sudo-cancelled"', 130, True, False),
    ('brew_failure_after_repair', ': > "$FIXTURE_ROOT/package-failure"', 43, True, True),
    ('residual_keg_is_partial', ': > "$FIXTURE_ROOT/retain-keg"', 2, True, True),
    ('all_versions_repaired', '/bin/mkdir "$PREFIX/Cellar/clamav/1.5.4_1"', 0, True, True),
]

results = []
for name, body, expected, sudo_expected, removal_expected in CASES:
    root = Path(tempfile.mkdtemp(prefix=name + '-', dir=HERE))
    resources = root / 'Fixture Installer.app/Contents/Resources'
    mac = resources.parent / 'MacOS'
    resources.mkdir(parents=True)
    mac.mkdir()
    library = resources / 'install.sh'
    if name == 'standalone_script_cannot_repair':
        library = root / 'standalone.sh'
    library.write_text(LIBRARY)
    helper = mac / 'package-repair'
    helper.write_text(HELPER)
    helper.chmod(0o755)
    (root / 'fake-brew').write_text(BREW)
    if name.startswith('orphan_'):
        archiver = mac / 'package-archive'
        real = HERE.parent / 'package-archive-test'
        archiver.write_text('#!/bin/bash\nexec "' + str(real) + '" "$FIXTURE_ROOT/homebrew" "$FIXTURE_ROOT"\n')
        archiver.chmod(0o755)
        body += '\n: > "$FIXTURE_ROOT/real-archive"\n/bin/mkdir -p "$PREFIX/Cellar/clamav/1.5.4/.brew"\n: > "$PREFIX/Cellar/clamav/1.5.4/.brew/clamav.rb"\n/bin/rm -r "$OPT"\n'
    script = root / 'run.sh'
    script.write_text(FIXTURE + MOCKS + '\n' + body + '\nrepair_uninstall_package\n')
    outcome = subprocess.run(['/bin/bash', str(script)], text=True, capture_output=True,
                             env=dict(os.environ, BACKEND_LIB=str(library), FIXTURE_ROOT=str(root), HELPER_FILE=str(helper)))
    output = outcome.stdout + outcome.stderr
    calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
    issues = []
    if outcome.returncode != expected:
        issues.append(f'exit {outcome.returncode}, expected {expected}')
    if ('\nsudo ' in '\n' + calls) != sudo_expected:
        issues.append('wrong privilege request state')
    if ('brew uninstall --formula homebrew/core/clamav' in calls) != removal_expected:
        issues.append('wrong package removal state')
    if (root / 'archives/existing-installation/quarantine/sample').read_bytes() != b'untouched sample\xff':
        issues.append('existing archive changed')
    if (root / 'logs/keep.log').read_bytes() != b'retained log\n':
        issues.append('existing log changed')
    if 'sudo brew' in calls or 'sudo /opt/homebrew/bin/brew' in calls:
        issues.append('Homebrew was elevated')
    if name in ('admin_denied_keeps_archive', 'admin_cancelled_keeps_archive', 'brew_failure_after_repair', 'residual_keg_is_partial'):
        if '@@CLAMAV:RESULT:PARTIAL_UNINSTALL' not in output:
            issues.append('missing partial result')
    elif expected == 0:
        if '@@CLAMAV:RESULT:NOT_INSTALLED' not in output:
            issues.append('missing successful result')
        if '@@CLAMAV:RESULT:PARTIAL_UNINSTALL' in output:
            issues.append('unexpected partial result')
    if name == 'all_versions_repaired':
        if calls.index('helper --check 1.5.4_1') > calls.index('sudo '):
            issues.append('privilege request occurred before all version checks')
        if 'helper --repair 1.5.4_1' not in calls:
            issues.append('second version not repaired')
    results.append(dict(name=name, passed=not issues, exit_code=outcome.returncode, issues=issues))
    (root / 'output.txt').write_text(output)
    print(('PASS ' if not issues else 'FAIL ') + name + (': ' + '; '.join(issues) if issues else ''))
    if issues:
        print(output)

(HERE / 'repair-results.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
