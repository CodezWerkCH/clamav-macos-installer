#!/usr/bin/env python3
"""Isolated PTY bridge acceptance tests; no ClamAV/Homebrew/system changes."""
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
import unittest

HERE = Path(__file__).resolve().parent
BRIDGE = HERE / "pty-bridge"


class Child:
    def __init__(self, *args, env=None):
        self.process = subprocess.Popen(
            [str(BRIDGE), *args], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ, "out")
        self.selector.register(self.process.stderr, selectors.EVENT_READ, "control")
        self.out = bytearray()
        self.control = bytearray()

    def pump(self, duration=0.1):
        for key, _ in self.selector.select(duration):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.selector.unregister(key.fileobj)
            else:
                getattr(self, key.data).extend(data)

    def until(self, marker, stream="out", timeout=5):
        deadline = time.monotonic() + timeout
        while marker not in getattr(self, stream):
            if time.monotonic() >= deadline:
                raise AssertionError("Expected marker was not received")
            self.pump()

    def send(self, value):
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def finish(self, timeout=10):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None or self.selector.get_map():
            if time.monotonic() >= deadline:
                self.process.kill()
                raise AssertionError("Bridge did not finish before timeout")
            self.pump()
        return self.process.wait()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.finish()
            except Exception:
                self.process.kill()
                self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream and not stream.closed:
                stream.close()
        self.selector.close()


class BridgeTests(unittest.TestCase):
    def child(self, *args, env=None):
        child = Child(*args, env=env)
        self.addCleanup(child.close)
        return child

    def test_all_child_standard_descriptors_are_ttys(self):
        c = self.child("/bin/bash", "-c", "[[ -t 0 && -t 1 && -t 2 ]] && printf TTY_OK")
        self.assertEqual(c.finish(), 0)
        self.assertIn(b"TTY_OK", c.out)

    def test_secure_password_input_and_echo_status(self):
        secret = b"fixture-secret-915823"
        c = self.child("/bin/bash", "-c",
                       'IFS= read -r -s -p "Password: " value; printf "\\nACCEPTED:%s\\n" "${#value}"')
        c.until(b"CLAMAV_PTY_ECHO=0", "control")
        c.send(secret + b"\n")
        self.assertEqual(c.finish(), 0)
        self.assertIn(f"ACCEPTED:{len(secret)}".encode(), c.out)
        self.assertNotIn(secret, c.out)
        self.assertNotIn(secret, c.control)

    def test_echo_enabled_rejects_secret_but_accepts_return(self):
        secret = b"must-never-echo-7731"
        c = self.child("/bin/bash", "-c", 'printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        c.until(b"READY")
        c.until(b"CLAMAV_PTY_ECHO=1", "control")
        c.send(secret + b"\n")
        c.until(b"CLAMAV_PTY_INPUT_REJECTED", "control")
        c.send(b"\n")
        self.assertEqual(c.finish(), 0)
        self.assertIn(b"LEN:0", c.out)
        self.assertNotIn(secret, c.out)
        self.assertNotIn(secret, c.control)

    def test_exit_code_is_preserved(self):
        c = self.child("/bin/bash", "-c", "exit 37")
        self.assertEqual(c.finish(), 37)

    def test_signal_exit_code_is_preserved(self):
        c = self.child("/bin/bash", "-c", "kill -TERM $$")
        self.assertEqual(c.finish(), 143)

    def test_nonexistent_command(self):
        c = self.child("/does-not-exist-clamav-installer-test")
        self.assertEqual(c.finish(), 127)

    def test_arguments_are_passed_without_shell_evaluation(self):
        value = "literal $(exit 33); spaces ' \" end"
        c = self.child("/usr/bin/printf", "%s", value)
        self.assertEqual(c.finish(), 0)
        self.assertEqual(c.out.decode(), value)

    def test_child_stderr_is_stdout_and_control_is_separate(self):
        c = self.child("/bin/bash", "-c", "printf CHILD_STDERR >&2")
        self.assertEqual(c.finish(), 0)
        self.assertIn(b"CHILD_STDERR", c.out)
        self.assertNotIn(b"CHILD_STDERR", c.control)

    def test_large_output_is_not_truncated(self):
        c = self.child("/bin/bash", "-c", "head -c 1048576 /dev/zero | tr '\\0' x")
        self.assertEqual(c.finish(), 0)
        self.assertEqual(len(c.out), 1048576)
        self.assertTrue(all(x == ord('x') for x in c.out))

    def test_termination_reaches_process_group(self):
        c = self.child("/bin/bash", "-c", "sleep 60 & printf 'DESCENDANT:%s\\n' $!; wait")
        c.until(b"DESCENDANT:")
        descendant = int(re.search(rb"DESCENDANT:(\d+)", c.out).group(1))
        c.process.terminate()
        self.assertEqual(c.finish(), 143)
        deadline = time.monotonic() + 3
        while True:
            try:
                os.kill(descendant, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                self.fail("Child process group still has a running descendant")
            time.sleep(0.05)

    def test_sigint_reaches_child(self):
        c = self.child("/bin/bash", "-c", "printf READY; exec sleep 60")
        c.until(b"READY")
        c.process.send_signal(signal.SIGINT)
        self.assertEqual(c.finish(), 130)

    def test_configured_grace_preserves_slow_rollback(self):
        env = dict(os.environ, CLAMAV_PTY_TERMINATION_GRACE_SECONDS="6")
        c = self.child("/bin/bash", "-c",
                       "trap 'sleep 4; printf ROLLBACK_COMPLETE; exit 130' TERM; "
                       "printf READY; while :; do sleep 1; done", env=env)
        c.until(b"READY")
        c.process.terminate()
        self.assertEqual(c.finish(timeout=9), 130)
        self.assertIn(b"ROLLBACK_COMPLETE", c.out)

    def test_invalid_grace_is_rejected_before_child_starts(self):
        for value in ("", "0", "-1", "+6", "6.0", " 6", "6 ", "nan", "inf", "121", "9" * 100):
            with self.subTest(value=value):
                env = dict(os.environ, CLAMAV_PTY_TERMINATION_GRACE_SECONDS=value)
                c = self.child("/usr/bin/printf", "CHILD_STARTED", env=env)
                self.assertEqual(c.finish(), 64)
                self.assertNotIn(b"CHILD_STARTED", c.out)
                self.assertIn(b"integer from 1 to 120", c.control)

    def test_stdin_eof_cannot_leave_uncooperative_child(self):
        c = self.child("/bin/bash", "-c", "trap '' HUP TERM; printf READY; while :; do sleep 1; done")
        c.until(b"READY")
        c.process.stdin.close()
        self.assertEqual(c.finish(timeout=9), 137)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BridgeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    (HERE / "test-results.json").write_text(json.dumps({
        "tests": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "passed": result.wasSuccessful(),
        "scope": "isolated PTY behavior; no installer execution or system configuration",
    }, indent=2) + "\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)
