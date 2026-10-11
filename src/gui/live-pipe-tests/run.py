#!/usr/bin/env python3
"""Bounded native macOS reproduction and real-PTY streaming regression."""
from pathlib import Path
import json
import subprocess

HERE = Path(__file__).resolve().parent
GUI = HERE.parent

def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, timeout=30, **kwargs)

run('/usr/bin/xcrun', 'clang', '-arch', 'arm64', '-std=c11', '-Wall', '-Wextra',
    '-Werror', '-O2', GUI / 'pty_bridge.c', '-o', HERE / 'pty-bridge')
run('/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path',
    GUI / 'cache', GUI / 'LivePipeReader.swift', HERE / 'main.swift',
    '-o', HERE / 'test-reader')
results = []
for mode in ('foundation', 'live'):
    completed = run(HERE / 'test-reader', mode, HERE / 'pty-bridge',
                    capture_output=True, text=True)
    results.append(json.loads(completed.stdout))
(HERE / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
