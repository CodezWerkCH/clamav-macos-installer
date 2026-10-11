# Troubleshooting

[Deutsche Fassung](TROUBLESHOOTING-DE.md)

- **Scan only requested:** Wait for the actual job to start and finish. Read the current status and scan log. A running daemon alone does not prove a scan is running.
- **Operation not permitted / cannot read:** Check Full Disk Access for the programs shown by the app, reload the background jobs and test again. Also check file permissions and cloud availability. Do not confuse old log entries with the latest result.
- **Missing clamd socket:** Setup must load signatures and start the managed daemon first. The private socket is separate from Homebrew's unconfigured default socket. Read the installation/daemon log.
- **No such keg after uninstall:** Version 1.0 checks for unregistered remnants and archives eligible unused directories. For protected program directories, retry package removal through the app. Resolve active jobs or dependencies first. Do not use blind recursive deletion.
- **Cannot archive a remnant:** Read the path and cause in the error. Cross-filesystem moves, unreadable contents, unknown structures or a remaining installation receipt cause a safe refusal. The app does not report complete success in these cases.
- **Homebrew tap warning:** Foreign taps are not automatically trusted. The installer targets `homebrew/core/clamav`; change unrelated trust settings only deliberately.
- **No notifications:** Check macOS notification settings for the app. Scan status is available independently in the logs.
- **macOS blocks launch:** The build is ad-hoc signed without a certificate and is not notarized. Review its source, then use the explicit system approval if appropriate. Do not disable system protection globally.
- **Permissions remain after uninstall:** Privacy permissions are separate macOS state. The app opens the relevant settings after removal; manually remove entries you no longer need.

For bug reports, include the app/macOS version, action, exact error and only relevant anonymized log excerpts. Do not publish personal paths, filenames, quarantine contents or credentials.
