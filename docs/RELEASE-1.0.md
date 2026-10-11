[English](#english) · [Deutsch](#deutsch)

## English

First public release for **Apple Silicon · macOS 14+**, including the complete source code and documentation.

### Downloads

- **ClamAV-Installer-1.0-Apple-Silicon.zip** — ready-to-use app with English and German operating instructions.
- **ClamAV-Installer-1.0-Complete.zip** — app, complete source code, build/test scripts and documentation, including both operating instructions.
- **ClamAV-Installer-1.0-Source.zip** — complete source project for building locally, including English and German documentation.
- **SHA256SUMS.txt** — SHA-256 checksums for all three ZIP files.

### Features

- Homebrew setup and installation or upgrade of the latest stable ClamAV version available through Homebrew.
- Private clamd Unix socket, signature updates every two hours and daily scanning at 19:00 of Downloads, Desktop and Documents.
- Live status, logs, quarantine, macOS notifications and safe uninstall.
- Unused damaged package remnants are archived after safety checks and verified using SHA-256.
- Six interface languages: German, English, French, Italian, Portuguese and Spanish. The app uses the primary system language when supported, otherwise English.

### Getting started

1. Extract the app ZIP and open **ClamAV Installer.app**.
2. Choose **Install / update**.
3. Manually grant **Full Disk Access** to the programs shown by the app.
4. Reload the background jobs, run a test scan and check its completion and log.

See the [English installation guide](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-EN.md) or the [German installation guide](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-DE.md).

### Signing, permissions and limitations

**Ad-hoc signed without a certificate; not notarized by Apple.** An explicit macOS launch approval may be required. Full Disk Access must be granted manually; permissions may also need to be removed manually after uninstall.

This is scheduled scanning, **not real-time protection**. Project version 1.0 is independent of the ClamAV engine version. Homebrew and ClamAV are downloaded during installation and are not bundled in this release. Automatic signature updates do not upgrade the engine itself.

### Documentation package refresh — 2026-10-12

All three attached ZIP packages include the full English and German operating instructions (`Instructions-English.txt` and `Anleitung-Deutsch.txt`). The source and complete bundles include the documentation refresh from [commit 21d7d14](https://github.com/CodezWerkCH/clamav-macos-installer/commit/21d7d147ec8c6416b16b3171aba4b6b8b2d2f761).

Download the updated **SHA256SUMS.txt** together with the new packages. The release remains **version 1.0**. GitHub’s automatically generated source archives still reflect the original `v1.0` tag and contain both installation guides as Markdown.

The app bundle and language catalogs were checked. All three published ZIP packages were downloaded again; their checksums and both operating instructions were verified. Both guides were also confirmed in GitHub’s automatically generated source archives. Full Disk Access and actual scanning must still be checked on the target Mac.

This release description and future release notes are published in **English and German**, with English first.

---

## Deutsch

Erste öffentliche Version für **Apple Silicon · macOS 14+**, einschließlich vollständigem Quellcode und Dokumentation.

### Downloads

- **ClamAV-Installer-1.0-Apple-Silicon.zip** — fertige App mit englischer und deutscher Bedienungsanleitung.
- **ClamAV-Installer-1.0-Complete.zip** — App, vollständiger Quellcode, Build-/Testskripte und Dokumentation einschließlich beider Bedienungsanleitungen.
- **ClamAV-Installer-1.0-Source.zip** — vollständiges Quellprojekt zum Selbstbauen einschließlich englischer und deutscher Dokumentation.
- **SHA256SUMS.txt** — SHA-256-Prüfsummen aller drei ZIP-Dateien.

### Funktionen

- Homebrew-Einrichtung sowie Installation oder Aktualisierung auf die neueste über Homebrew verfügbare stabile ClamAV-Version.
- Privater clamd-Unix-Socket, Signaturupdates alle zwei Stunden und täglicher Scan um 19:00 Uhr für Downloads, Schreibtisch und Dokumente.
- Live-Status, Protokolle, Quarantäne, macOS-Mitteilungen und sichere Deinstallation.
- Unbenutzte beschädigte Paketreste werden nach Sicherheitsprüfungen archiviert und anhand von SHA-256-Prüfsummen kontrolliert.
- Sechs Oberflächensprachen: Deutsch, Englisch, Französisch, Italienisch, Portugiesisch und Spanisch. Die App verwendet die primäre Systemsprache, sofern unterstützt, andernfalls Englisch.

### Erste Schritte

1. App-ZIP entpacken und **ClamAV Installer.app** öffnen.
2. **Installieren / aktualisieren** wählen.
3. Den von der App angezeigten Programmen manuell **Festplattenvollzugriff** erteilen.
4. Hintergrundjobs neu laden, einen Testscan starten und dessen Abschluss sowie Protokoll prüfen.

Siehe die [englische Installationsanleitung](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-EN.md) oder die [deutsche Installationsanleitung](https://github.com/CodezWerkCH/clamav-macos-installer/blob/main/docs/INSTALLATION-DE.md).

### Signierung, Berechtigungen und Einschränkungen

**Ad-hoc signiert, ohne Zertifikat; nicht von Apple notarisiert.** Eine ausdrückliche macOS-Startfreigabe kann erforderlich sein. Festplattenvollzugriff muss manuell erteilt werden; auch nach der Deinstallation müssen Berechtigungen gegebenenfalls manuell entfernt werden.

Dies ist ein geplanter Scanner, **kein Echtzeitschutz**. Die Projektversion 1.0 ist unabhängig von der ClamAV-Engine-Version. Homebrew und ClamAV werden während der Installation heruntergeladen und sind nicht im Release enthalten. Automatische Signaturupdates aktualisieren nicht die Engine selbst.

### Aktualisierung der Dokumentationspakete — 12.10.2026

Alle drei angehängten ZIP-Pakete enthalten die vollständige englische und deutsche Bedienungsanleitung (`Instructions-English.txt` und `Anleitung-Deutsch.txt`). Die Quellcode- und Komplettpakete enthalten die aktualisierte Dokumentation aus [Commit 21d7d14](https://github.com/CodezWerkCH/clamav-macos-installer/commit/21d7d147ec8c6416b16b3171aba4b6b8b2d2f761).

Die aktualisierte **SHA256SUMS.txt** zusammen mit den neuen Paketen herunterladen. Der Release bleibt **Version 1.0**. Die von GitHub automatisch erzeugten Quellcode-Archive entsprechen weiterhin dem ursprünglichen Tag `v1.0` und enthalten beide Installationsanleitungen als Markdown.

App-Bundle und Sprachdateien wurden geprüft. Alle drei veröffentlichten ZIP-Pakete wurden erneut heruntergeladen; ihre Prüfsummen und beide Bedienungsanleitungen wurden kontrolliert. Auch in den automatisch erzeugten GitHub-Quellcode-Archiven wurden beide Anleitungen bestätigt. Festplattenvollzugriff und der tatsächliche Scan müssen weiterhin auf dem Ziel-Mac geprüft werden.

Diese Release-Beschreibung und künftige Release-Mitteilungen erscheinen auf **Englisch und Deutsch**, jeweils Englisch zuerst.
