# Installation und Bedienung

## Voraussetzungen

Apple Silicon (ARM64), macOS 14 oder neuer, Internetzugang und genügend Speicher/RAM für ClamAV. Homebrew muss die verwendete macOS-Version unterstützen. Die App verwendet `/opt/homebrew` und benötigt das macOS-Werkzeug `/usr/bin/lockf`. Intel-Macs werden nicht unterstützt.

## Installation

ZIP vom GitHub-Release entpacken, App öffnen und **Installieren / aktualisieren** wählen. Homebrew wird bei Bedarf über seinen offiziellen Installer eingerichtet; notwendige Administratorabfragen erscheinen in der App. Passwörter nicht in normale Protokollfelder eingeben. Die normalen Homebrew-Installationsbestätigungen sind durch diese Aktion autorisiert. Fremde Homebrew-Taps werden nicht automatisch als vertrauenswürdig eingestuft.

Der Installer aktualisiert Homebrew-Paketinformationen, prüft die Formel `homebrew/core/clamav`, installiert oder aktualisiert sie und lädt die Signaturen. Bei Netzwerkproblemen, gesperrten Versionen oder nicht passenden Versionsinformationen meldet er einen Fehler. „Neueste Version“ bedeutet die aktuelle stabile Version dieser Homebrew-Formel zum Installationszeitpunkt; spätere automatische Updates aktualisieren **Signaturen**, nicht die ClamAV-Programmversion.

Die erste Signaturinitialisierung und die Startphase des Scanners können dauern. Die App zeigt Schritte und laufende Ausgaben. Schrittfortschritt ist keine Zeitprognose; für Scans wird keine erfundene Prozentzahl angezeigt.

## Festplattenvollzugriff: ein manueller Schritt bleibt

macOS erlaubt keine stillschweigende Vergabe von TCC/Festplattenvollzugriff durch diesen Installer.

1. **Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff** öffnen.
2. `/bin/bash` sowie den von der App angezeigten Scanner `/opt/homebrew/opt/clamav/bin/clamdscan` hinzufügen/aktivieren. Die App zeigt auch dessen realen Versionspfad an.
3. Danach über die App die Hintergrundjobs neu laden und einen Scan starten.
4. Das Scanprotokoll auf Zugriffsfehler prüfen. Nach einem Programmupgrade kann eine erneute Freigabe nötig sein.

Der Scan läuft mit `clamdscan --fdpass`: der Client öffnet Dateien und übergibt Deskriptoren über den privaten Socket. Nur Terminal oder nur `clamd` freizugeben reicht für diesen Job nicht. Die Freigabe für `/bin/bash` gilt auch für andere darüber gestartete Skripte; entscheide bewusst, ob du sie erteilen willst.

## Automatik und Ergebnisse

Benutzerbezogene launchd-Jobs prüfen täglich um 19:00 Uhr Downloads, Schreibtisch und Dokumente; Signaturupdates laufen alle zwei Stunden. Eine angemeldete Benutzersitzung ist erforderlich. Schlafmodus und Abmeldung können die Ausführung verzögern; der Zeitpunkt ist keine Garantie, dass der Mac aufgeweckt wird.

Ein manueller Start fordert denselben Hintergrundjob an. „Angefordert“ ist noch kein Scanabschluss. Der Status und das jeweils aktuelle Scanprotokoll zeigen Ende, Funde, Fehler und nicht verschobene Dateien. Hinweise zu Größenlimits oder Zugriffsfehlern nicht als vollständigen erfolgreichen Scan interpretieren.

Logs: `~/Library/Logs/ClamAV-Automatik`. Eigene Konfiguration/Signaturen/Quarantäne: `~/.clamav-automatik`. Die Anzeige unterstützt sechs Sprachen; technische Originalausgaben können Englisch oder Deutsch bleiben.

## Quarantäne

Jeder Scan nutzt einen eigenen privaten Quarantäneordner. Funde werden dort gesammelt; Namenskonflikte und fehlgeschlagene Verschiebungen werden im Bericht berücksichtigt. Es gibt keine automatische Löschung der Quarantäne. Ein Fund kann auch ein Fehlalarm sein. Eine Wiederherstellung ist bewusst manuell und darf vorhandene Dateien am Ziel nicht überschreiben. Weitere Grenzen: 256 MB pro Datei, 512 MB entpackte Daten pro Container; verschlüsselte und nur in der Cloud liegende Inhalte können nicht vollständig geprüft werden.

## Deinstallation

Die eigene Automatik kann entfernt werden, während das Homebrew-Paket erhalten bleibt. Die Paketentfernung ist eine zusätzliche Auswahl. Eigene Konfigurationen, Signaturen und Quarantäne werden in einem eindeutigen Archiv unter `~/.clamav-automatik-archiv` gesichert; Logs bleiben erhalten. Homebrew selbst und fremde Konfigurationen bleiben bestehen.

Paketreste ohne `INSTALL_RECEIPT.json` werden nach erfolgreicher Sicherheitsprüfung atomar in ein privates Archiv verschoben und gegen ein SHA-256-Manifest geprüft. Laufende Prozesse/Jobs, Paketabhängigkeiten, aktive Verknüpfungen, unbekannte Strukturen oder noch gültig registrierte Pakete werden nicht erzwungen entfernt. Bei verschiedenen Dateisystemen oder unzureichenden Rechten bleibt die Wiederherstellung offen und der Rest erhalten. Bekannte geschützte Programmordner können über **ClamAV-Paket entfernen…** gezielt mit Administratorbestätigung repariert werden.

**Berechtigungen bleiben in macOS erhalten.** Nach erfolgreicher Deinstallation öffnet die App den Festplattenvollzugriff und weist darauf hin. Entferne dort nur nicht mehr benötigte Einträge; andere Apps können die Bash-Freigabe weiterhin verwenden.
