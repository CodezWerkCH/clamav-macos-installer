#!/usr/bin/env python3
"""Exercise the real Bash 3.2 install function against an isolated brew process.

No real Homebrew command, service, home directory, or preference is modified.
The fake brew enforces the current default confirmation behavior and captures
its inherited environment, including restoration after function assignments.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "src/backend/install.sh"
LIBRARY = SOURCE.read_text().rsplit('\nmain "$@"', 1)[0] + '\n'

FAKE_BREW = r'''#!/bin/bash
set -eu
if [ "${TEST_ENV_FILE_NO_ASK+x}" = x ]; then export HOMEBREW_NO_ASK="$TEST_ENV_FILE_NO_ASK"; fi
printf '%s|NO_ASK=%s|ASK=%s|NO_UPDATE=%s|NO_CLEANUP=%s\n' "$*" "${HOMEBREW_NO_ASK-unset}" "${HOMEBREW_ASK-unset}" "${HOMEBREW_NO_AUTO_UPDATE-unset}" "${HOMEBREW_NO_INSTALL_CLEANUP-unset}" >> "$FIXTURE_ROOT/calls"
case "$1" in
  update) exit "${TEST_UPDATE_RC:-0}" ;;
  list)
    if [ "$2" = --pinned ]; then
      if [ "${TEST_PINNED:-no}" = yes ]; then printf 'clamav\n'; fi
    else
      [ "${TEST_INSTALLED:-yes}" = yes ] || exit 1
      printf 'clamav 1.5.4\n'
    fi ;;
  unpin) [ "$2" = homebrew/core/clamav ] ;;
  install|upgrade)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] && [ "$2" = --formula ] && [ "$3" = homebrew/core/clamav ] || exit 95
    [ "$#" -ne 4 ] || [ "$4" = --no-ask ] || exit 95
    if [ "${HOMEBREW_NO_ASK:-}" != 1 ] && [ "${4:-}" != --no-ask ]; then
      printf 'Do you want to proceed with the upgrade? [y/n]\n'
      printf 'Invalid input. Please press y to proceed, or n to abort.\n'
      exit 96
    fi
    if [ "${TEST_PACKAGE_RC:-0}" -ne 0 ]; then printf 'Package operation refused or failed.\n' >&2; fi
    exit "${TEST_PACKAGE_RC:-0}" ;;
  outdated)
    if [ "${TEST_OUTDATED:-no}" = yes ]; then printf 'clamav\n'; fi
    exit "${TEST_OUTDATED_RC:-0}" ;;
  info) [ "$*" = "info --json=v2 --formula homebrew/core/clamav" ] || exit 97; printf '{"formulae":[{"name":"clamav","tap":"%s","versions":{"stable":"1.5.4"}}]}\n' "${TEST_TAP:-homebrew/core}" ;;
  *) printf 'Unexpected operation, including trust changes: %s\n' "$*" >&2; exit 97 ;;
esac
'''

RUNNER = r'''source "$FIXTURE_ROOT/backend.sh"
BASE="$FIXTURE_ROOT/installation"
ARCHIVES="$FIXTURE_ROOT/archives"
LOGS="$FIXTURE_ROOT/logs"
AGENTS="$FIXTURE_ROOT/agents"
PREFIX="$FIXTURE_ROOT/homebrew"
OPT="$PREFIX/opt/clamav"
legacy_rollback() { :; }
before_no_ask="${HOMEBREW_NO_ASK-unset}"
before_ask="${HOMEBREW_ASK-unset}"
install_latest_clamav
[ "${HOMEBREW_NO_ASK-unset}" = "$before_no_ask" ] || exit 98
[ "${HOMEBREW_ASK-unset}" = "$before_ask" ] || exit 98
printf 'COMPLETE:%s\n' "$EXPECTED_VERSION"
'''

CASES = [
    ("new_install_default_prompt", {"TEST_INSTALLED": "no"}, 0),
    ("upgrade_default_prompt", {}, 0),
    ("install_inherited_ask", {"TEST_INSTALLED": "no", "HOMEBREW_ASK": "1"}, 0),
    ("upgrade_inherited_ask", {"HOMEBREW_ASK": "1"}, 0),
    ("inherited_no_ask_restored", {"HOMEBREW_NO_ASK": "original-value"}, 0),
    ("inherited_ask_and_no_ask", {"HOMEBREW_ASK": "1", "HOMEBREW_NO_ASK": "0"}, 0),
    ("install_env_file_overrides_variable", {"TEST_INSTALLED": "no", "TEST_ENV_FILE_NO_ASK": "", "HOMEBREW_ASK": "1"}, 0),
    ("upgrade_env_file_overrides_variable", {"TEST_ENV_FILE_NO_ASK": "", "HOMEBREW_ASK": "1"}, 0),
    ("unpin_latest_upgrade", {"TEST_PINNED": "yes"}, 0),
    ("update_failure_stops_package", {"TEST_UPDATE_RC": "41"}, 41),
    ("install_failure_propagates", {"TEST_INSTALLED": "no", "TEST_PACKAGE_RC": "42"}, 42),
    ("upgrade_failure_propagates", {"TEST_PACKAGE_RC": "43"}, 43),
    ("trust_refusal_still_fails", {"TEST_PACKAGE_RC": "77"}, 77),
    ("freshness_failure_still_fails", {"TEST_OUTDATED_RC": "9"}, 2),
    ("still_outdated_still_fails", {"TEST_OUTDATED": "yes"}, 2),
    ("foreign_source_still_fails", {"TEST_TAP": "other/tap"}, 2),
    ("old_behavior_reproduces_prompt", {"REGRESSION": "yes"}, 96),
]

results = []
for name, options, expected in CASES:
    root = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=HERE))
    (root / "installation/run").mkdir(parents=True)
    brew = root / "homebrew/bin/brew"
    brew.parent.mkdir(parents=True)
    brew.write_text(FAKE_BREW)
    brew.chmod(0o700)
    source = LIBRARY.replace('HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1', 'HOMEBREW_NO_AUTO_UPDATE=1').replace('"$FORMULA" --no-ask', '"$FORMULA"') if options.get("REGRESSION") else LIBRARY
    (root / "backend.sh").write_text(source)
    (root / "test.sh").write_text(RUNNER)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("HOMEBREW_", "TEST_"))}
    env.update(options, FIXTURE_ROOT=str(root))
    run = subprocess.run(["/bin/bash", str(root / "test.sh")], env=env, text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    output = run.stdout
    (root / "output.txt").write_text(output)
    calls = (root / "calls").read_text().splitlines()
    package_calls = [line for line in calls if line.startswith(("install ", "upgrade "))]
    errors = []
    if run.returncode != expected:
        errors.append(f"exit {run.returncode}, expected {expected}")
    if expected == 0 and "COMPLETE:1.5.4" not in output:
        errors.append("missing verified stable version")
    if expected != 0 and "COMPLETE:" in output:
        errors.append("false success")
    if options.get("TEST_UPDATE_RC"):
        if package_calls:
            errors.append("package modified after metadata refresh failed")
    elif len(package_calls) != 1:
        errors.append(f"expected exactly one package operation, got {len(package_calls)}")
    if not options.get("REGRESSION"):
        package_no_ask = options.get("TEST_ENV_FILE_NO_ASK", "1")
        if any(f"|NO_ASK={package_no_ask}|" not in line or " --no-ask|" not in line for line in package_calls):
            errors.append("package confirmation not scoped correctly")
        if "Do you want to proceed" in output:
            errors.append("interactive confirmation leaked")
    elif "Do you want to proceed" not in output:
        errors.append("regression did not reproduce original prompt")
    original_no_ask = options.get("TEST_ENV_FILE_NO_ASK", options.get("HOMEBREW_NO_ASK", "unset"))
    for line in calls:
        if not line.startswith(("install ", "upgrade ")) and f"|NO_ASK={original_no_ask}|" not in line:
            errors.append("no-ask changed a non-package command")
    if options.get("TEST_PACKAGE_RC") or options.get("REGRESSION"):
        if any(line.startswith(("outdated ", "info ")) for line in calls):
            errors.append("verification ran after package failure")
    if any(line.startswith(("trust ", "untap ")) for line in calls):
        errors.append("tap trust changed")
    results.append({"name": name, "passed": not errors, "exit": run.returncode, "errors": errors})

(HERE / "results.json").write_text(json.dumps(results, indent=2) + '\n')
for result in results:
    print(("PASS " if result["passed"] else "FAIL ") + result["name"] + (": " + "; ".join(result["errors"]) if result["errors"] else ""))
raise SystemExit(0 if all(item["passed"] for item in results) else 1)
