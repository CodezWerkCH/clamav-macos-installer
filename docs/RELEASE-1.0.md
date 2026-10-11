# ClamAV Installer 1.0

Erste öffentliche Version für **Apple Silicon · macOS 14+**. Enthält den gesamten aktuellen Funktionsstand einschließlich sicherer Archivierung beschädigter Paketreste.

## Download

- **ClamAV-Installer-1.0-Apple-Silicon.zip** – fertige App und Bedienhinweise.
- **ClamAV-Installer-1.0-Complete.zip** – fertige App, vollständiger Quellcode, Build-/Testskripte und Dokumentation.
- **ClamAV-Installer-1.0-Source.zip** – vollständiges Quellprojekt zum Selbstbauen.
- **SHA256SUMS.txt** – SHA-256-Prüfsummen dieser Pakete.

## Enthalten

Homebrew-Einrichtung, Installation/Aktualisierung der neuesten stabilen ClamAV-Formel, privater clamd-Socket, Signaturupdates alle zwei Stunden, täglicher Scan um 19:00 Uhr, Scanstatus und Protokolle, Quarantäne, Mitteilungen, sicherer Uninstaller und sechs Sprachen (DE/EN/FR/IT/PT/ES).

## Installation

App-ZIP entpacken, `ClamAV Installer.app` öffnen und **Installieren / aktualisieren** wählen. Anschließend den angezeigten Programmen den **Festplattenvollzugriff manuell** erteilen, Hintergrundjobs neu laden und einen Testscan starten. Anleitung und technische Erklärung stehen im Repository.

**Ad-hoc signiert, ohne Zertifikat; nicht von Apple notarisiert.** Eine ausdrückliche macOS-Startfreigabe kann erforderlich sein. TCC-Berechtigungen können nicht automatisch vergeben oder nach der Deinstallation stillschweigend entfernt werden.

Die Projektversion 1.0 ist unabhängig von der installierten ClamAV-Engine-Version. ClamAV/Homebrew werden nicht im Download mitgeliefert. Geplanter Scanner, kein Echtzeitschutz.
