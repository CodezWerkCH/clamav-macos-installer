#!/usr/bin/env python3
"""Exercise the real fd-based traversal without sudo or ownership mutations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "package_repair.c"
RESULTS = []
WORK = Path(tempfile.mkdtemp(prefix="fixtures-", dir=HERE))
PREFIX = WORK / "homebrew/Cellar/clamav"
KEG = PREFIX / "1.5.4"
REAL = WORK / "package-repair"
SIM = WORK / "package-repair-simulated"


def compile_binary(source, output, prefix):
    subprocess.run([
        "/usr/bin/xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=12.0",
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
        f'-DCLAMAV_REPAIR_TEST_PREFIX="{prefix}"', str(source), "-o", str(output),
    ], check=True)


def reset():
    root = WORK / "homebrew"
    if root.is_symlink():
        root.unlink()
    elif root.exists():
        shutil.rmtree(root)
    for name in ("bin", "sbin"):
        folder = KEG / name
        folder.mkdir(parents=True, mode=0o755)
        folder.chmod(0o755)
        (folder / "retained-file").write_bytes(b"must stay byte-identical\x00\xff")
    KEG.chmod(0o755)


def run(name, args=None, simulation=False, env=None, success=True, marker=None, changes=()):
    actual_env = os.environ.copy()
    actual_env.pop("SUDO_UID", None)
    actual_env.update(env or {})
    before = {
        str(p): (p.read_bytes(), p.stat().st_uid, p.stat().st_gid, p.stat().st_mode)
        for p in KEG.rglob("*") if p.is_file() and not p.is_symlink()
    } if KEG.is_dir() and not KEG.is_symlink() else {}
    proc = subprocess.run([str(SIM if simulation else REAL), *(args or ["--check", "1.5.4"])],
                          env=actual_env, capture_output=True, text=True)
    assert (proc.returncode == 0) == success, (name, proc.returncode, proc.stdout, proc.stderr)
    if marker:
        assert proc.stdout.strip().endswith(marker), (name, proc.stdout)
        if (args or ["--check"])[0] == "--check":
            assert proc.stdout == marker + "\n", (name, proc.stdout)
    called = [line.removeprefix("TEST:FCHOWN:") for line in proc.stderr.splitlines()
              if line.startswith("TEST:FCHOWN:")]
    assert called == list(changes), (name, called, changes)
    for path, expected in before.items():
        p = Path(path)
        assert p.exists(), (name, "deleted file", path)
        assert (p.read_bytes(), p.stat().st_uid, p.stat().st_gid, p.stat().st_mode) == expected
    RESULTS.append({"name": name, "passed": True, "exit": proc.returncode})


compile_binary(SOURCE, REAL, PREFIX)
compile_binary(HERE / "simulated_syscalls.c", SIM, PREFIX)
reset()
run("owned directories need no repair", marker="REPAIR:NOT_NEEDED")
for version in ["1", "..", "../1.5.4", "/1.5.4", "1.5.4/../1.5.4", "1.5.4-beta",
                "1.5.4_", "1.5.4_x", "1..5", "1.2.3.4.5", "1.2\n", "1." + "2" * 64]:
    run(f"reject invalid version {version!r}", args=["--check", version], success=False)
for version in ["1.5", "1.5.4_2", "1.2.3.4"]:
    run(f"accept version grammar {version}", args=["--check", version], marker="REPAIR:NOT_NEEDED")
run("reject unknown operation", args=["--delete", "1.5.4"], success=False)
run("reject excess arguments", args=["--check", "1.5.4", "/tmp"], success=False)
run("repair requires actual root", args=["--repair", "1.5.4"],
    env={"SUDO_UID": str(os.getuid())}, success=False)
root_metadata = {"TEST_ROOT_BIN": "1", "TEST_ROOT_SBIN": "1"}
sudo = {"TEST_ROOT_EUID": "1", "SUDO_UID": str(os.getuid()), **root_metadata}
run("known Homebrew root directories need repair", simulation=True, env=root_metadata,
    marker="REPAIR:NEEDED")
run("check rejects root", simulation=True, env=sudo, success=False)
run("repair both validated directory inodes", args=["--repair", "1.5.4"],
    simulation=True, env=sudo, marker="REPAIR:NOT_NEEDED", changes=["bin", "sbin"])
run("already repaired directories are unchanged", args=["--repair", "1.5.4"],
    simulation=True, env={"TEST_ROOT_EUID": "1", "SUDO_UID": str(os.getuid())},
    marker="REPAIR:NOT_NEEDED")
for uid in ["", "0", "-1", "+501", "501x", " 501", "4294967295", "4294967296", "9" * 80]:
    run(f"reject invalid SUDO_UID {uid!r}", args=["--repair", "1.5.4"], simulation=True,
        env={**sudo, "SUDO_UID": uid}, success=False)
run("reject missing SUDO_UID", args=["--repair", "1.5.4"], simulation=True,
    env={"TEST_ROOT_EUID": "1", **root_metadata}, success=False)
run("reject keg owned by a different user", args=["--repair", "1.5.4"], simulation=True,
    env={**sudo, "SUDO_UID": str(os.getuid() + 1)}, success=False)
for key, value in [("TEST_FOREIGN_SBIN", "1"), ("TEST_MODE_SBIN", "0755"),
                   ("TEST_MODE_SBIN", "01777"), ("TEST_MODE_SBIN", "04755"),
                   ("TEST_FLAGS_SBIN", "1")]:
    run(f"prevalidate both leaves before mutation: {key}={value}", args=["--repair", "1.5.4"],
        simulation=True, env={**sudo, key: value}, success=False)
run("detect metadata change before mutation", args=["--repair", "1.5.4"],
    simulation=True, env={**sudo, "TEST_RACE_BIN": "1"}, success=False)
run("report a partial ownership repair", args=["--repair", "1.5.4"],
    simulation=True, env={**sudo, "TEST_FAIL_SBIN": "1"}, success=False, changes=["bin", "sbin"])
run("verify preserved metadata after each repair", args=["--repair", "1.5.4"],
    simulation=True, env={**sudo, "TEST_BAD_POSTCHECK": "1"}, success=False, changes=["bin"])

reset()
shutil.rmtree(KEG / "sbin")
run("partly uninstalled keg is checkable", simulation=True, env=root_metadata, marker="REPAIR:NEEDED")
run("repair only the still-existing leaf", args=["--repair", "1.5.4"], simulation=True,
    env=sudo, marker="REPAIR:NOT_NEEDED", changes=["bin"])
shutil.rmtree(KEG / "bin")
run("both leaves already absent", marker="REPAIR:NOT_NEEDED")
shutil.rmtree(KEG)
run("keg already absent", marker="REPAIR:NOT_NEEDED")

for target in ["bin", "sbin"]:
    reset()
    shutil.rmtree(KEG / target)
    (KEG / target).symlink_to(WORK)
    run(f"reject {target} symlink", simulation=True, env=root_metadata, success=False)
    run(f"repair rejects {target} symlink without changes", args=["--repair", "1.5.4"],
        simulation=True, env=sudo, success=False)
reset()
shutil.rmtree(KEG / "sbin")
(KEG / "sbin").write_text("not a directory")
run("reject regular file as leaf", simulation=True, env=root_metadata, success=False)
reset()
KEG.chmod(0o777)
run("reject writable keg", success=False)
reset()
(KEG / "bin").chmod(0o777)
run("reject unexpectedly writable user-owned leaf", success=False)
reset()
shutil.rmtree(KEG)
KEG.symlink_to(WORK)
run("reject keg symlink", success=False)
reset()
shutil.rmtree(WORK / "homebrew")
(WORK / "homebrew").symlink_to(WORK)
run("reject ancestor symlink", success=False)
(WORK / "homebrew").unlink()
run("Homebrew absent", marker="REPAIR:NOT_NEEDED")

report = {"passed": len(RESULTS), "failed": 0, "sudo_used": False,
          "real_ownership_changes": False, "fixtures": str(WORK), "tests": RESULTS}
(HERE / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"PASS: {len(RESULTS)} checks; no sudo and no real ownership changes")
