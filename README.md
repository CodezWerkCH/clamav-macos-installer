# ClamAV Installer for macOS

Native **Apple Silicon / macOS 14+** GUI for installing and managing ClamAV through Homebrew. First public release: **1.0**.

**[Download version 1.0](https://github.com/CodezWerkCH/clamav-macos-installer/releases/tag/v1.0)** · [Deutsche Anleitung](docs/INSTALLATION-DE.md) · [English guide](docs/INSTALLATION-EN.md) · [Build and tests](docs/BUILD.md) · [Architecture](docs/ARCHITECTURE.md)

## Funktionen

- Homebrew bei Bedarf installieren; Paketdaten aktualisieren und die neueste dort verfügbare stabile ClamAV-Version installieren/aktualisieren.
- Privater `clamd`-Unix-Socket; automatische Signaturupdates alle zwei Stunden.
- Täglicher Scan um 19:00 Uhr für Downloads, Schreibtisch und Dokumente, zusätzlich manuell startbar.
- Scanstatus, echte Laufzeit, Protokolle und macOS-Mitteilungen.
- Getrennte Quarantäne pro Scan; Namenskonflikte werden behandelt, Fehler bleiben sichtbar.
- Wiederholbare Einrichtung mit Sicherungen; sichere Deinstallation und geprüfte Archivierung unbenutzter beschädigter Paketreste.
- Deutsch, Englisch, Französisch, Italienisch, Portugiesisch und Spanisch. Start in der primären Systemsprache, sonst Englisch.

## Schnellstart

1. Unter **Releases** die Datei `ClamAV-Installer-1.0-Apple-Silicon.zip` laden und entpacken.
2. `ClamAV Installer.app` öffnen und **Installieren / aktualisieren** wählen.
3. Den erforderlichen **Festplattenvollzugriff manuell** erlauben. Die App zeigt die genauen Programme und den nächsten Schritt; siehe [Anleitung](docs/INSTALLATION-DE.md).
4. Hintergrundjobs neu laden, einen Scan starten und den Abschluss im Status/Protokoll kontrollieren.

Die App ist **ad-hoc signiert, ohne Zertifikat, und nicht von Apple notarisiert**. macOS kann deshalb beim ersten Start eine Bestätigung unter *Datenschutz & Sicherheit → Dennoch öffnen* verlangen. Nur verwenden, wenn du Quelle und Inhalt vertraust.

ClamAV ist hier ein geplanter Scanner, **kein Echtzeitschutz**. Es gelten Größen-/Archivlimits; verschlüsselte, nicht lokal verfügbare oder nicht lesbare Dateien können ungeprüft bleiben. Kein Fund bedeutet keine Sicherheitsgarantie.

## Source and development

The full project source is included, including the Swift/AppKit UI, Bash backend, C PTY and permissions helpers, Swift archive helper, icon generator, translations and isolated regression suites. ClamAV and Homebrew are fetched from their upstream sources during installation and are not bundled in this repository.

```sh
python3 scripts/test.py
python3 scripts/build.py
```

Build on an Apple Silicon Mac with macOS 14+, Xcode Command Line Tools and Python 3. Output is placed in `dist/`. No private build paths, prebuilt cache or prior release is required. See [BUILD.md](docs/BUILD.md).

**Version 1.0 is the first public project release.** The installer version is independent of the ClamAV engine version. Internal pre-publication development versions were consolidated into this release; its safety and uninstall fixes are included.

## Documentation

- [Installation, permissions, updates and uninstall (Deutsch)](docs/INSTALLATION-DE.md)
- [Installation and operation (English)](docs/INSTALLATION-EN.md)
- [Architecture, storage and recovery](docs/ARCHITECTURE.md)
- [Build and tests](docs/BUILD.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release notes](CHANGELOG.md)
- [Security reporting](SECURITY.md)

Independent project; not an official ClamAV, Homebrew or Apple product. Their names and upstream software remain the property of their respective owners. Project code: [MIT License](LICENSE).
