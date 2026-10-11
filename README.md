# ClamAV Installer for macOS

Native **Apple Silicon / macOS 14+** GUI for installing and managing ClamAV through Homebrew. First public release: **1.0**.

**[Download version 1.0](https://github.com/CodezWerkCH/clamav-macos-installer/releases/tag/v1.0)** · [English guide](docs/INSTALLATION-EN.md) · [German guide](docs/INSTALLATION-DE.md) · [Deutsche Projektübersicht](README.de.md) · [Build and tests](docs/BUILD.md) · [Architecture](docs/ARCHITECTURE.md)

## Features

- Install Homebrew if needed, refresh package metadata and install or upgrade the latest stable ClamAV version available through Homebrew.
- Private `clamd` Unix socket and automatic signature updates every two hours.
- Daily 19:00 scan of Downloads, Desktop and Documents, with on-demand scanning.
- Scan status, actual elapsed time, logs and macOS notifications.
- Separate quarantine for each scan, with filename collision handling and visible errors.
- Repeatable setup with backups, safe uninstall and verified archival of unused damaged package remnants.
- German, English, French, Italian, Portuguese and Spanish. Uses the primary system language when supported, otherwise English.

## Quick start

1. Download `ClamAV-Installer-1.0-Apple-Silicon.zip` from **Releases** and extract it.
2. Open `ClamAV Installer.app` and choose **Install / update**.
3. Grant the required **Full Disk Access manually**. The app shows the exact programs and next steps; see the [installation guide](docs/INSTALLATION-EN.md).
4. Reload background jobs, start a scan and check the status/log for completion.

The app is **ad-hoc signed without a certificate and is not notarized by Apple**. On first launch, macOS may require confirmation under *Privacy & Security → Open Anyway*. Only proceed if you trust the source and contents.

ClamAV is a scheduled scanner here, **not real-time protection**. File/archive size limits apply; encrypted, unavailable or unreadable files may remain unscanned. No detections is not a safety guarantee.

## Source and development

The full project source is included, including the Swift/AppKit UI, Bash backend, C PTY and permissions helpers, Swift archive helper, icon generator, translations and isolated regression suites. ClamAV and Homebrew are fetched from their upstream sources during installation and are not bundled in this repository.

```sh
python3 scripts/test.py
python3 scripts/build.py
```

Build on an Apple Silicon Mac with macOS 14+, Xcode Command Line Tools and Python 3. Output is placed in `dist/`. No private build paths, prebuilt cache or prior release is required. See [BUILD.md](docs/BUILD.md).

**Version 1.0 is the first public project release.** The installer version is independent of the ClamAV engine version. Internal pre-publication development versions were consolidated into this release; its safety and uninstall fixes are included.

## Documentation

- [Installation, permissions, updates and uninstall (English)](docs/INSTALLATION-EN.md)
- [Installation and operation (German)](docs/INSTALLATION-DE.md)
- [Architecture, storage and recovery](docs/ARCHITECTURE.md)
- [Build and tests](docs/BUILD.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release notes](CHANGELOG.md)
- [Release language policy and process](docs/RELEASING.md)
- [Security reporting](SECURITY.md)

Independent project; not an official ClamAV, Homebrew or Apple product. Their names and upstream software remain the property of their respective owners. Project code: [MIT License](LICENSE).
