#!/usr/bin/env python3
"""Bash 3.2 backend regression tests. Homebrew and launchd are always mocked.

No HOME override and no real service/package changes. All fixture data lives
inside this test directory and all shell entrypoints operate on overridden paths.
"""
from pathlib import Path
import json
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "src/backend/install.sh"
LIB = HERE / "backend-functions.sh"
LIB.write_text(SOURCE.read_text().rsplit('\nmain "$@"', 1)[0] + '\n')
PREAMBLE = r'''
# ClamAV-Automatik-managed-v1
source "$BACKEND_LIB"
BASE="$FIXTURE_ROOT/installation"
ARCHIVES="$FIXTURE_ROOT/archives"
MANAGEMENT_LOCK="$FIXTURE_ROOT/management.lock"
LOGS="$FIXTURE_ROOT/logs"
AGENTS="$FIXTURE_ROOT/agents"
PREFIX="$FIXTURE_ROOT/homebrew"
OPT="$PREFIX/opt/clamav"
CONF="$BASE/etc/clamd.conf"
FRESHCONF="$BASE/etc/freshclam.conf"
INSTALLED="$BASE/bin/clamav-automatik.sh"
DOMAIN=gui/mock
CALLS="$FIXTURE_ROOT/calls"
TEST_INSTALLED=yes
TEST_PINNED=no
TEST_FOREIGN=0
TEST_DEPENDENTS=''
TEST_TAP=homebrew/core
TEST_VERSION=1.5.4
TEST_STABLE=1.5.4
TEST_OUTDATED=''
TEST_OUTDATED_RC=0
TEST_FAIL=''
TEST_BAD_SOURCE=no
TEST_ASYNC=''
STOP_TICKS=0
/bin/mkdir -p "$BASE/bin" "$BASE/run" "$BASE/etc" "$BASE/db" "$BASE/backups" "$BASE/quarantine" "$LOGS" "$AGENTS" "$OPT/bin" "$OPT/sbin" "$PREFIX/bin"
printf '%s\n' "$MARKER" > "$BASE/.owner"
printf '#!/bin/bash\nexit 0\n' > "$PREFIX/bin/brew"
/bin/chmod 700 "$PREFIX/bin/brew"
printf '#!/bin/bash\nif [ "$1" = --version ]; then printf "ClamAV 1.5.4/mock\\n"; fi\nexit 0\n' > "$OPT/bin/clamdscan"
printf '#!/bin/bash\nexit 0\n' > "$OPT/bin/freshclam"
printf '#!/bin/bash\nexit 0\n' > "$OPT/sbin/clamd"
/bin/chmod 700 "$OPT/bin/clamdscan" "$OPT/bin/freshclam" "$OPT/sbin/clamd"
/bin/cp "$OPT/bin/clamdscan" "$OPT/bin/clamscan"
notify_user() { :; }
shutdown_pause() {
    STOP_TICKS=$((STOP_TICKS+1))
    printf '%s\n' "$STOP_TICKS" > "$FIXTURE_ROOT/stop-ticks"
    case "$TEST_ASYNC" in
        job|both|cancel) if [ "$STOP_TICKS" -ge 3 ]; then /bin/rm -f "$FIXTURE_ROOT/loaded-clamd"; fi ;;
        recovery) if [ "$STOP_TICKS" -ge 153 ]; then /bin/rm -f "$FIXTURE_ROOT/loaded-clamd"; fi ;;
    esac
    if [ "$TEST_ASYNC" = cancel ] && [ "$STOP_TICKS" -eq 1 ]; then interrupted; fi
    return 0
}
job_pid_alive() {
    case "$TEST_ASYNC" in
        job) [ "$STOP_TICKS" -lt 3 ]; return $? ;;
        pid|both|cancel|failed) [ "$STOP_TICKS" -lt 5 ]; return $? ;;
        timeout|pid_timeout) return 0 ;;
        recovery) [ "$STOP_TICKS" -lt 155 ]; return $? ;;
    esac
    return 1
}
foreign_jobs() { return "$TEST_FOREIGN"; }
brew_cmd() {
    printf 'brew %s\n' "$*" >> "$CALLS"
    case "$1" in
        --prefix) printf '%s\n' "$PREFIX" ;;
        update) [ "$TEST_FAIL" != update ] ;;
        list)
            if [ "$2" = --pinned ]; then
                if [ "$TEST_PINNED" = yes ]; then printf 'clamav\n'; fi
            else
                [ "$TEST_INSTALLED" = yes ] || return 1
                printf 'clamav %s\n' "$TEST_VERSION"
            fi ;;
        unpin) TEST_PINNED=no ;;
        install|upgrade)
            [ "$TEST_FAIL" != "$1" ] || return 42
            TEST_INSTALLED=yes ;;
        outdated)
            if [ -n "$TEST_OUTDATED" ]; then printf '%s\n' "$TEST_OUTDATED"; fi
            return "$TEST_OUTDATED_RC" ;;
        info) printf '{"formulae":[{"name":"clamav","tap":"%s","versions":{"stable":"%s"}}]}\n' "$TEST_TAP" "$TEST_STABLE" ;;
        uses) if [ -n "$TEST_DEPENDENTS" ]; then printf '%s\n' "$TEST_DEPENDENTS"; fi ;;
        uninstall) [ "$TEST_FAIL" != uninstall ] || return 43; TEST_INSTALLED=no; /bin/rm -r "$OPT" ;;
        *) printf 'Unexpected brew command\n' >&2; return 99 ;;
    esac
}
launchctl_cmd() {
    local kind source
    printf 'launchctl %s\n' "$*" >> "$CALLS"
    case "$1" in
        print)
            [ "$2" != "$DOMAIN" ] || return 0
            kind=${2##*.}
            [ -f "$FIXTURE_ROOT/loaded-$kind" ] || return 1
            source="$AGENTS/$LABEL.$kind.plist"
            [ "$TEST_BAD_SOURCE" != yes ] || source="$FIXTURE_ROOT/foreign.plist"
            printf '\tpath = %s\n\tstate = running\n' "$source"
            if [ "$kind" = clamd ] && [ -n "$TEST_ASYNC" ]; then printf '\tpid = 99999999\n'; fi ;;
        enable) : ;;
        bootstrap)
            kind=${3##*.automatik.}; kind=${kind%.plist}
            : > "$FIXTURE_ROOT/loaded-$kind" ;;
        bootout)
            kind=${2##*.}
            [ "$TEST_FAIL" != "bootout-$kind" ] || return 44
            if [ "$kind" = clamd ]; then
                case "$TEST_ASYNC" in job|both|cancel|recovery|timeout) return 0 ;; esac
            fi
            /bin/rm -f "$FIXTURE_ROOT/loaded-$kind"
            [ "$TEST_ASYNC" != failed ] || return 44 ;;
        *) printf 'Unexpected launchctl command\n' >&2; return 99 ;;
    esac
}
make_fixture_jobs() {
    local kind
    for kind in clamd update scan; do
        make_plist "$kind" "$AGENTS/$LABEL.$kind.plist"
        : > "$FIXTURE_ROOT/loaded-$kind"
    done
}
'''

CASES = [
    ("managed_async_job", 'make_fixture_jobs; TEST_ASYNC=job; stop_job clamd restore', 0, ["launchctl bootout"], ["launchctl bootstrap"]),
    ("managed_async_pid", 'make_fixture_jobs; TEST_ASYNC=pid; stop_job clamd restore', 0, ["launchctl bootout"], ["launchctl bootstrap"]),
    ("managed_async_both", 'make_fixture_jobs; TEST_ASYNC=both; stop_job clamd restore', 0, ["launchctl bootout"], ["launchctl bootstrap"]),
    ("managed_timeout", 'make_fixture_jobs; TEST_ASYNC=timeout; stop_job clamd restore', 2, ["launchctl bootout"], ["launchctl bootstrap"]),
    ("managed_pid_timeout", 'make_fixture_jobs; TEST_ASYNC=pid_timeout; stop_job clamd restore', 2, ["launchctl bootout"], ["launchctl bootstrap"]),
    ("managed_cancel_wait", 'make_fixture_jobs; TEST_ASYNC=cancel; stop_job clamd restore', 130, ["launchctl bootout", "launchctl bootstrap"], []),
    ("managed_timeout_recovery", 'make_fixture_jobs; TEST_ASYNC=recovery; stop_job clamd restore', 2, ["launchctl bootout", "launchctl bootstrap"], []),
    ("managed_failed_stop_disappears", 'make_fixture_jobs; TEST_ASYNC=failed; stop_job clamd restore', 44, ["launchctl bootout", "launchctl bootstrap"], []),
    ("new_install", "TEST_INSTALLED=no; install_latest_clamav", 0, ["brew update", "brew install --formula homebrew/core/clamav"], []),
    ("upgrade_and_unpin", "TEST_PINNED=yes; install_latest_clamav", 0, ["brew unpin homebrew/core/clamav", "brew upgrade --formula homebrew/core/clamav"], []),
    ("update_failure", "TEST_FAIL=update; install_latest_clamav", 1, [], ["brew upgrade", "brew install"]),
    ("upgrade_failure", "TEST_FAIL=upgrade; install_latest_clamav", 42, [], ["brew outdated"]),
    ("outdated_is_fatal", "TEST_OUTDATED=clamav; install_latest_clamav", 2, [], []),
    ("outdated_query_failure", "TEST_OUTDATED_RC=9; install_latest_clamav", 2, [], []),
    ("foreign_tap_is_fatal", "TEST_TAP=someone/custom; install_latest_clamav", 2, [], []),
    ("active_version_mismatch", "TEST_STABLE=1.6.0; setup no", 2, [], ["launchctl bootout", "launchctl bootstrap"]),
    ("unchanged_plist_restarts_daemon", 'setup no; : > "$CALLS"; setup no', 0, ["launchctl bootout gui/mock/local.clamav.automatik.clamd", "launchctl bootstrap gui/mock"], ["launchctl bootout gui/mock/local.clamav.automatik.scan", "launchctl bootout gui/mock/local.clamav.automatik.update"]),
    ("default_uninstall_archives", 'make_fixture_jobs; printf "payload" > "$BASE/quarantine/same-name"; printf "logs" > "$LOGS/keep.log"; uninstall no', 0, ["launchctl bootout gui/mock/local.clamav.automatik.clamd"], ["brew uninstall"]),
    ("repeated_uninstall", 'make_fixture_jobs; uninstall no; uninstall no', 0, [], ["brew uninstall"]),
    ("package_uninstall", 'make_fixture_jobs; uninstall yes', 0, ["brew uses --installed --recursive homebrew/core/clamav", "brew uninstall --formula homebrew/core/clamav"], ["--force", "--ignore-dependencies", "brew autoremove"]),
    ("foreign_use_blocks_package", 'make_fixture_jobs; TEST_FOREIGN=1; uninstall yes', 2, [], ["launchctl bootout", "brew uninstall"]),
    ("dependents_block_package", 'make_fixture_jobs; TEST_DEPENDENTS=other-package; uninstall yes', 2, [], ["launchctl bootout", "brew uninstall"]),
    ("foreign_job_collision", 'make_fixture_jobs; printf "foreign" > "$AGENTS/$LABEL.scan.plist"; uninstall no', 2, [], ["launchctl bootout"]),
    ("symlink_job_refused", 'make_fixture_jobs; /bin/mv "$AGENTS/$LABEL.scan.plist" "$FIXTURE_ROOT/other.plist"; /bin/ln -s "$FIXTURE_ROOT/other.plist" "$AGENTS/$LABEL.scan.plist"; uninstall no', 2, [], ["launchctl bootout"]),
    ("foreign_loaded_source", 'make_fixture_jobs; TEST_BAD_SOURCE=yes; uninstall no', 2, [], ["launchctl bootout"]),
    ("stop_failure_restores_jobs", 'make_fixture_jobs; TEST_FAIL=bootout-clamd; uninstall no', 44, ["launchctl bootstrap gui/mock"], ["brew uninstall"]),
    ("package_removal_failure_preserves_archive", 'make_fixture_jobs; TEST_FAIL=uninstall; uninstall yes', 43, ["brew uninstall"], []),
    ("update_failure_keeps_live_daemon", 'make_fixture_jobs; TEST_FAIL=update; setup no', 1, [], ["launchctl bootout", "launchctl bootstrap"]),
    ("management_lock_survives_archive", r'''make_fixture_jobs
remove_package() {
    [ ! -e "$BASE" ] || die 'Test expected archived installation'
    local rc=0
    /bin/bash -c 'exec 7>>"$1"; /usr/bin/lockf -s -t 0 7' _ "$MANAGEMENT_LOCK" || rc=$?
    [ "$rc" = 75 ] || die "Concurrent management lock was not blocked: $rc"
}
uninstall yes''', 0, [], ["brew uninstall"]),
    ("symlink_management_lock_refused", 'make_fixture_jobs; /bin/ln -s "$FIXTURE_ROOT/other-lock" "$MANAGEMENT_LOCK"; uninstall no', 2, [], ["launchctl bootout", "brew uninstall"]),
]

results = []
for name, body, expected, required, forbidden in CASES:
    root = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=HERE))
    script = root / "test.sh"
    script.write_text(PREAMBLE + '\n' + body + '\n')
    import os
    env = dict(os.environ, BACKEND_LIB=str(LIB), FIXTURE_ROOT=str(root))
    result = subprocess.run(["/bin/bash", str(script)], env=env, text=True, capture_output=True)
    calls = (root / "calls").read_text() if (root / "calls").exists() else ''
    issues = []
    if result.returncode != expected:
        issues.append(f"exit {result.returncode}, expected {expected}")
    if expected == 0 and '@@CLAMAV:ERROR:' in result.stdout + result.stderr:
        issues.append('successful operation emitted an error marker')
    issues += [f"missing call {s}" for s in required if s not in calls]
    issues += [f"unexpected call {s}" for s in forbidden if s in calls]
    if name.startswith('managed_'):
        ticks = int((root / 'stop-ticks').read_text())
        expected_ticks = {'managed_async_job': 3, 'managed_async_pid': 5, 'managed_async_both': 5, 'managed_timeout': 300, 'managed_pid_timeout': 300, 'managed_cancel_wait': 5, 'managed_timeout_recovery': 155, 'managed_failed_stop_disappears': 5}[name]
        if ticks != expected_ticks: issues.append(f'wrong number of wait iterations: {ticks}, expected {expected_ticks}')
        if not (root / 'installation/.owner').exists(): issues.append('installation was not preserved')
        if len(list((root / 'agents').glob('*.plist'))) != 3: issues.append('job definitions not preserved')
        expected_loaded = name not in ('managed_async_job', 'managed_async_pid', 'managed_async_both', 'managed_pid_timeout')
        if (root / 'loaded-clamd').exists() != expected_loaded: issues.append('wrong daemon loaded state')
    if name == "default_uninstall_archives":
        payloads = list((root / 'archives').glob('*/installation/quarantine/same-name'))
        if len(payloads) != 1 or payloads[0].read_text() != 'payload': issues.append('quarantine payload not preserved')
        if (root / 'logs/keep.log').read_text() != 'logs': issues.append('logs not preserved')
        if (root / 'installation').exists(): issues.append('installation still present')
        if list((root / 'agents').glob('*.plist')): issues.append('owned jobs still present')
    if name in ('foreign_use_blocks_package', 'dependents_block_package', 'stop_failure_restores_jobs', 'update_failure_keeps_live_daemon'):
        if not (root / 'installation/.owner').exists(): issues.append('installation was not preserved')
        if len(list((root / 'agents').glob('*.plist'))) != 3: issues.append('job definitions not preserved')
    if name == 'stop_failure_restores_jobs' and len(list(root.glob('loaded-*'))) != 3:
        issues.append('previously active jobs not restored')
    if name == 'package_removal_failure_preserves_archive' and not list((root / 'archives').glob('*/installation/.owner')):
        issues.append('archive lost on package error')
    if name == 'repeated_uninstall' and '@@CLAMAV:RESULT:NOT_INSTALLED' not in result.stdout:
        issues.append('second uninstall not idempotent')
    record = {"name": name, "passed": not issues, "issues": issues, "exit_code": result.returncode}
    results.append(record)
    (root / 'output.txt').write_text(result.stdout + result.stderr)
    print(('PASS ' if not issues else 'FAIL ') + name + (': ' + '; '.join(issues) if issues else ''))
    if issues: print(result.stdout + result.stderr)

(HERE / 'test-results.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
