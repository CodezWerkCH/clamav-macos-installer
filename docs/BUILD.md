# Build and test

Build host: Apple Silicon, macOS 14+, Xcode Command Line Tools (`xcode-select --install`), Python 3 on PATH. No Python third-party packages are required. The app itself does not require Python. Swift/AppKit, CryptoKit, Clang, codesign and ditto are used from the Apple toolchain/system.

```sh
git clone https://github.com/CodezWerkCH/clamav-macos-installer.git
cd clamav-macos-installer
python3 scripts/test.py
python3 scripts/build.py
```

`test.py` copies sources into a temporary directory, compiles fixture-only helpers and runs the isolated regression suites. It does not install Homebrew/ClamAV, request sudo, change Full Disk Access or register real launchd jobs. Suites cover package archives, failed removal, permission repair traversal, dependency/job/process refusals, rollback, legacy migration, version selection, prompts, PTY framing, live output and scan display.

`build.py` embeds the included icon asset, builds ARM64 binaries, embeds translations and backend, ad-hoc signs the bundle, creates the ZIP, re-extracts it and checks signing and the app self-test again. It produces:

- `dist/ClamAV-Installer-1.0-Apple-Silicon.zip`
- `dist/ClamAV-Installer-1.0-Apple-Silicon.zip.sha256`

Check a downloaded archive using `shasum -a 256 -c ClamAV-Installer-1.0-Apple-Silicon.zip.sha256` in its directory. Builds are self-contained but are not promised to be byte-for-byte reproducible across toolchain versions/signing timestamps.

## Versioning

The `VERSION` file, backend version and UI/catalog display strings use `1.0` for the first public release. Update them together for future releases. The engine version comes from Homebrew and is separate. Internal development builds used other numbers before this public versioning baseline.

## Test scope

A successful local test/build verifies the isolated cases and bundle contents. It does not establish that a fresh Homebrew installation, every target macOS version, real TCC grants or an actual antivirus scan succeeded on another machine. Those require a target-Mac acceptance run following the installation guide.

## Distribution

The default build is ad-hoc signed, without a Developer ID certificate or notarization. For notarized distribution, a maintainer needs their own Apple Developer credentials, an appropriate signing/notarization pipeline and separate validation. No credentials belong in source control.

The icon asset is included under `assets/`; its drawing source is `src/gui/make-icon.swift`. It is independent of previous release packages.

For source-only and complete bundles, run `python3 scripts/package.py` after the build. The complete ZIP includes the ready-to-open app, all source files and documentation. `dist/SHA256SUMS.txt` covers all three ZIPs. Local Git history and generated output are excluded from the source bundle.

## Release languages

The default project documentation is English. Future releases use both English and German release notes and include `Instructions-English.txt` and `Anleitung-Deutsch.txt` in the app archive. Follow [RELEASING.md](RELEASING.md) and use the [release template](../.github/RELEASE_TEMPLATE.md).

The app and complete archives also include `RELEASE-VERSION.md` at the top level. The source archive includes the identical bilingual text under `docs/`. Keep this file synchronized with the published GitHub release description.

Before building, run `python3 scripts/test_release.py` and `python3 scripts/release_notes.py`. Build and packaging reject missing bilingual notes; packaging also rejects stale app documentation. Run `python3 scripts/release_notes.py --packages` to verify all ZIPs and checksums. Version-tag pushes run the complete workflow described in [RELEASING.md](RELEASING.md).
