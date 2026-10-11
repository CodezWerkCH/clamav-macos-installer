# Fehlerbehebung

- **Scan nur angefordert:** Auf echten Jobstart und Abschluss im Status/aktuellen Protokoll achten. Ein laufender Daemon allein beweist keinen laufenden Scan.
- **Operation not permitted / nicht lesbar:** Festplattenvollzugriff für die angezeigten Programme prüfen, Hintergrundjobs neu laden und erneut testen. Datei-/Cloud-Zustand ebenfalls prüfen. Alte Logeinträge nicht mit neuen Ergebnissen verwechseln.
- **Kein clamd-Socket:** Die Einrichtung muss zuerst Signaturen laden und den eigenen Daemon starten. Nicht den unkonfigurierten Homebrew-Standardsocket mit dem privaten Socket dieser App verwechseln. Installations-/Daemon-Log lesen.
- **No such keg nach Deinstallation:** Version 1.0 prüft automatisch auf unregistrierte Reste und archiviert geeignete, unbenutzte Verzeichnisse. Bei Schutzrechten die Paketentfernung erneut über die App ausführen. Bei aktiven Jobs/Abhängigkeiten diese erst geordnet beenden/klären. Kein blindes `sudo rm -rf` verwenden.
- **Archivierung nicht möglich:** Pfad und Ursache aus dem Fehler prüfen. Bei anderem Dateisystem, fehlenden Leserechten, unbekannter Struktur oder verbliebenem Installationsnachweis bleibt der Rest bestehen. Die App meldet keinen vollständigen Erfolg.
- **Homebrew-Tap-Warnung:** Fremde Taps werden nicht automatisch vertraut. Der Installer verwendet gezielt `homebrew/core/clamav`; ändere fremde Vertrauenseinstellungen nur bewusst.
- **Mitteilungen fehlen:** macOS-Mitteilungseinstellungen für die App prüfen; der Scanstatus steht unabhängig davon in den Logs.
- **macOS blockiert die App:** Diese Ausgabe ist ad-hoc signiert, ohne Zertifikat und nicht notarisiert. Quelle prüfen und gegebenenfalls die explizite Systemfreigabe verwenden; nicht den gesamten Systemschutz deaktivieren.
- **Berechtigungen nach Entfernung noch sichtbar:** Das ist ein eigener macOS-Datenschutzstatus. Nach Deinstallation öffnet die App die Einstellungen; nicht mehr benötigte Einträge manuell entfernen.

Bei Fehlerberichten: App-/macOS-Version, Aktion, genaue Fehlermeldung und nur relevante anonymisierte Protokollzeilen angeben. Dateinamen, persönliche Pfade, Quarantäneinhalte und Zugangsdaten nicht öffentlich posten.
