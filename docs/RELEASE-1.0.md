# ClamAV Installer 1.0

First public release for **Apple Silicon · macOS 14+**, including the complete source code and documentation.

## Downloads

- **ClamAV-Installer-1.0-Apple-Silicon.zip** — ready-to-use app and operating instructions.
- **ClamAV-Installer-1.0-Complete.zip** — app, complete source code, build/test scripts and documentation.
- **ClamAV-Installer-1.0-Source.zip** — complete source project for building locally.
- **SHA256SUMS.txt** — SHA-256 checksums for all three ZIP files.

## Features

Homebrew setup, the latest stable ClamAV formula, a private clamd socket, signature updates every two hours, daily scanning at 19:00, live status, logs, quarantine, notifications and safe uninstall. Unused damaged package remnants are archived after safety checks and verified using SHA-256. Six interface languages: DE/EN/FR/IT/PT/ES.

## Getting started

Extract the app ZIP, open **ClamAV Installer.app** and choose **Install / update**. Manually grant **Full Disk Access** to the programs shown by the app, reload the background jobs and run a test scan. See the [English installation guide](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-EN.md) or the [German guide](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-DE.md).

**Ad-hoc signed without a certificate; not notarized by Apple.** An explicit macOS launch approval may be required. Privacy permissions remain a manual step. This is scheduled scanning, not real-time protection.

Project version 1.0 is independent of the ClamAV engine version. Homebrew and ClamAV are downloaded during installation and are not bundled in this release.

Future release notes will be published in **English and German**, with English first.
