# Automated bilingual releases / Automatische zweisprachige Releases

## English

The single source for each version is `docs/RELEASE-VERSION.md`, committed with `VERSION` **before** creating its tag. English comes first (`## English`), followed by German (`## Deutsch`). Start with [.github/RELEASE_TEMPLATE.md](../.github/RELEASE_TEMPLATE.md) and replace every placeholder. Write and review both translations; automation checks their presence and propagates the exact text, but does not translate or judge translation quality.

1. Update `VERSION`, the backend/UI version strings and changelog together. Copy the template to the matching notes file, for example `docs/RELEASE-1.1.md`, and finish both languages. Keep the English and German operating instructions current.
2. Commit and push to `main`. The **Bilingual release** workflow runs release guard tests, isolated runtime tests, an Apple Silicon build, signature/self-tests and package checks. A manual **Run workflow** or a pull request also validates without publishing.
3. After the workflow succeeds and target-Mac acceptance checks are complete, tag that same commit, for example `git tag v1.1` and `git push origin v1.1`. Pushing the version tag starts the automatic release. `vVERSION` must match the file exactly.
4. The workflow builds all three ZIPs, generates checksums, creates a GitHub draft using the exact notes file, downloads the uploaded files, verifies their bytes and documentation, and then publishes the release automatically.

The app ZIP and complete ZIP contain `RELEASE-VERSION.md` at their top level. The source ZIP contains it in `clamav-macos-installer/docs/`; the complete ZIP also includes that source copy. Every ZIP includes both operating guides. GitHub's generated source ZIP/tar archives contain the notes because they are committed before the tag. `SHA256SUMS.txt` is a checksum manifest, not a documentation package.

Missing/empty language sections, template placeholders, mismatched tags, stale package documentation, missing guides or incorrect checksums stop the process. Build/test/upload failures also prevent publication. The workflow uses GitHub's built-in token; no personal token is required. Only the tag publication job receives repository write permission. Existing releases are never overwritten. If an upload/verification fails, inspect and remove the incomplete draft before rerunning; fix source issues in a new version instead of rewriting a published tag. Repository Actions permissions or rules must permit this workflow.

Local checks (macOS Apple Silicon, Xcode tools and Python 3):

```sh
python3 scripts/test_release.py
python3 scripts/release_notes.py
python3 scripts/test.py
python3 scripts/build.py
python3 scripts/package.py
python3 scripts/release_notes.py --packages
```

The default build remains ad-hoc signed, without a Developer ID certificate and without Apple notarization. Full Disk Access remains a manual step. Automated tests do not replace a real target-Mac scan/permissions acceptance check. Release notes must describe only checks actually completed.

Implementation: [.github/workflows/release.yml](../.github/workflows/release.yml), [release_notes.py](../scripts/release_notes.py), [publish_release.py](../scripts/publish_release.py). The workflow uses an [Apple Silicon macOS runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [GitHub CLI draft release creation](https://cli.github.com/manual/gh_release_create).

## Deutsch

Die einzige Quelle pro Version ist `docs/RELEASE-VERSION.md`. Diese Datei wird zusammen mit `VERSION` **vor** dem Erstellen des Tags eingecheckt. Zuerst steht Englisch (`## English`), danach Deutsch (`## Deutsch`). Die [Vorlage](../.github/RELEASE_TEMPLATE.md) kopieren und sämtliche Platzhalter ersetzen. Beide Sprachfassungen werden redaktionell geschrieben und geprüft; die Automatik prüft ihr Vorhandensein und übernimmt den Text unverändert, übersetzt ihn aber nicht und bewertet nicht die Qualität der Übersetzung.

1. `VERSION`, Versionsangaben in Backend/Oberfläche und Änderungsprotokoll gemeinsam aktualisieren. Die Vorlage beispielsweise als `docs/RELEASE-1.1.md` speichern und beide Sprachfassungen fertigstellen. Beide Bedienungsanleitungen aktuell halten.
2. Änderungen auf `main` übertragen. **Bilingual release** prüft Release-Regeln, isolierte Laufzeittests, den Apple-Silicon-Build, Signatur/Selbsttests und Paketinhalte. Ein manueller **Run workflow** oder Pull Request prüft ebenfalls, ohne zu veröffentlichen.
3. Nach erfolgreicher Prüfung und Abnahme auf einem Ziel-Mac denselben Commit markieren, beispielsweise mit `git tag v1.1` und `git push origin v1.1`. Das Übertragen des Versions-Tags startet die automatische Veröffentlichung. `vVERSION` muss exakt zum Inhalt der Versionsdatei passen.
4. Die Automatik erstellt alle drei ZIPs und Prüfsummen, legt einen GitHub-Entwurf mit der unveränderten Beschreibung an, lädt die hochgeladenen Pakete erneut herunter, prüft deren Bytes und Dokumentation und veröffentlicht anschließend automatisch.

App- und Komplettpaket enthalten `RELEASE-VERSION.md` direkt auf oberster Ebene. Im Quellpaket liegt sie unter `clamav-macos-installer/docs/`; das Komplettpaket enthält zusätzlich diese Quellkopie. Alle ZIPs enthalten beide Bedienungsanleitungen. Auch GitHubs automatisch erzeugte Quellarchive enthalten die Beschreibung, weil sie vor dem Tag eingecheckt wurde. `SHA256SUMS.txt` ist eine Prüfsummenliste, kein Dokumentationspaket.

Fehlende/leere Sprachabschnitte, Platzhalter, abweichende Versions-Tags, veraltete Texte im Paket, fehlende Anleitungen oder falsche Prüfsummen stoppen den Ablauf. Auch Build-, Test- oder Uploadfehler verhindern die Veröffentlichung. Verwendet wird GitHubs eingebautes Token; ein persönliches Token ist nicht erforderlich. Nur der Veröffentlichungsjob für Versions-Tags erhält Schreibrechte. Bestehende Releases werden nicht überschrieben. Nach einem Upload-/Prüffehler den unvollständigen Entwurf prüfen und entfernen, bevor der Lauf erneut gestartet wird. Fehler im Quellcode mit einer neuen Version beheben; veröffentlichte Tags nicht umschreiben. Die Actions-Berechtigungen und Repository-Regeln müssen den Ablauf erlauben.

Die oben genannten lokalen Prüfkommandos gelten ebenso für die deutsche Anleitung. Der Build bleibt ad-hoc signiert, ohne Developer-ID-Zertifikat und ohne Apple-Notarisierung. Festplattenvollzugriff muss weiterhin manuell erteilt werden. Automatisierte Tests ersetzen keine echte Prüfung von Scan und Berechtigungen auf einem Ziel-Mac. In der Release-Beschreibung nur tatsächlich durchgeführte Prüfungen angeben.
