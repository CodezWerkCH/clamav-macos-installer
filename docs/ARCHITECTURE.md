# Architecture and retained data

| Component | Source | Responsibility |
| --- | --- | --- |
| GUI | `src/gui/main.swift` | Native AppKit window, operations, live progress, notifications and settings handoff |
| Localization | `src/gui/Localization.swift`, `i18n/*.json` | Six catalogs, system language with English fallback |
| Output and prompts | `LivePipeReader.swift`, `InputPromptState.swift`, `pty_bridge.c` | Incremental output and framed password/yes/no/return input |
| Scan view | `ScanSnapshot.swift` | Status/log interpretation and elapsed time |
| Runtime | `src/backend/install.sh` | Install, upgrades, scan, updates, launchd, migration and uninstall |
| Permission helper | `package_repair.c` | Fixed Homebrew keg path; restricted repair of recognized bin/sbin ownership |
| Archive helper | `package_archive.swift` | Unprivileged atomic archival of unused, unregistered ClamAV kegs |
| Icon | `make-icon.swift` | Generates the complete app icon locally |

## Process and privilege boundaries

The backend runs as the logged-in user, not root. Homebrew runs without sudo. Only Homebrew's own bootstrap and the narrowly scoped package permission repair can request administrator authorization. The archive helper refuses root execution. Password input is framed through the PTY bridge and must not be treated as ordinary public confirmation input.

The daemon uses a private Unix socket. `clamdscan --fdpass` passes opened file descriptors to clamd. The daemon is not exposed through a configured TCP service. Job and management locks prevent overlapping managed operations; stop handling waits for both the launchd registration and prior process to stop before replacing a job.

## Files and schedules

| Location | Purpose |
| --- | --- |
| `~/.clamav-automatik` | Managed runtime, configuration, signatures, socket/run state, backups and quarantine |
| `~/Library/LaunchAgents/local.clamav.automatik.*.plist` | User jobs: daemon, update and scan |
| `~/Library/Logs/ClamAV-Automatik` | Operation/scan logs and last scan status |
| `~/.clamav-automatik-archiv` | Unique uninstall and package-remnant archives |
| `/opt/homebrew/Cellar/clamav` | Homebrew-owned engine packages |

Default daily scan: 19:00. Signature refresh: two hours. A logged-in user session is required. Scheduled scans do not promise to wake a sleeping Mac.

## Package-remnant recovery

Normal Homebrew removal is attempted first. The backend then independently checks remaining directories, even if Homebrew reports no installed package. Before invoking the archive helper it requires the managed automation to be absent and checks active processes, known service registrations and installed dependents.

The helper validates all remaining version directories before moving any. A valid receipt blocks the fallback. The `.brew/clamav.rb` marker, plain directory structure and expected owner are required; active Homebrew links to the keg block it. Files, symlinks and metadata are inventoried; regular files receive SHA-256 hashes. Special files are refused.

A private unique archive receives the manifest. An exclusive same-volume rename moves the whole keg, preserving filesystem metadata without recursive deletion or copy-and-delete. The archive is compared with the manifest; a mismatch attempts an exclusive rollback without replacing a newly created source. If rollback fails, the error identifies the retained archive. Cross-volume moves fail safely. Unexpected live changes and permission errors remain failures, not false success.

Do not manually overwrite an original path when recovering from an archive. Review the included manifest/README and current filesystem first. Uninstall never automatically empties archives, logs or quarantine.

## Limits

Filesystem checks and locks cover this application's managed operations, not hostile concurrent modifications by the same user or another administrator. This utility is not a sandbox or a real-time endpoint protection product. Full Disk Access is a macOS decision and remains explicitly manual.
