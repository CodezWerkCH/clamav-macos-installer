#!/usr/bin/env python3
"""Isolated live-output tests of the production initial-signature pipeline.

Use the real macOS Bash 3.2 and tee, with a fake freshclam executable only.
No HOME changes, networking, Homebrew operations, or launchd operations.
The fake updater waits for Python to acknowledge receipt of its first output,
so buffering until completion would fail the test instead of appearing to pass.
"""
from pathlib import Path
import json
import os
import selectors
import shlex
import stat
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "src/backend/install.sh"
LIB = HERE / "backend-functions.sh"
LIB.write_text(SOURCE.read_text().rsplit('\nmain "$@"', 1)[0] + '\n')

FAKE_FRESHCLAM = r'''#!/bin/bash
printf 'Signature download started\n'
printf 'Updater diagnostic before completion\n' >&2
for ((tick=0; tick<100; tick++)); do
    if [ -f "$FIXTURE_RELEASE" ]; then
        printf 'Signature verification finished\n'
        exit "$FIXTURE_EXIT"
    fi
    /bin/sleep 0.05
done
printf 'Test timed out waiting for live-output acknowledgement\n' >&2
exit 97
'''


def run_case(name, fresh_status, tee_failure, expected):
    fixture = Path(tempfile.mkdtemp(prefix=name + '-', dir=HERE))
    (fixture / 'opt/bin').mkdir(parents=True)
    updater = fixture / 'opt/bin/freshclam'
    updater.write_text(FAKE_FRESHCLAM)
    updater.chmod(0o700)
    report = fixture / 'install-update.log'
    if tee_failure:
        # The real tee cannot open a directory as its log output, but still
        # forwards standard output. This exercises both pipeline statuses.
        report.mkdir()
    else:
        report.touch(mode=0o600)
    runner = fixture / 'run.sh'
    runner.write_text(f'''#!/bin/bash
source {shlex.quote(str(LIB))}
BASE={shlex.quote(str(fixture / 'installation'))}
OPT={shlex.quote(str(fixture / 'opt'))}
FRESHCONF={shlex.quote(str(fixture / 'freshclam.conf'))}
initial_signature_update {shlex.quote(str(report))}
printf 'CONTINUED_TO_JOBS\\n'
''')
    environment = dict(os.environ, FIXTURE_RELEASE=str(fixture / 'release'),
                       FIXTURE_EXIT=str(fresh_status))
    process = subprocess.Popen(['/bin/bash', str(runner)], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=environment)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    transcript = b''
    live = False
    started = time.monotonic()
    try:
        while time.monotonic() - started < 4:
            if selector.select(0.1):
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    break
                transcript += chunk
            if b'Signature download started\n' in transcript:
                assert process.poll() is None, 'Updater already exited before live output'
                assert b'Signature verification finished\n' not in transcript
                live = True
                (fixture / 'release').touch()
                break
        assert live, 'No visible output before updater completion'
        rest, _ = process.communicate(timeout=5)
        transcript += rest
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    (fixture / 'output.txt').write_bytes(transcript)
    assert process.returncode == expected, (name, process.returncode, transcript)
    assert transcript.count(b'Signature download started\n') == 1, 'Output replayed'
    assert transcript.count(b'Signature verification finished\n') == 1, 'Output replayed'
    assert b'Updater diagnostic before completion\n' in transcript, 'stderr lost'
    assert (b'CONTINUED_TO_JOBS\n' in transcript) == (expected == 0), transcript
    if not tee_failure:
        assert report.read_bytes() == (b'Signature download started\n'
                                       b'Updater diagnostic before completion\n'
                                       b'Signature verification finished\n')
        assert stat.S_IMODE(report.stat().st_mode) == 0o600, 'Log permission changed'
    if fresh_status:
        assert f'freshclam Status {fresh_status}'.encode() in transcript
        assert b'@@CLAMAV:ERROR:' in transcript
    if tee_failure and not fresh_status:
        assert b'Protokoll konnte nicht vollstaendig geschrieben werden' in transcript
    return {'case': name, 'freshclam_status': fresh_status, 'tee_failure': tee_failure,
            'exit_status': process.returncode, 'received_while_running': live,
            'fixture': str(fixture)}


results = [run_case('successful_live_update', 0, False, 0),
           run_case('failed_live_update', 52, False, 52),
           run_case('log_failure_blocks_jobs', 0, True, 1),
           run_case('updater_failure_survives_log_failure', 53, True, 53)]
(HERE / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps({'passed': len(results), 'cases': [r['case'] for r in results]}))
