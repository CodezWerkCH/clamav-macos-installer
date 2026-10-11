# Project instructions

- Default GitHub presentation, README and general documentation: English.
- For every future release after 1.0, publish release notes in both English and German, English first. Use `.github/RELEASE_TEMPLATE.md` and follow `docs/RELEASING.md`.
- Keep English and German operating instructions in release packages. Preserve all six existing app languages and primary-system-language selection.
- Never claim notarization or certificate signing for an ad-hoc build. Full Disk Access is always a manual macOS step.
- Preserve logs, quarantine and archives. Do not introduce forced recursive removal of package remnants.
- Run isolated tests for runtime changes and the build/bundle checks for app changes. Do not run a real install/uninstall as a unit test.
