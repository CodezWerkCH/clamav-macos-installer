#!/usr/bin/env python3
"""Framed GUI input tests using real isolated PTYs, with no installation."""
import json
from pathlib import Path
import sys
import time
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend-tests'))
from test_bridge import Child

class GUIBridgeTests(unittest.TestCase):
    def child(self, code):
        c = Child('--gui-input', '/bin/bash', '-c', code)
        self.addCleanup(c.close)
        c.until(b'READY')
        return c
    def public(self, wire, answer):
        c = self.child('printf READY; IFS= read -r value; printf "ANSWER:%s" "$value"')
        c.send(wire)
        self.assertEqual(c.finish(), 0)
        self.assertIn(b'ANSWER:' + answer, c.out)
    def test_explicit_yes_echo_enabled(self): self.public(b'Y\n', b'y')
    def test_explicit_no_echo_enabled(self): self.public(b'N\n', b'n')
    def test_explicit_return(self): self.public(b'R\n', b'')
    def test_public_answer_echo_disabled_getch_like(self):
        c = self.child('stty -echo; printf READY; IFS= read -r -n 1 value; stty echo; printf "ANSWER:%s" "$value"')
        c.send(b'Y\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'ANSWER:y', c.out)
    def assert_waits_for_next_frame(self, c):
        c.until(b'NEXT_PROMPT')
        deadline = time.monotonic() + 0.35
        while time.monotonic() < deadline:
            c.pump(0.05)
        self.assertNotIn(b'SECOND:', c.out,
                         'Public getch answer must not enqueue a newline for the next prompt')
        c.send(b'R\n')
        self.assertEqual(c.finish(), 0)
        self.assertIn(b'SECOND:0', c.out)
    def test_noncanonical_yes_waits_for_separate_return(self):
        c = self.child('stty -echo -icanon min 1 time 0; printf READY; '
                       'IFS= read -r -n 1 first; stty echo icanon; '
                       'printf "FIRST:%s\\nNEXT_PROMPT" "$first"; '
                       'IFS= read -r second; printf "SECOND:%s" "${#second}"')
        c.until(b'CLAMAV_PTY_ECHO=0', 'control')
        c.send(b'Y\n')
        self.assert_waits_for_next_frame(c)
        self.assertIn(b'FIRST:y', c.out)
    def test_real_ruby_getch_yes_waits_for_separate_return(self):
        self.ruby_getch(b'Y\n', b'y')
    def test_real_ruby_getch_no_waits_for_separate_return(self):
        self.ruby_getch(b'N\n', b'n')
    def ruby_getch(self, frame, expected):
        self.assertTrue(Path('/usr/bin/ruby').is_file())
        c = Child('--gui-input', '/usr/bin/ruby', '-e',
                  'require "io/console"; STDOUT.sync=true; puts "READY"; '
                  'first=STDIN.getch; puts "FIRST:#{first}"; puts "NEXT_PROMPT"; '
                  'second=STDIN.gets; puts "SECOND:#{second.chomp.length}"')
        self.addCleanup(c.close)
        c.until(b'READY'); c.until(b'CLAMAV_PTY_ECHO=0', 'control')
        c.send(frame)
        self.assert_waits_for_next_frame(c)
        self.assertIn(b'FIRST:' + expected, c.out)
    def test_fragmented_public_frame(self):
        c = self.child('printf READY; IFS= read -r value; printf "ANSWER:%s" "$value"')
        c.send(b'Y'); c.pump(0.2)
        self.assertNotIn(b'ANSWER:', c.out)
        c.send(b'\n'); self.assertEqual(c.finish(), 0); self.assertIn(b'ANSWER:y', c.out)
    def test_coalesced_frames_preserve_boundaries(self):
        c = self.child('printf READY; IFS= read -r first; IFS= read -r second; printf "ANSWERS:%s,%s" "$first" "$second"')
        c.send(b'Y\nN\n'); self.assertEqual(c.finish(), 0); self.assertIn(b'ANSWERS:y,n', c.out)
    def test_password_frame_cannot_be_public_yes(self):
        c = self.child('printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        c.send(b'Py\n'); c.until(b'CLAMAV_PTY_INPUT_REJECTED', 'control'); c.send(b'R\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'LEN:0', c.out)
        self.assertNotIn(b'Py', c.out)
    def test_password_frame_cannot_be_public_no(self):
        c = self.child('printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        c.send(b'Pn\n'); c.until(b'CLAMAV_PTY_INPUT_REJECTED', 'control'); c.send(b'R\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'LEN:0', c.out)
    def test_fragmented_secret_never_echoes(self):
        secret = b'fixture-secret-1900'
        c = self.child('stty -echo; printf READY; IFS= read -r value; stty echo; printf "LEN:%s" "${#value}"')
        c.until(b'CLAMAV_PTY_ECHO=0', 'control')
        for part in [b'P', secret[:5], secret[5:], b'\n']:
            c.send(part); c.pump(0.04)
        self.assertEqual(c.finish(), 0)
        self.assertIn(b'LEN:19', c.out); self.assertNotIn(secret, c.out); self.assertNotIn(secret, c.control)
    def test_invalid_frames_fail_closed_then_recover(self):
        c = self.child('printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        frames = [b'\n', b'P\n', b'unknown\n', b'Yextra\n', b'y\n', b'Pfoo\rbar\n', b'Pfoo\x00bar\n', b'Pfoo\x1bbar\n']
        c.send(b''.join(frames) + b'R\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'LEN:0', c.out)
        self.assertEqual(c.control.count(b'CLAMAV_PTY_INPUT_REJECTED'), len(frames))
    def test_oversized_complete_frame_rejected(self):
        c = self.child('printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        c.send(b'P' + b'x'*5000 + b'\nR\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'LEN:0', c.out)
        self.assertIn(b'CLAMAV_PTY_INPUT_REJECTED', c.control)
    def test_oversized_fragment_discarded_through_end(self):
        c = self.child('printf READY; IFS= read -r value; printf "LEN:%s" "${#value}"')
        c.send(b'P' + b'x'*9000)
        c.until(b'CLAMAV_PTY_INPUT_REJECTED', 'control')
        c.send(b'Y\nR\n')
        self.assertEqual(c.finish(), 0); self.assertIn(b'LEN:0', c.out)
    def test_cancel_incomplete_secret(self):
        secret = b'never-forward-incomplete'
        c = self.child('stty -echo; printf READY; IFS= read -r value')
        c.send(b'P' + secret); c.process.terminate()
        self.assertEqual(c.finish(), 143)
        self.assertNotIn(secret, c.out); self.assertNotIn(secret, c.control)

if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(GUIBridgeTests))
    Path(__file__).with_name('gui-bridge-results.json').write_text(json.dumps({'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'passed': result.wasSuccessful()}, indent=2)+'\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
