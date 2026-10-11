# Changelog

## 1.0 — 2026-10-12

First public GitHub release. Consolidates the internal development builds into the public 1.0 baseline.

- Native Apple Silicon app with six languages and system-language selection.
- Homebrew bootstrap and current stable ClamAV formula installation/upgrade.
- Private clamd socket, periodic signature updates and daily user-folder scans.
- Live operation output, prompt handling, true scan status and notifications.
- Per-scan quarantine, retained logs, idempotent setup and conservative legacy migration.
- Uninstall archives managed data; safely handles unregistered orphan kegs with SHA-256 verification and rollback on verification failure.
- Full Disk Access explanation and settings handoff after uninstall.
- Complete source, generated icon, local build and isolated regression test runner.

Release is ad-hoc signed, without an Apple certificate or notarization. ClamAV engine and signatures are downloaded separately; engine version is independent of this release number.
