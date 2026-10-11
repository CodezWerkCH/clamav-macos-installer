#!/bin/bash
# ClamAV Automatik 1.0 — macOS / Apple Silicon, Bash 3.2 compatible.
# Install: /bin/bash ClamAV-macOS-Apple-Silicon-installieren.sh
# No root execution. No silent TCC/FDA changes. No automatic file deletion.
# This file is also the installed runtime; do not move it out of bin/ afterwards.
set -Eeuo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C

VERSION=1.0
BASE="$HOME/.clamav-automatik"
ARCHIVES="$HOME/.clamav-automatik-archiv"
MANAGEMENT_LOCK="$HOME/.clamav-automatik-management.lock"
LOGS="$HOME/Library/Logs/ClamAV-Automatik"
AGENTS="$HOME/Library/LaunchAgents"
PREFIX=/opt/homebrew
OPT="$PREFIX/opt/clamav"
CONF="$BASE/etc/clamd.conf"
FRESHCONF="$BASE/etc/freshclam.conf"
INSTALLED="$BASE/bin/clamav-automatik.sh"
DOMAIN="gui/$(/usr/bin/id -u)"
LABEL=local.clamav.automatik
MARKER='ClamAV-Automatik-managed-v1'
TEMP_FILES=()
CHILD=''
RESTORE_JOBS=()
RESTORE_PIDS=()
RESTORE_PENDING=()
UNINSTALL_ARCHIVE=''
UNINSTALL_COMMITTED=no
FORMULA=homebrew/core/clamav
EXPECTED_VERSION=''
LEGACY_ARCHIVE=''
LEGACY_COMMITTED=no
LEGACY_FILES=()
LEGACY_RELS=()
LEGACY_LOADED=()
LEGACY_ORIGINAL_FILES=()
LEGACY_ORIGINAL_RELS=()
LEGACY_RESTORE_JOBS=()
LEGACY_RESTORE_PIDS=()
LEGACY_RESTORE_PENDING=()
LEGACY_FOUND=no
LEGACY_BUSY=no

say() { printf '%s\n' "$*"; }
event() { printf '@@CLAMAV:%s\n' "$*"; }
die() { event "ERROR:$*" >&2; printf 'FEHLER: %s\n' "$*" >&2; exit 2; }
brew_cmd() { "$PREFIX/bin/brew" "$@"; }
launchctl_cmd() { /bin/launchctl "$@"; }
cleanup() {
    local rc=$? p kind target i=0 pid pending
    if [ "$rc" -ne 0 ]; then
        legacy_rollback || true
        # Roll back a partially completed removal. Never overwrite a new file.
        if [ -n "$UNINSTALL_ARCHIVE" ] && [ "$UNINSTALL_COMMITTED" != yes ]; then
            if [ ! -e "$BASE" ] && [ ! -L "$BASE" ] && [ -d "$UNINSTALL_ARCHIVE/installation" ]; then
                /bin/mv "$UNINSTALL_ARCHIVE/installation" "$BASE" || true
            fi
            for kind in scan update clamd; do
                p="$UNINSTALL_ARCHIVE/launchagents/$LABEL.$kind.plist"
                target="$AGENTS/$LABEL.$kind.plist"
                if [ -f "$p" ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then /bin/cp -p "$p" "$target" || true; fi
            done
        fi
        # Failed upgrades/removals retain old files and restore previously active
        # owned jobs whenever their runtime is still available.
        if [ -d "$BASE" ] && [ -x "$OPT/sbin/clamd" ]; then
            for kind in ${RESTORE_JOBS[@]+"${RESTORE_JOBS[@]}"}; do
                pid="${RESTORE_PIDS[$i]}"; pending="${RESTORE_PENDING[$i]}"; i=$((i+1))
                if [ "$pending" = yes ] && ! wait_job_stopped "$LABEL.$kind" "$pid"; then
                    say "WARNUNG: Job oder alter Prozess ist noch aktiv; kein zweiter Job wird gestartet: $LABEL.$kind (PID $pid)" >&2
                    continue
                fi
                ( bootstrap_job "$kind" ) || say "WARNUNG: Job konnte nicht wiederhergestellt werden: $kind" >&2
            done
        fi
    fi
    for p in ${TEMP_FILES[@]+"${TEMP_FILES[@]}"}; do /bin/rm -f "$p"; done
    # Do not unlink kernel lock files: that would allow two different inodes.
    exec 7>&- 8>&- 9>&-
}
interrupted() {
    trap - INT TERM HUP
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM HUP
trap 'rc=$?; event "ERROR:command_failed:$rc:$LINENO" >&2; printf "FEHLER in Zeile %s (Status %s). Installation/Job nicht vollstaendig.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

usage() {
    cat <<'HELP'
ClamAV Automatik — macOS Apple Silicon
  Ohne Argument / --install : installieren oder eigene Installation reparieren
  --allow-parallel          : Installation trotz fremder ClamAV-Jobs (bewusst!)
  --status                 : Jobs, Scanner und letzte Ergebnisse anzeigen
  --scan-now               : echten launchd-Scan jetzt anfordern
  --restart                : eigene Jobs nach FDA-Aenderungen neu laden
  --stop                   : eigene Jobs entladen; Daten/Quarantaene behalten
  --uninstall              : eigene Jobs entfernen, Daten sicher archivieren
  --uninstall-package      : zusaetzlich ungeteiltes ClamAV-Paket entfernen
  --repair-uninstall-package : nur GUI: bekannte Paket-Rechte reparieren und entfernen
  --legacy-status          : alte manuelle Konfiguration nur pruefen
  --uninstall-legacy       : verifizierte alte Benutzer-Jobs/Skript archivieren
  --help                   : diese Hilfe
Interne Job-Aufrufe: --scan, --update
Nicht mit sudo ausfuehren. Festplattenvollzugriff muss manuell erteilt werden.
Installation aktualisiert Homebrew und ClamAV auf die neueste stabile Core-Version.
Deinstallation behaelt Homebrew, Logs und ein Archiv aller eigenen Daten.
HELP
}

platform_check() {
    [ "$(/usr/bin/uname -s)" = Darwin ] || die 'Nur fuer macOS.'
    [ "$(/usr/bin/uname -m)" = arm64 ] || die 'Nativ in einem Apple-Silicon-Terminal starten, nicht unter Rosetta.'
    [ "$(/usr/bin/id -u)" -ne 0 ] || die 'Als angemeldeter Benutzer ohne sudo starten.'
    [ -x /usr/bin/lockf ] || die 'Das macOS-Systemwerkzeug /usr/bin/lockf fehlt. Ein aktuelles macOS wird benoetigt.'
    [ -n "$HOME" ] && [ "$HOME" != / ] && [ -d "$HOME" ] || die 'Ungueltiges HOME.'
    case "$HOME" in
        *$'\n'*|*$'\r'*|*'"'*|*'\'*) die 'Der Home-Pfad enthaelt fuer ClamAV-Konfigurationen nicht unterstuetzte Zeichen.' ;;
    esac
    [ "${#BASE}" -lt 85 ] || die 'Home-Pfad zu lang fuer einen sicheren macOS-Unix-Socket.'
}

# Never follow a symlink into a different managed tree. Only chmod our own dirs.
private_dir() {
    local d="$1"
    [ ! -L "$d" ] || die "Symlink statt privatem Verzeichnis: $d"
    if [ ! -e "$d" ]; then /bin/mkdir "$d"; fi
    [ -d "$d" ] && [ -O "$d" ] || die "Verzeichnis gehoert nicht diesem Benutzer: $d"
    /bin/chmod 700 "$d"
}

assert_managed() {
    [ ! -L "$BASE" ] && [ -O "$BASE" ] && [ -d "$BASE" ] || die 'Verwaltete Installation fehlt.'
    [ -f "$BASE/.owner" ] && [ ! -L "$BASE/.owner" ] || die 'Installationsmarkierung fehlt.'
    [ "$(/bin/cat "$BASE/.owner")" = "$MARKER" ] || die 'Unbekannte Installation im Zielordner.'
}

# macOS lockf's FD mode applies flock(2) to a shared open file description.
# Bash retains the descriptor; the kernel releases it when its holders exit.
# There are no stale PID locks to delete or reclaim, even after a crash.
lock() {
    local d="$BASE/run/$1.lock" fd rc=0
    if [ "$1" = install ]; then
        # Never archive/unlink this inode: a removal must continue excluding
        # installers until optional Homebrew package removal has also finished.
        d="$MANAGEMENT_LOCK"
    else
        [ ! -L "$BASE/run" ] && [ -d "$BASE/run" ] && [ -O "$BASE/run" ] || die 'Ungueltiges privates Sperrverzeichnis.'
    fi
    [ ! -L "$d" ] || die "Symlink statt Sperrdatei: $d"
    [ ! -e "$d" ] || { [ -f "$d" ] && [ -O "$d" ]; } || die "Ungueltige Sperrdatei: $d"
    case "$1" in
        install) exec 7>>"$d"; fd=7 ;;
        scan) exec 8>>"$d"; fd=8 ;;
        update) exec 9>>"$d"; fd=9 ;;
        *) die 'Unbekannte Sperre.' ;;
    esac
    /usr/bin/lockf -s -t 0 "$fd" || rc=$?
    [ "$rc" -ne 75 ] || return 1
    [ "$rc" -eq 0 ] || die "Sperre konnte nicht erstellt werden (Status $rc): $d"
}

notify_user() {
    local title="$1" body="$2" language="${CLAMAV_LANGUAGE:-}"
    # Read one plain value, never execute/source the saved preference.
    if [ -z "$language" ] && [ -n "${BASE:-}" ] && [ -f "$BASE/etc/language" ] && [ ! -L "$BASE/etc/language" ] && [ -O "$BASE/etc/language" ]; then
        IFS= read -r language < "$BASE/etc/language" || true
    fi
    case "$language" in de|en|fr|it|pt|es) ;; *) language=de ;; esac
    case "$language:$title" in
        de:'ClamAV: Update fehlgeschlagen') title='ClamAV: Update fehlgeschlagen'; body='Signaturen konnten nicht aktualisiert werden. Bitte Update-Log prüfen.' ;;
        de:'ClamAV: Scan fehlgeschlagen') title='ClamAV: Scan fehlgeschlagen'; body='Der Scanner ist nicht erreichbar. Bitte Status und clamd-Log prüfen.' ;;
        de:'ClamAV: Zugriff fehlt') title='ClamAV: Zugriff fehlt'; body='Downloads, Schreibtisch und Dokumente sind nicht lesbar. Festplattenvollzugriff prüfen.' ;;
        de:'ClamAV: Scan unvollstaendig') title='ClamAV: Scan unvollständig'; body='Keine verlässliche Scan-Zusammenfassung vorhanden. Bitte Log prüfen.' ;;
        de:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV: Scan braucht Aufmerksamkeit'; body="Funde: ${infected:-0}. Fehler: ${errors:-0}. Nicht verschoben: ${not_moved:-0}. Bitte Log prüfen." ;;
        de:'ClamAV: Dateien in Quarantaene') title='ClamAV: Dateien in Quarantäne'; body="Funde: ${infected:-0}. Details und Ursprungspfade stehen im Scan-Log." ;;
        de:'ClamAV eingerichtet') title='ClamAV eingerichtet'; body='Bitte Festplattenvollzugriff manuell erlauben und danach den geplanten Scan testen.' ;;

        en:'ClamAV: Update fehlgeschlagen') title='ClamAV: Update failed'; body='Virus signatures could not be updated. Check the update log.' ;;
        en:'ClamAV: Scan fehlgeschlagen') title='ClamAV: Scan failed'; body='The scanner is unreachable. Check its status and the clamd log.' ;;
        en:'ClamAV: Zugriff fehlt') title='ClamAV: Access required'; body='Downloads, Desktop and Documents cannot be read. Check Full Disk Access.' ;;
        en:'ClamAV: Scan unvollstaendig') title='ClamAV: Scan incomplete'; body='No reliable scan summary is available. Check the log.' ;;
        en:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV: Scan needs attention'; body="Detections: ${infected:-0}. Errors: ${errors:-0}. Not moved: ${not_moved:-0}. Check the log." ;;
        en:'ClamAV: Dateien in Quarantaene') title='ClamAV: Files quarantined'; body="Detections: ${infected:-0}. Details and original paths are in the scan log." ;;
        en:'ClamAV eingerichtet') title='ClamAV is set up'; body='Grant Full Disk Access manually, then test the scheduled scan.' ;;

        fr:'ClamAV: Update fehlgeschlagen') title='ClamAV : échec de la mise à jour'; body='Impossible de mettre à jour les signatures antivirus. Consultez le journal des mises à jour.' ;;
        fr:'ClamAV: Scan fehlgeschlagen') title='ClamAV : échec de l’analyse'; body='Le moteur d’analyse est inaccessible. Vérifiez son état et le journal clamd.' ;;
        fr:'ClamAV: Zugriff fehlt') title='ClamAV : accès requis'; body='Téléchargements, Bureau et Documents sont illisibles. Vérifiez l’accès complet au disque.' ;;
        fr:'ClamAV: Scan unvollstaendig') title='ClamAV : analyse incomplète'; body='Aucun résumé d’analyse fiable n’est disponible. Consultez le journal.' ;;
        fr:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV : analyse à vérifier'; body="Détections : ${infected:-0}. Erreurs : ${errors:-0}. Fichiers non déplacés : ${not_moved:-0}. Consultez le journal." ;;
        fr:'ClamAV: Dateien in Quarantaene') title='ClamAV : fichiers en quarantaine'; body="Détections : ${infected:-0}. Les détails et les chemins d’origine figurent dans le journal d’analyse." ;;
        fr:'ClamAV eingerichtet') title='ClamAV est configuré'; body='Autorisez manuellement l’accès complet au disque, puis testez l’analyse planifiée.' ;;

        it:'ClamAV: Update fehlgeschlagen') title='ClamAV: aggiornamento non riuscito'; body='Impossibile aggiornare le firme antivirus. Controlla il registro degli aggiornamenti.' ;;
        it:'ClamAV: Scan fehlgeschlagen') title='ClamAV: scansione non riuscita'; body='Il motore di scansione non è raggiungibile. Controlla lo stato e il registro clamd.' ;;
        it:'ClamAV: Zugriff fehlt') title='ClamAV: accesso richiesto'; body='Download, Scrivania e Documenti non sono leggibili. Controlla Accesso completo al disco.' ;;
        it:'ClamAV: Scan unvollstaendig') title='ClamAV: scansione incompleta'; body='Non è disponibile un riepilogo affidabile della scansione. Controlla il registro.' ;;
        it:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV: scansione da verificare'; body="Rilevamenti: ${infected:-0}. Errori: ${errors:-0}. File non spostati: ${not_moved:-0}. Controlla il registro." ;;
        it:'ClamAV: Dateien in Quarantaene') title='ClamAV: file in quarantena'; body="Rilevamenti: ${infected:-0}. I dettagli e i percorsi originali sono nel registro della scansione." ;;
        it:'ClamAV eingerichtet') title='ClamAV è configurato'; body='Concedi manualmente Accesso completo al disco, poi prova la scansione pianificata.' ;;

        pt:'ClamAV: Update fehlgeschlagen') title='ClamAV: falha na atualização'; body='Não foi possível atualizar as assinaturas antivírus. Consulte o registo de atualizações.' ;;
        pt:'ClamAV: Scan fehlgeschlagen') title='ClamAV: falha na análise'; body='O motor de análise está inacessível. Verifique o estado e o registo do clamd.' ;;
        pt:'ClamAV: Zugriff fehlt') title='ClamAV: acesso necessário'; body='Não é possível ler Descargas, Secretária e Documentos. Verifique o Acesso total ao disco.' ;;
        pt:'ClamAV: Scan unvollstaendig') title='ClamAV: análise incompleta'; body='Não está disponível um resumo fiável da análise. Consulte o registo.' ;;
        pt:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV: análise requer atenção'; body="Deteções: ${infected:-0}. Erros: ${errors:-0}. Ficheiros não movidos: ${not_moved:-0}. Consulte o registo." ;;
        pt:'ClamAV: Dateien in Quarantaene') title='ClamAV: ficheiros em quarentena'; body="Deteções: ${infected:-0}. Os detalhes e os caminhos originais estão no registo da análise." ;;
        pt:'ClamAV eingerichtet') title='ClamAV está configurado'; body='Conceda manualmente Acesso total ao disco e teste a análise agendada.' ;;

        es:'ClamAV: Update fehlgeschlagen') title='ClamAV: actualización fallida'; body='No se han podido actualizar las firmas antivirus. Consulta el registro de actualizaciones.' ;;
        es:'ClamAV: Scan fehlgeschlagen') title='ClamAV: análisis fallido'; body='No se puede acceder al motor de análisis. Comprueba su estado y el registro de clamd.' ;;
        es:'ClamAV: Zugriff fehlt') title='ClamAV: se requiere acceso'; body='No se pueden leer Descargas, Escritorio y Documentos. Comprueba Acceso total al disco.' ;;
        es:'ClamAV: Scan unvollstaendig') title='ClamAV: análisis incompleto'; body='No hay un resumen fiable del análisis. Consulta el registro.' ;;
        es:'ClamAV: Scan braucht Aufmerksamkeit') title='ClamAV: revisa el análisis'; body="Detecciones: ${infected:-0}. Errores: ${errors:-0}. Archivos no movidos: ${not_moved:-0}. Consulta el registro." ;;
        es:'ClamAV: Dateien in Quarantaene') title='ClamAV: archivos en cuarentena'; body="Detecciones: ${infected:-0}. Los detalles y las rutas originales están en el registro del análisis." ;;
        es:'ClamAV eingerichtet') title='ClamAV está configurado'; body='Concede manualmente Acceso total al disco y prueba el análisis programado.' ;;
    esac
    # argv instead of interpolating text, paths or signature names into AppleScript.
    /usr/bin/osascript - "$title" "$body" <<'APPLESCRIPT' || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

save_language() {
    local language="${CLAMAV_LANGUAGE:-}" tmp target="$BASE/etc/language"
    case "$language" in '') return 0 ;; de|en|fr|it|pt|es) ;; *) die 'Ungueltige Oberflaechensprache.' ;; esac
    [ ! -L "$target" ] || die 'Symlink statt Sprachdatei.'
    [ ! -e "$target" ] || { [ -f "$target" ] && [ -O "$target" ]; } || die 'Ungueltige Sprachdatei.'
    tmp=$(/usr/bin/mktemp "$BASE/run/language.XXXXXX")
    TEMP_FILES+=("$tmp")
    printf '%s\n' "$language" > "$tmp"
    /bin/chmod 600 "$tmp"
    /bin/mv -f "$tmp" "$target"
}

scanner_ready() {
    "$OPT/bin/clamdscan" --config-file="$CONF" --ping=1:1 >/dev/null 2>&1
}

wait_ready() {
    local i
    for ((i=0; i<60; i++)); do
        if scanner_ready; then return 0; fi
        /bin/sleep 2
    done
    return 1
}

save_status() {
    local kind="$1" message="$2" tmp
    tmp=$(/usr/bin/mktemp "$BASE/run/status.XXXXXX")
    printf '%s | %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')" "$message" > "$tmp"
    /bin/mv -f "$tmp" "$LOGS/last-$kind.txt"
}

update_database() {
    local report rc=0 stamp
    assert_managed
    lock update || { say 'Ein Update/eine Installation laeuft bereits.'; return 0; }
    stamp=$(/bin/date '+%Y%m%d-%H%M%S')
    report=$(/usr/bin/mktemp "$LOGS/update-$stamp.XXXXXX")
    say "Signaturupdate: $report"
    "$OPT/bin/freshclam" --config-file="$FRESHCONF" --stdout > "$report" 2>&1 &
    CHILD=$!
    wait "$CHILD" || rc=$?
    CHILD=''
    /bin/cat "$report"
    if [ "$rc" -ne 0 ]; then
        save_status update "FEHLER: freshclam Status $rc; Details: $report"
        notify_user 'ClamAV: Update fehlgeschlagen' 'Signaturen konnten nicht aktualisiert werden. Bitte Update-Log pruefen.'
        return 2
    fi
    # SelfCheck is a fallback if an explicit reload cannot be delivered yet.
    if scanner_ready; then
        if ! "$OPT/bin/clamdscan" --config-file="$CONF" --reload >> "$report" 2>&1; then
            save_status update "WARNUNG: Update OK, Reload fehlgeschlagen; SelfCheck/clamd-Log pruefen: $report"
            return 2
        fi
    fi
    save_status update "OK: freshclam erfolgreich; $report"
}

# Parse only ClamAV's final summary, never use reported filenames as commands.
summary_counts() {
    /usr/bin/awk '
      /^----------- SCAN SUMMARY -----------$/ {seen=1; infected=""; errors=0; moved=0; next}
      seen && /^Infected files: [0-9]+$/ {infected=$3}
      seen && /^Total errors: [0-9]+$/ {errors=$3}
      seen && /^Not moved: [0-9]+$/ {moved=$3}
      END {if (!seen || infected=="") exit 1; print infected, errors, moved}
    ' "$1"
}

daily_scan() {
    local report rc=0 q stamp d counts infected errors not_moved pre_errors=0
    local roots=()
    assert_managed
    lock scan || { say 'Ein Scan/eine Installation laeuft bereits.'; return 0; }
    stamp=$(/bin/date '+%Y%m%d-%H%M%S')
    report=$(/usr/bin/mktemp "$LOGS/scan-$stamp.XXXXXX")
    say "Scan-Log: $report"
    save_status scan "LAEUFT: $report"
    if ! wait_ready; then
        say 'FEHLER: clamd antwortet nicht.' >> "$report"
        save_status scan "FEHLER: clamd nicht erreichbar; $report"
        notify_user 'ClamAV: Scan fehlgeschlagen' 'Der Scanner ist nicht erreichbar. Bitte Status und clamd-Log pruefen.'
        return 2
    fi
    for d in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"; do
        # Symlink roots are deliberately not followed into other trees.
        if [ -d "$d" ] && [ ! -L "$d" ] && /bin/ls -A "$d" >/dev/null 2>>"$report"; then
            roots+=("$d")
        else
            printf 'FEHLER: Ziel fehlt, ist ein Symlink oder ist nicht lesbar: %q\n' "$d" >> "$report"
            pre_errors=$((pre_errors+1))
        fi
    done
    if [ "${#roots[@]}" -eq 0 ]; then
        save_status scan "FEHLER: kein Scanziel lesbar (TCC/FDA pruefen); $report"
        notify_user 'ClamAV: Zugriff fehlt' 'Downloads, Desktop und Dokumente sind nicht lesbar. Festplattenvollzugriff pruefen.'
        return 2
    fi
    q=$(/usr/bin/mktemp -d "$BASE/quarantine/$stamp.XXXXXX")
    # Metadata stays outside payload/, so malware cannot collide with a report.
    /bin/mkdir "$q/payload"
    printf '%s\0' "${roots[@]}" > "$q/scan-roots.nul"
    printf '%s\n' "$report" > "$q/report-path.txt"
    printf 'Beginn: %s\nQuarantaene: %s\n' "$(/bin/date)" "$q/payload" >> "$report"
    # ClamAV >= 1.5.4 reserves quarantine targets exclusively, resolves duplicate
    # basenames itself, and checks source identity. Never use --remove.
    "$OPT/bin/clamdscan" --config-file="$CONF" --fdpass --multiscan --infected \
        --move="$q/payload" "${roots[@]}" >> "$report" 2>&1 &
    CHILD=$!
    wait "$CHILD" || rc=$?
    CHILD=''
    /bin/cp -p "$report" "$q/scan-report.txt"
    if ! counts=$(summary_counts "$report"); then
        save_status scan "FEHLER: Scan ohne gueltige Zusammenfassung (Status $rc); $report"
        notify_user 'ClamAV: Scan unvollstaendig' 'Keine verlaessliche Scan-Zusammenfassung vorhanden. Bitte Log pruefen.'
        return 2
    fi
    read -r infected errors not_moved <<< "$counts"
    errors=$((errors+pre_errors))
    if [ "$rc" -gt 1 ] || [ "$errors" -gt 0 ] || [ "$not_moved" -gt 0 ]; then
        save_status scan "UNVOLLSTAENDIG: Funde=$infected Fehler=$errors Nicht_verschoben=$not_moved Status=$rc; $report"
        notify_user 'ClamAV: Scan braucht Aufmerksamkeit' "Funde: $infected. Fehler: $errors. Nicht verschoben: $not_moved. Bitte Log pruefen."
        return 2
    fi
    if [ "$infected" -gt 0 ]; then
        save_status scan "FUNDE: $infected; Quarantaene: $q/payload; $report"
        notify_user 'ClamAV: Dateien in Quarantaene' "$infected Fund(e). Details und Ursprungspfade stehen im Scan-Log."
    else
        save_status scan "OK: keine Bedrohung erkannt (Scan-Grenzen beachten); $report"
        # Remove only an empty payload directory; never delete quarantined data.
        if /bin/rmdir "$q/payload" 2>/dev/null; then
            /bin/rm -f "$q/scan-roots.nul" "$q/report-path.txt" "$q/scan-report.txt"
            /bin/rmdir "$q"
        fi
    fi
    # Infection handled successfully is a successful scheduled job, not a retry.
    return 0
}

foreign_jobs() {
    local file content found=0 cmd
    # Existing user/system launchd definitions, including unloaded ones.
    for file in "$AGENTS"/*.plist /Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist; do
        [ -f "$file" ] || continue
        case "$file" in "$AGENTS/$LABEL.clamd.plist"|"$AGENTS/$LABEL.update.plist"|"$AGENTS/$LABEL.scan.plist")
            if [ ! -L "$file" ] && [ -O "$file" ] && /usr/bin/grep -q "$MARKER" "$file"; then continue; fi ;;
        esac
        content=$(/usr/bin/plutil -convert xml1 -o - "$file" 2>/dev/null) || continue
        if printf '%s\n' "$content" | /usr/bin/grep -Eiq 'clamav|clamd|freshclam|clamscan'; then
            say "Bestehender ClamAV-Job: $file" >&2
            found=1
        fi
    done
    while IFS= read -r cmd; do
        case "$cmd" in *"$CONF"*|*"$FRESHCONF"*) continue ;; esac
        say "Bestehender Scanner/Updater: $cmd" >&2
        found=1
    done < <(/bin/ps -axo comm=,args= | /usr/bin/awk '$1 ~ /(^|\/)(clamd|freshclam|clamscan|clamdscan)$/')
    # Cron jobs are not changed, either.
    if /usr/bin/crontab -l 2>/dev/null | /usr/bin/grep -Eiv '^[[:space:]]*#' | /usr/bin/grep -Eiq 'clamav|clamd|freshclam|clamscan'; then
        say 'Bestehender ClamAV-Eintrag in der Benutzer-crontab.' >&2
        found=1
    fi
    return "$found"
}

xml() {
    local s="$1"
    s=${s//&/\&amp;}; s=${s//</\&lt;}; s=${s//>/\&gt;}
    s=${s//\"/\&quot;}; s=${s//\'/\&apos;}
    printf '%s' "$s"
}

backup_file() {
    local source="$1" dest
    dest=$(/usr/bin/mktemp "$BASE/backups/$(/usr/bin/basename "$source").XXXXXX")
    /bin/cp -p "$source" "$dest"
    say "Sicherung: $dest"
}

# Replace only files carrying our marker, keeping a backup of each changed file.
put_managed() {
    local source="$1" target="$2" mode="$3"
    [ ! -L "$target" ] || die "Symlink am Dateiziel: $target"
    if [ -e "$target" ]; then
        [ -f "$target" ] && [ -O "$target" ] || die "Ungeeignetes Dateiziel: $target"
        /usr/bin/grep -q "$MARKER" "$target" || die "Fremde Datei wird nicht ueberschrieben: $target"
        if /usr/bin/cmp -s "$source" "$target"; then return 0; fi
        backup_file "$target"
    fi
    /bin/chmod "$mode" "$source"
    /bin/mv -f "$source" "$target"
}

make_plist() {
    local kind="$1" out="$2" executable arg1 arg2 schedule
    if [ "$kind" = clamd ]; then
        executable="$OPT/sbin/clamd"; arg1="--config-file=$CONF"; arg2=--foreground
        schedule='<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>60</integer>'
    else
        executable=/bin/bash; arg1="$INSTALLED"; arg2="--$kind"
        if [ "$kind" = update ]; then
            schedule='<key>RunAtLoad</key><true/><key>StartInterval</key><integer>7200</integer>'
        else
            schedule='<key>StartCalendarInterval</key><dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>0</integer></dict>'
        fi
    fi
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<!-- $MARKER -->
<key>Label</key><string>$LABEL.$kind</string>
<key>ProgramArguments</key><array><string>$(xml "$executable")</string><string>$(xml "$arg1")</string><string>$(xml "$arg2")</string></array>
<key>WorkingDirectory</key><string>$(xml "$BASE")</string>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$(xml "$HOME")</string><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string><key>LC_ALL</key><string>C</string></dict>
<key>Umask</key><integer>63</integer>
<key>ProcessType</key><string>Background</string>
<key>Nice</key><integer>10</integer>
<key>StandardOutPath</key><string>$(xml "$LOGS/launchd-$kind.log")</string>
<key>StandardErrorPath</key><string>$(xml "$LOGS/launchd-$kind.log")</string>
$schedule
</dict></plist>
PLIST
    /usr/bin/plutil -lint "$out" >/dev/null
}

bootstrap_job() {
    local kind="$1"
    assert_owned_job "$kind" || die "Eigene Job-Datei fehlt: $kind"
    launchctl_cmd enable "$DOMAIN/$LABEL.$kind"
    if ! launchctl_cmd print "$DOMAIN/$LABEL.$kind" >/dev/null 2>&1; then
        launchctl_cmd bootstrap "$DOMAIN" "$AGENTS/$LABEL.$kind.plist"
    fi
}

assert_owned_job() {
    local kind="$1" file="$AGENTS/$LABEL.$1.plist" actual executable argument
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 1; fi
    [ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] || die "Ungueltige Job-Datei: $file"
    /usr/bin/grep -q "$MARKER" "$file" || die "Fremder Job bleibt unveraendert: $file"
    actual=$(/usr/bin/plutil -extract Label raw -o - "$file") || die "Job-Datei ist ungueltig: $file"
    [ "$actual" = "$LABEL.$kind" ] || die "Unerwartete Job-Kennung: $file"
    executable=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$file") || die "Job-Programm fehlt: $file"
    argument=$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$file") || die "Job-Argument fehlt: $file"
    if [ "$kind" = clamd ]; then
        [ "$executable" = "$OPT/sbin/clamd" ] && [ "$argument" = "--config-file=$CONF" ] || die "Fremde Job-Konfiguration bleibt unveraendert: $file"
    else
        [ "$executable" = /bin/bash ] && [ "$argument" = "$INSTALLED" ] || die "Fremde Job-Konfiguration bleibt unveraendert: $file"
    fi
}

preflight_jobs() {
    local kind record source
    for kind in clamd update scan; do
        if assert_owned_job "$kind"; then :
        elif launchctl_cmd print "$DOMAIN/$LABEL.$kind" >/dev/null 2>&1; then
            die "Geladener Job ohne eigene Definition wird nicht veraendert: $LABEL.$kind"
        fi
        # Bash 3.2 otherwise runs the inherited ERR trap for an expected
        # nonzero result inside a command substitution, even in an if test.
        if record=$(launchctl_cmd print "$DOMAIN/$LABEL.$kind" 2>/dev/null || exit $?); then
            source=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*path = / {sub(/^[[:space:]]*path = /, ""); print; exit}')
            [ "$source" = "$AGENTS/$LABEL.$kind.plist" ] || die "Geladener Job stammt aus fremder/unklarer Definition: $LABEL.$kind"
        fi
    done
}

# launchctl bootout acknowledges a removal request before launchd has always
# reaped the process and removed the service. Observe both; never force-kill.
# The tiny adapters allow isolated tests without replacing system commands.
job_pid_alive() { /bin/kill -0 "$1" 2>/dev/null; }
shutdown_pause() { /bin/sleep 0.2; }
wait_job_stopped() {
    local label="$1" pid="${2:-0}" tick=0 registered alive
    while :; do
        registered=no; alive=no
        if launchctl_cmd print "$DOMAIN/$label" >/dev/null 2>&1; then registered=yes; fi
        if [ "$pid" != 0 ] && job_pid_alive "$pid"; then alive=yes; fi
        if [ "$registered" = no ] && [ "$alive" = no ]; then return 0; fi
        [ "$tick" -lt 150 ] || return 1
        shutdown_pause || return $?
        tick=$((tick+1))
    done
}

stop_job() {
    local kind="$1" record pid index=-1
    if record=$(launchctl_cmd print "$DOMAIN/$LABEL.$kind" 2>/dev/null || exit $?); then
        assert_owned_job "$kind" || die "Geladener Job ohne eigene Definition bleibt unangetastet: $kind"
        pid=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')
        if [ "${2:-no}" = restore ]; then
            index=${#RESTORE_JOBS[@]}
            RESTORE_JOBS+=("$kind"); RESTORE_PIDS+=("${pid:-0}"); RESTORE_PENDING+=(yes)
        fi
        launchctl_cmd bootout "$DOMAIN/$LABEL.$kind"
        wait_job_stopped "$LABEL.$kind" "${pid:-0}" || die "Job oder alter Prozess wurde nicht innerhalb von 30 Sekunden beendet: $LABEL.$kind"
        if [ "$index" -ge 0 ]; then RESTORE_PENDING[$index]=no; fi
    fi
}

read_clamav_formula_info() {
    local info="$1" name tap
    # A positional match is valid only for a single, identified Core formula.
    # Never interpret an arbitrary installed package as the scanner version.
    name=$(/usr/bin/plutil -extract formulae.0.name raw -o - "$info") || die 'ClamAV-Paketidentitaet fehlt.'
    [ "$name" = clamav ] || die "Unerwartetes Paket in ClamAV-Metadaten: $name"
    if /usr/bin/plutil -extract formulae.1 json -o - "$info" >/dev/null 2>&1; then
        die 'Mehrere Pakete in ClamAV-Metadaten; Versionspruefung abgebrochen.'
    fi
    tap=$(/usr/bin/plutil -extract formulae.0.tap raw -o - "$info") || die 'ClamAV-Paketquelle konnte nicht geprueft werden.'
    [ "$tap" = homebrew/core ] || die "ClamAV stammt nicht aus der offiziellen Homebrew-Core-Quelle: $tap"
    EXPECTED_VERSION=$(/usr/bin/plutil -extract formulae.0.versions.stable raw -o - "$info") || die 'Neueste stabile ClamAV-Version konnte nicht ermittelt werden.'
    printf '%s\n' "$EXPECTED_VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die 'Ungueltige stabile ClamAV-Version in Paketmetadaten.'
}

scanner_version() {
    local output version
    # clamdscan --version contacts the daemon and can report its old version.
    # clamscan queries the installed engine without needing a running socket.
    output=$("$OPT/bin/clamscan" --version) || die 'Installierte Scanner-Version konnte nicht gelesen werden.'
    version=$(printf '%s\n' "$output" | /usr/bin/awk 'NR==1 && $1 == "ClamAV" {split($2,a,"/");print a[1]}')
    printf '%s\n' "$version" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die 'Ungueltige Versionsausgabe des installierten Scanners.'
    [ "$version" = "$EXPECTED_VERSION" ] || die "Aktiver Scanner $version entspricht nicht der neuesten stabilen Homebrew-Version $EXPECTED_VERSION. Homebrew-Verknuepfung pruefen."
    printf '%s\n' "$version"
}

install_latest_clamav() {
    local pinned outdated info
    event STAGE:homebrew_update
    say 'Homebrew-Paketinformationen werden aktualisiert.'
    # A failed refresh is fatal: stale metadata must never be called latest.
    HOMEBREW_NO_INSTALL_CLEANUP=1 brew_cmd update
    pinned=$(brew_cmd list --pinned) || die 'Homebrew-Pins konnten nicht geprueft werden.'
    if printf '%s\n' "$pinned" | /usr/bin/grep -Eq '^(homebrew/core/)?clamav$'; then
        say 'Die ClamAV-Versionssperre wird geloest, um die angeforderte neueste Version zu installieren.'
        brew_cmd unpin "$FORMULA"
    fi
    if brew_cmd list --versions --formula "$FORMULA" >/dev/null 2>&1; then
        event STAGE:clamav_upgrade
        # Installation explicitly authorizes this Core formula and its required
        # dependencies. Disable Homebrew's default y/n prompt only for this
        # command; keep password prompts and tap trust policy unchanged. The
        # explicit flag also wins if brew.env overrides the scoped variable.
        HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew_cmd upgrade --formula "$FORMULA" --no-ask
    else
        event STAGE:clamav_install
        HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew_cmd install --formula "$FORMULA" --no-ask
    fi
    event STAGE:clamav_verify
    outdated=$(HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd outdated --formula --quiet "$FORMULA") || die 'Aktualitaet von ClamAV konnte nicht verifiziert werden.'
    [ -z "$outdated" ] || die "ClamAV ist nach dem Update weiterhin veraltet: $outdated"
    info=$(/usr/bin/mktemp "$BASE/run/formula-info.XXXXXX")
    TEMP_FILES+=("$info")
    HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd info --json=v2 --formula "$FORMULA" > "$info"
    read_clamav_formula_info "$info"
}

initial_signature_update() {
    local report="$1" message
    local update_status=()
    # Keep the private log while forwarding output immediately to the GUI.
    # Capture both statuses before any other command changes PIPESTATUS.
    # A successful tee must never hide a failed freshclam (or vice versa).
    if "$OPT/bin/freshclam" --config-file="$FRESHCONF" --stdout 2>&1 | /usr/bin/tee "$report"; then
        update_status=("${PIPESTATUS[@]}")
    else
        update_status=("${PIPESTATUS[@]}")
    fi
    if [ "${update_status[0]}" -ne 0 ]; then
        message="Signaturupdate fehlgeschlagen (freshclam Status ${update_status[0]}); keine neuen Jobs gestartet. Vorhandene Daten bleiben erhalten. Erneut versuchen; Log: $report"
        event "ERROR:$message" >&2
        say "FEHLER: $message" >&2
        return "${update_status[0]}"
    fi
    if [ "${update_status[1]}" -ne 0 ]; then
        message="Signaturupdate-Protokoll konnte nicht vollstaendig geschrieben werden (Status ${update_status[1]}); keine neuen Jobs gestartet. Vorhandene Daten bleiben erhalten. Log: $report"
        event "ERROR:$message" >&2
        say "FEHLER: $message" >&2
        return "${update_status[1]}"
    fi
}

setup() {
    local allow_parallel="$1" file tmp kind installed_version major minor patch
    local changed_jobs=()
    event STAGE:checking
    launchctl_cmd print "$DOMAIN" >/dev/null 2>&1 || die 'Bitte in einer angemeldeten grafischen macOS-Sitzung starten.'
    lock install || die 'Eine Installation oder Deinstallation laeuft bereits.'
    preflight_jobs
    if ! foreign_jobs; then
        if [ "$allow_parallel" != yes ]; then
            die 'Vorhandene ClamAV-Jobs bleiben unangetastet. Zuerst bewusst stilllegen, oder mit --allow-parallel eine getrennte Zusatzinstallation anlegen.'
        fi
        say 'WARNUNG: Getrennte Zusatzinstallation; bestehende Jobs bleiben aktiv (mehr RAM, doppelte Scans/Downloads moeglich).'
    fi
    if [ -e "$BASE" ] || [ -L "$BASE" ]; then
        assert_managed
    else
        /bin/mkdir "$BASE"
        printf '%s\n' "$MARKER" > "$BASE/.owner"
    fi
    private_dir "$BASE"
    for file in bin etc db run quarantine backups; do private_dir "$BASE/$file"; done
    [ -d "$HOME/Library/Logs" ] && [ ! -L "$HOME/Library/Logs" ] || die 'Library/Logs fehlt oder ist ein Symlink.'
    private_dir "$LOGS"
    [ ! -L "$AGENTS" ] || die 'LaunchAgents darf kein Symlink sein.'
    if [ ! -d "$AGENTS" ]; then /bin/mkdir "$AGENTS"; fi
    [ -O "$AGENTS" ] || die 'LaunchAgents gehoert nicht diesem Benutzer.'
    lock scan || die 'Scan laeuft; nach dessen Abschluss erneut installieren.'
    lock update || die 'Update laeuft; nach dessen Abschluss erneut installieren.'
    save_language

    event STAGE:homebrew_check
    if [ ! -x "$PREFIX/bin/brew" ]; then
        event STAGE:homebrew_install
        say 'Homebrew wird mit dem offiziellen Installer eingerichtet; macOS kann nach Admin-Passwort/Entwicklerwerkzeugen fragen.'
        tmp=$(/usr/bin/mktemp "$BASE/run/homebrew.XXXXXX")
        TEMP_FILES+=("$tmp")
        /usr/bin/curl --fail --show-error --location --proto '=https' --tlsv1.2 \
            https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$tmp"
        /bin/bash "$tmp"
    fi
    [ -x "$PREFIX/bin/brew" ] || die 'Homebrew wurde nicht unter /opt/homebrew installiert.'
    [ "$(brew_cmd --prefix)" = "$PREFIX" ] || die 'Unerwarteter Homebrew-Praefix.'
    install_latest_clamav
    for file in "$OPT/bin/clamscan" "$OPT/bin/clamdscan" "$OPT/bin/freshclam" "$OPT/sbin/clamd"; do
        [ -x "$file" ] || die "ClamAV-Bestandteil fehlt: $file"
    done
    installed_version=$(scanner_version)
    IFS=. read -r major minor patch <<< "$installed_version"
    case "$major.$minor.$patch" in *[!0-9.]*|..|*..*) die "Unbekannte ClamAV-Version: $installed_version" ;; esac
    if ! (( major > 1 || (major == 1 && minor > 5) || (major == 1 && minor == 5 && patch >= 4) )); then
        die 'Die angebotene Homebrew-Version erfuellt die erforderliche Sicherheitsuntergrenze ClamAV 1.5.4 nicht.'
    fi
    say "ClamAV $installed_version wird verwendet; vorhandene Homebrew-Konfigurationen bleiben erhalten."
    event "VERSION:$installed_version"

    event STAGE:configuration
    if [ ! -e "$CONF" ] && [ ! -L "$CONF" ]; then
        cat > "$CONF" <<CONFIG
# $MARKER — eigene Anpassungen bleiben bei erneuter Installation erhalten.
DatabaseDirectory "$BASE/db"
LocalSocket "$BASE/run/clamd.sock"
LocalSocketMode 600
FixStaleSocket yes
Foreground yes
LogFile "$LOGS/clamd.log"
LogTime yes
LogFileMaxSize 10M
LogRotate yes
LogClean no
SelfCheck 600
MaxThreads 2
ConcurrentDatabaseReload no
FollowDirectorySymlinks no
FollowFileSymlinks no
MaxDirectoryRecursion 100
MaxFileSize 256M
MaxScanSize 512M
MaxRecursion 20
MaxFiles 10000
DetectPUA no
AlertExceedsMax no
CONFIG
    fi
    if [ ! -e "$FRESHCONF" ] && [ ! -L "$FRESHCONF" ]; then
        cat > "$FRESHCONF" <<CONFIG
# $MARKER — eigene Anpassungen bleiben bei erneuter Installation erhalten.
DatabaseDirectory "$BASE/db"
DatabaseMirror database.clamav.net
DNSDatabaseInfo current.cvd.clamav.net
ScriptedUpdates yes
TestDatabases yes
ConnectTimeout 30
ReceiveTimeout 120
MaxAttempts 3
CONFIG
    fi
    for file in "$CONF" "$FRESHCONF"; do
        [ -f "$file" ] && [ ! -L "$file" ] && [ -O "$file" ] || die "Ungueltige Konfigurationsdatei: $file"
        /bin/chmod 600 "$file"
    done
    tmp=$(/usr/bin/mktemp "$BASE/bin/installer.XXXXXX")
    TEMP_FILES+=("$tmp")
    /bin/cp "$0" "$tmp"
    /bin/bash -n "$tmp"
    put_managed "$tmp" "$INSTALLED" 700

    # Stage and lint every definition before changing any running job.
    for kind in clamd update scan; do
        tmp=$(/usr/bin/mktemp "$BASE/run/$kind.plist.XXXXXX")
        TEMP_FILES+=("$tmp")
        make_plist "$kind" "$tmp"
        file="$AGENTS/$LABEL.$kind.plist"
        if [ -e "$file" ] || [ -L "$file" ]; then
            [ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] || die "Ungueltige Job-Datei: $file"
            /usr/bin/grep -q "$MARKER" "$file" || die "Fremder Job wird nicht ersetzt: $file"
        fi
        if ! /usr/bin/cmp -s "$tmp" "$file"; then changed_jobs+=("$kind"); fi
        # Pending files are private; jobs are not loaded until initial DB exists.
        put_managed "$tmp" "$file" 600
    done
    event STAGE:signatures
    say 'Lade/pruefe Virensignaturen. Dies kann einige Minuten dauern.'
    tmp=$(/usr/bin/mktemp "$LOGS/install-update.XXXXXX")
    initial_signature_update "$tmp"
    save_status update "OK: Installationsupdate; $tmp"
    event STAGE:jobs
    for kind in ${changed_jobs[@]+"${changed_jobs[@]}"}; do stop_job "$kind" restore; done
    # The plist can be byte-identical after a Homebrew upgrade. Always replace
    # the running daemon so a previous executable cannot remain in memory.
    stop_job clamd restore
    bootstrap_job clamd
    if ! wait_ready; then
        event DAEMON:UNAVAILABLE
        die "clamd antwortet nicht. Details: $LOGS/clamd.log und $LOGS/launchd-clamd.log. Danach erneut ausfuehren."
    fi
    event DAEMON:READY
    "$OPT/bin/clamdscan" --config-file="$CONF" --reload >/dev/null
    bootstrap_job update
    bootstrap_job scan
    RESTORE_JOBS=(); RESTORE_PIDS=(); RESTORE_PENDING=()
    say ''
    say 'Installiert: taeglicher Scan um 19:00 Uhr, Signaturpruefung etwa alle 2 Stunden waehrend der Anmeldung.'
    say 'NOCH MANUELL: Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff.'
    say 'Fuer Hintergrundjobs /bin/bash sowie den Scanner hinzufuegen/aktivieren:'
    say "$OPT/bin/clamdscan"
    say "Realer Scanner-Pfad: $(cd "$OPT/bin" && /bin/pwd -P)/clamdscan"
    say 'Achtung: FDA fuer /bin/bash gilt auch fuer andere darueber gestartete Skripte.'
    say 'Nur Terminal oder nur clamd freizugeben reicht fuer diesen Hintergrundjob nicht.'
    say 'Nach der Freigabe diese zwei Befehle ausfuehren:'
    printf '/bin/bash %q --restart\n' "$INSTALLED"
    printf '/bin/bash %q --scan-now\n' "$INSTALLED"
    say "Logs: $LOGS"
    say "Quarantaene: $BASE/quarantine (keine automatische Loeschung)"
    notify_user 'ClamAV eingerichtet' 'Bitte Festplattenvollzugriff manuell erlauben und danach den geplanten Scan testen.'
    event RESULT:INSTALLED
}

package_removal_preflight() {
    local dependents
    if ! foreign_jobs; then
        die 'Das ClamAV-Paket wird von fremden Jobs/Prozessen verwendet. Ohne Paketentfernung deinstallieren.'
    fi
    if [ ! -x "$PREFIX/bin/brew" ]; then return 0; fi
    [ "$(brew_cmd --prefix)" = "$PREFIX" ] || die 'Unerwarteter Homebrew-Praefix.'
    dependents=$(HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd uses --installed --recursive "$FORMULA") || die 'Abhaengigkeiten konnten nicht geprueft werden; Paket bleibt erhalten.'
    [ -z "$dependents" ] || die "Andere Homebrew-Pakete benoetigen ClamAV; Paket bleibt erhalten: $dependents"
}

package_removal_failed() {
    local rc="$1"
    event PACKAGE:REMOVAL_FAILED
    event RESULT:PARTIAL_UNINSTALL
    say 'Die eigene Automatik ist entfernt. Nur die optionale Entfernung des Homebrew-Pakets ist nicht abgeschlossen.' >&2
    say 'Archive und Logs bleiben erhalten.' >&2
    # Called only after our automation was archived or confirmed absent. Exit
    # explicitly so the generic ERR trap cannot replace this partial result.
    exit "$rc"
}

archive_package_remainders() {
    local helper
    [ -e "$PREFIX/Cellar/clamav" ] || [ -L "$PREFIX/Cellar/clamav" ] || return 0
    package_repair_preflight
    helper=$(package_repair_tool_path package-archive) || return 2
    event STAGE:package_archive
    "$helper"
}

remove_package() {
    local rc=0
    if [ ! -x "$PREFIX/bin/brew" ]; then
        if [ -e "$PREFIX/Cellar/clamav" ] || [ -L "$PREFIX/Cellar/clamav" ]; then package_removal_failed 2; fi
        event PACKAGE:NOT_INSTALLED; return 0
    fi
    package_removal_preflight
    if [ ! -e "$PREFIX/Cellar/clamav" ] && [ ! -L "$PREFIX/Cellar/clamav" ] && [ ! -e "$OPT" ] && [ ! -L "$OPT" ] && ! brew_cmd list --versions --formula "$FORMULA" >/dev/null 2>&1; then
        event PACKAGE:NOT_INSTALLED; return 0
    fi
    event STAGE:package_remove
    if brew_cmd list --versions --formula "$FORMULA" >/dev/null 2>&1; then
        if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 brew_cmd uninstall --formula "$FORMULA"; then :; else rc=$?; fi
    fi
    # Homebrew can leave an unregistered keg even after reporting success.
    # Check the filesystem independently of its installed-package listing.
    if [ -e "$PREFIX/Cellar/clamav" ] || [ -L "$PREFIX/Cellar/clamav" ]; then
        archive_package_remainders || { [ "$rc" -ne 0 ] || rc=2; package_removal_failed "$rc"; }
    elif [ "$rc" -ne 0 ]; then
        package_removal_failed "$rc"
    fi
    if [ -e "$PREFIX/Cellar/clamav" ] || [ -L "$PREFIX/Cellar/clamav" ] || [ -e "$OPT" ] || [ -L "$OPT" ] || brew_cmd list --versions --formula "$FORMULA" >/dev/null 2>&1; then
        say 'ClamAV-Paket oder Verknuepfung ist noch vorhanden.' >&2
        package_removal_failed 2
    fi
    event PACKAGE:REMOVED
}

# This optional action is separate from ordinary uninstall and available only
# with the narrowly scoped native helper shipped inside the GUI app bundle.
package_repair_tool_path() {
    local resources contents helper mode owner tool="${1:-package-repair}"
    case "$tool" in package-repair|package-archive) : ;; *) return 2 ;; esac
    [ "${BASH_SOURCE[0]##*/}" = install.sh ] || die 'Die Paket-Reparatur muss aus der Installer-App gestartet werden.'
    resources=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P) || die 'App-Ressourcen konnten nicht gefunden werden.'
    contents=${resources%/*}
    [ "${resources##*/}" = Resources ] && [ "${contents##*/}" = Contents ] || die 'Ungueltiger App-Ressourcenpfad.'
    helper="$contents/MacOS/$tool"
    [ ! -L "$contents/MacOS" ] && [ -d "$contents/MacOS" ] && [ ! -L "$helper" ] && [ -f "$helper" ] && [ -x "$helper" ] || die 'Paket-Reparaturhilfe fehlt oder ist verlinkt.'
    mode=$(/usr/bin/stat -f '%Lp' "$helper") || die 'Rechte der Reparaturhilfe konnten nicht geprueft werden.'
    owner=$(/usr/bin/stat -f '%u' "$helper") || die 'Eigentuemer der Reparaturhilfe konnte nicht geprueft werden.'
    [ "$owner" = 0 ] || [ "$owner" = "$(/usr/bin/id -u)" ] || die 'Unbekannter Eigentuemer der Reparaturhilfe.'
    [ "$((8#$mode & 0022))" -eq 0 ] || die 'Reparaturhilfe ist fuer andere Benutzer beschreibbar.'
    printf '%s\n' "$helper"
}

package_process_listing() { /bin/ps -axo comm=; }
package_repair_sudo() { /usr/bin/sudo -p 'Administrator-Passwort: ' "$@"; }

package_repair_preflight() {
    local kind records matches domain label
    [ ! -e "$BASE" ] && [ ! -L "$BASE" ] || die 'Zuerst die eigene Automatik ohne Paketentfernung deinstallieren.'
    for kind in scan update clamd; do
        [ ! -e "$AGENTS/$LABEL.$kind.plist" ] && [ ! -L "$AGENTS/$LABEL.$kind.plist" ] || die 'Eigene Job-Dateien sind noch vorhanden; zuerst die Automatik deinstallieren.'
        if launchctl_cmd print "$DOMAIN/$LABEL.$kind" >/dev/null 2>&1; then
            die 'Eigene Hintergrundjobs sind noch geladen; zuerst die Automatik deinstallieren.'
        fi
    done
    # Unlike a process substitution, a captured status fails closed if ps is
    # unavailable. No scanner/updater process is exempt in this package-only mode.
    records=$(package_process_listing) || die 'Laufende Prozesse konnten nicht sicher geprueft werden.'
    matches=$(printf '%s\n' "$records" | /usr/bin/awk '/(^|\/)(clamd|freshclam|clamscan|clamdscan)$/ { print }') || die 'Prozesspruefung fehlgeschlagen.'
    [ -z "$matches" ] || die 'ClamAV-Prozesse sind noch aktiv; Paket-Reparatur wurde nicht gestartet.'
    # Root services can remain registered without an active PID or plist. Read
    # the system domain first, then also check the known root/user registrations.
    launchctl_cmd print system >/dev/null || die 'System-Hintergrundjobs konnten nicht sicher geprueft werden.'
    for label in sh.brew.clamav homebrew.mxcl.clamav; do
        for domain in system user/0 "$DOMAIN"; do
            if launchctl_cmd print "$domain/$label" >/dev/null 2>&1; then
                die "ClamAV-Job ist noch registriert: $domain/$label"
            fi
        done
    done
    package_removal_preflight
}

repair_uninstall_package() {
    local helper keg version result rc
    local versions=() needs_repair=()
    event STAGE:uninstall_check
    launchctl_cmd print "$DOMAIN" >/dev/null 2>&1 || die 'Bitte in einer angemeldeten grafischen macOS-Sitzung starten.'
    lock install || die 'Eine Installation oder Deinstallation laeuft bereits.'
    package_repair_preflight
    helper=$(package_repair_tool_path) || die 'Sichere Paket-Reparatur ist nur aus der Installer-App verfuegbar.'
    # The native helper independently enforces the fixed /opt/homebrew tree.
    # Validate every version before the first privileged operation; no arbitrary
    # path, executable, environment override or recursive ownership change.
    for keg in "$PREFIX" "$PREFIX/Cellar" "$PREFIX/Cellar/clamav"; do
        [ ! -L "$keg" ] || die "Verlinkter Homebrew-Paketpfad wird nicht repariert: $keg"
        [ ! -e "$keg" ] || [ -d "$keg" ] || die "Ungueltiger Homebrew-Paketpfad: $keg"
    done
    for keg in "$PREFIX/Cellar/clamav"/* "$PREFIX/Cellar/clamav"/.[!.]* "$PREFIX/Cellar/clamav"/..?*; do
        if [ ! -e "$keg" ] && [ ! -L "$keg" ]; then continue; fi
        [ ! -L "$keg" ] && [ -d "$keg" ] || die "Unerwarteter Eintrag im ClamAV-Paketordner: $keg"
        version=${keg##*/}
        [ "${#version}" -le 64 ] && printf '%s\n' "$version" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,3}(_[0-9]+)?$' || die 'Unbekannter ClamAV-Versionsordner; keine Reparatur ausgefuehrt.'
        result=$("$helper" --check "$version") || die 'Paketstruktur entspricht nicht der begrenzten, sicheren Reparatur.'
        case "$result" in
            REPAIR:NEEDED) needs_repair+=("$version") ;;
            REPAIR:NOT_NEEDED) : ;;
            *) die 'Unerwartete Antwort der Paket-Reparaturhilfe.' ;;
        esac
        versions+=("$version")
    done
    for version in ${needs_repair[@]+"${needs_repair[@]}"}; do
        package_repair_preflight
        event STAGE:package_repair
        say "Bekannte Verzeichnisrechte von ClamAV $version werden mit Admin-Bestaetigung repariert."
        if package_repair_sudo "$helper" --repair "$version"; then
            :
        else
            rc=$?
            package_removal_failed "$rc"
        fi
    done
    package_repair_preflight
    remove_package
    # Homebrew must also remove residual keg directories; an empty or absent
    # formula entry alone is not enough to claim that repair/removal succeeded.
    for version in ${versions[@]+"${versions[@]}"}; do
        if [ -e "$PREFIX/Cellar/clamav/$version" ] || [ -L "$PREFIX/Cellar/clamav/$version" ]; then
            say 'Ein ClamAV-Paketordner ist noch vorhanden; bestehende Archive und Logs bleiben unveraendert.' >&2
            package_removal_failed 2
        fi
    done
    say 'ClamAV-Paket entfernt oder bereits nicht mehr vorhanden. Bestehende Archive und Logs bleiben unveraendert.'
    event RESULT:NOT_INSTALLED
}

uninstall() {
    local remove_shared="$1" kind file archive_copy stamp
    event STAGE:uninstall_check
    launchctl_cmd print "$DOMAIN" >/dev/null 2>&1 || die 'Bitte in einer angemeldeten grafischen macOS-Sitzung starten.'
    lock install || die 'Eine Installation oder Deinstallation laeuft bereits.'
    preflight_jobs
    if [ "$remove_shared" = yes ]; then package_removal_preflight; fi
    if [ ! -e "$BASE" ] && [ ! -L "$BASE" ]; then
        for kind in scan update clamd; do
            if [ -e "$AGENTS/$LABEL.$kind.plist" ] || [ -L "$AGENTS/$LABEL.$kind.plist" ]; then
                die 'Eigene Job-Datei ohne Installationsordner gefunden. Zur sicheren Reparatur zuerst erneut installieren.'
            fi
        done
        if [ "$remove_shared" = yes ]; then remove_package; fi
        say "Keine eigene Installation vorhanden. Vorhandene Archive und Logs bleiben erhalten: $ARCHIVES; $LOGS"
        event RESULT:NOT_INSTALLED
        return 0
    fi
    assert_managed
    lock scan || die 'Scan laeuft; vor der Deinstallation dessen Abschluss abwarten.'
    lock update || die 'Signaturupdate laeuft; vor der Deinstallation dessen Abschluss abwarten.'
    private_dir "$ARCHIVES"
    stamp=$(/bin/date '+%Y%m%d-%H%M%S')
    UNINSTALL_ARCHIVE=$(/usr/bin/mktemp -d "$ARCHIVES/$stamp.XXXXXX")
    /bin/mkdir "$UNINSTALL_ARCHIVE/launchagents"
    # Keep copies before any removal. A failed operation restores removed
    # definitions and previously active jobs in the EXIT cleanup handler.
    for kind in scan update clamd; do
        file="$AGENTS/$LABEL.$kind.plist"
        if assert_owned_job "$kind"; then /bin/cp -p "$file" "$UNINSTALL_ARCHIVE/launchagents/"; fi
    done
    event STAGE:uninstall_stop
    for kind in scan update clamd; do stop_job "$kind" restore; done
    event STAGE:uninstall_archive
    for kind in scan update clamd; do
        file="$AGENTS/$LABEL.$kind.plist"
        archive_copy="$UNINSTALL_ARCHIVE/launchagents/$LABEL.$kind.plist"
        if [ -f "$archive_copy" ]; then
            assert_owned_job "$kind" || die "Job-Datei wurde waehrend der Deinstallation entfernt: $file"
            /usr/bin/cmp -s "$archive_copy" "$file" || die "Job-Datei wurde waehrend der Deinstallation geaendert: $file"
            /bin/rm "$file"
        fi
    done
    # A unique directory on the same home volume avoids basename collisions.
    # No recursive deletion: quarantine, signatures, configs and backups survive.
    /bin/mv "$BASE" "$UNINSTALL_ARCHIVE/installation"
    UNINSTALL_COMMITTED=yes
    RESTORE_JOBS=(); RESTORE_PIDS=(); RESTORE_PENDING=()
    event "ARCHIVE:$UNINSTALL_ARCHIVE"
    say "Eigene Automatik entfernt. Alle eigenen Daten bleiben im Archiv: $UNINSTALL_ARCHIVE"
    say "Logs bleiben erhalten: $LOGS"
    if [ "$remove_shared" = yes ]; then remove_package; else event PACKAGE:RETAINED; fi
    say 'Homebrew und fremde Konfigurationen bleiben erhalten. Festplattenvollzugriff kann bei Bedarf manuell in den Systemeinstellungen entfernt werden.'
    event RESULT:UNINSTALLED
}

# Legacy definitions are recognized conservatively; shared Homebrew configs,
# signatures, original logs and quarantined files are never removed or moved.
legacy_path_is_plain() {
    local p="$1"
    case "$p" in /*) ;; *) return 1 ;; esac
    while [ "$p" != / ]; do
        [ ! -L "$p" ] || return 1
        p=${p%/*}; [ -n "$p" ] || p=/
    done
}

legacy_file_is_owned() {
    legacy_path_is_plain "$1" && [ -f "$1" ] && [ -O "$1" ]
}

legacy_label() {
    case "$1" in
        scan) printf '%s' ch.ivan.clamav.dailyscan ;;
        update) printf '%s' ch.ivan.clamav.freshclam ;;
        clamd) printf '%s' sh.brew.clamav ;;
    esac
}

legacy_script_check() {
    local script="$HOME/.local/bin/clamav-daily-scan.sh"
    if [ ! -e "$script" ] && [ ! -L "$script" ]; then return 1; fi
    legacy_file_is_owned "$script" || die "Unbekannte oder verlinkte alte Scan-Datei: $script"
    [ "$(/usr/bin/head -n 1 "$script")" = '#!/bin/zsh' ] || die "Alte Scan-Datei hat eine unbekannte Struktur: $script"
    /usr/bin/grep -Fxq 'CLAMSCAN="/opt/homebrew/bin/clamscan"' "$script" &&
    /usr/bin/grep -Fxq 'LOGDIR="$HOME/Library/Logs/ClamAV"' "$script" &&
    /usr/bin/grep -Fxq 'QUARANTINE="$HOME/ClamAV-Quarantine"' "$script" || die "Alte Scan-Datei wurde nicht eindeutig erkannt: $script"
}

legacy_job_check() {
    local kind="$1" label file actual expected arg count index
    label=$(legacy_label "$kind"); file="$AGENTS/$label.plist"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 1; fi
    legacy_file_is_owned "$file" || die "Alte Job-Datei gehoert nicht diesem Benutzer oder ist verlinkt: $file"
    actual=$(/usr/bin/plutil -extract Label raw -o - "$file") || die "Ungueltige alte Job-Datei: $file"
    [ "$actual" = "$label" ] || die "Unbekannte Kennung in alter Job-Datei: $file"
    # Program can override ProgramArguments[0]; refuse any such alternate form.
    if /usr/bin/plutil -extract Program raw -o - "$file" >/dev/null 2>&1; then die "Abweichendes Programm in alter Job-Datei: $file"; fi
    case "$kind" in
        scan) expected="$HOME/.local/bin/clamav-daily-scan.sh"; count=1 ;;
        update) expected="$PREFIX/bin/freshclam"; count=2 ;;
        clamd) expected="$OPT/sbin/clamd"; count=2 ;;
    esac
    arg=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$file") || die "Programm fehlt in alter Job-Datei: $file"
    [ "$arg" = "$expected" ] || die "Abweichendes Programm in alter Job-Datei: $file"
    if [ "$count" -eq 2 ]; then
        case "$kind" in update) expected="--config-file=$PREFIX/etc/clamav/freshclam.conf" ;; clamd) expected=--foreground ;; esac
        arg=$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$file") || die "Argument fehlt in alter Job-Datei: $file"
        [ "$arg" = "$expected" ] || die "Abweichende Argumente in alter Job-Datei: $file"
    fi
    if /usr/bin/plutil -extract "ProgramArguments.$count" raw -o - "$file" >/dev/null 2>&1; then die "Zusaetzliche Argumente in alter Job-Datei: $file"; fi
    # Enforce a real array, rejecting dictionaries with numeric keys as well.
    actual=$(/usr/bin/plutil -type ProgramArguments "$file") || die "Argumentliste fehlt in alter Job-Datei: $file"
    [ "$actual" = array ] || die "Ungueltige Argumentliste in alter Job-Datei: $file"
}

legacy_process_listing() { /bin/ps -axo pid=,comm=,args=; }
legacy_external_busy() {
    local records matches
    records=$(legacy_process_listing) || die 'Laufende Prozesse konnten nicht sicher geprueft werden.'
    matches=$(printf '%s\n' "$records" | /usr/bin/awk -v script="$HOME/.local/bin/clamav-daily-scan.sh" -v quarantine="$HOME/ClamAV-Quarantine" -v config="$PREFIX/etc/clamav/freshclam.conf" '
      ($2 ~ /(^|\/)(zsh|bash)$/ && index($0, script)) ||
      ($2 ~ /(^|\/)clamscan$/ && index($0, quarantine)) ||
      ($2 ~ /(^|\/)freshclam$/ && index($0, config)) { print $1 }
    ')
    [ -z "$matches" ] || return 0
    return 1
}

# This read-only preflight also powers the GUI status. It creates no directories,
# lock files or archives, and never reads logs or quarantine contents.
legacy_preflight() {
    local mode="$1" kind label file record source pid program args expected found=no busy=no
    LEGACY_FILES=(); LEGACY_RELS=(); LEGACY_LOADED=()
    legacy_path_is_plain "$HOME" && legacy_path_is_plain "$AGENTS" || die 'Verlinkter Benutzer- oder LaunchAgents-Pfad wird nicht veraendert.'
    [ ! -e "$AGENTS" ] || { [ -d "$AGENTS" ] && [ -O "$AGENTS" ]; } || die 'LaunchAgents-Ordner gehoert nicht diesem Benutzer.'
    for kind in scan update clamd; do
        label=$(legacy_label "$kind"); file="$AGENTS/$label.plist"
        if legacy_job_check "$kind"; then
            LEGACY_FILES+=("$file"); LEGACY_RELS+=("launchagents/$label.plist"); found=yes
            if [ "$kind" = scan ]; then legacy_script_check || die 'Alte Scan-Job-Datei ohne eindeutig erkanntes Scan-Skript gefunden.'; fi
        fi
        if record=$(launchctl_cmd print "$DOMAIN/$label" 2>/dev/null || exit $?); then
            legacy_job_check "$kind" || die "Geladener alter Job ohne verifizierbare Datei: $label"
            source=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*path = / {sub(/^[[:space:]]*path = /, ""); print; exit}')
            [ "$source" = "$file" ] || die "Geladener alter Job hat eine fremde Quelle: $label"
            program=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*program = / {sub(/^[[:space:]]*program = /, ""); print; exit}')
            case "$kind" in
                scan) [ "$program" = "$HOME/.local/bin/clamav-daily-scan.sh" ] ;;
                update) [ "$program" = "$PREFIX/bin/freshclam" ] ;;
                clamd) [ "$program" = "$OPT/sbin/clamd" ] ;;
            esac || die "Geladener alter Job verwendet ein anderes Programm: $label"
            args=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*arguments = \{$/ {inside=1; next} inside && /^\t\}$/ {exit} inside {sub(/^\t\t/, ""); print}')
            case "$kind" in
                scan) expected="$HOME/.local/bin/clamav-daily-scan.sh" ;;
                update) expected=$(printf '%s\n' "$PREFIX/bin/freshclam" "--config-file=$PREFIX/etc/clamav/freshclam.conf") ;;
                clamd) expected=$(printf '%s\n' "$OPT/sbin/clamd" --foreground) ;;
            esac
            [ "$args" = "$expected" ] || die "Geladener alter Job verwendet andere Argumente: $label"
            LEGACY_LOADED+=("$kind")
            pid=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')
            if [ "$kind" != clamd ] && [ -n "$pid" ]; then busy=yes; fi
        fi
    done
    if legacy_script_check; then
        LEGACY_FILES+=("$HOME/.local/bin/clamav-daily-scan.sh"); LEGACY_RELS+=(scripts/clamav-daily-scan.sh); found=yes
    fi
    if legacy_external_busy; then busy=yes; fi
    LEGACY_FOUND="$found"; LEGACY_BUSY="$busy"
    if [ "$mode" = remove ] && [ "$busy" = yes ]; then die 'Alter Scan oder Signaturupdate laeuft noch. Dessen Abschluss abwarten und erneut versuchen.'; fi
}

legacy_status() {
    legacy_preflight status
    if [ "$LEGACY_FOUND" = no ]; then event LEGACY:NOT_FOUND; return 0; fi
    event LEGACY:FOUND
    if [ "$LEGACY_BUSY" = yes ]; then event LEGACY:BUSY; fi
    local file
    for file in ${LEGACY_FILES[@]+"${LEGACY_FILES[@]}"}; do say "Alte Konfiguration zum Archivieren: $file"; done
    say "Unveraendert erhalten: $HOME/Library/Logs/ClamAV; $HOME/ClamAV-Quarantine; $PREFIX/etc/clamav; Homebrew und ClamAV-Paket."
}

legacy_move() { /bin/mv -n "$1" "$2"; }

legacy_rollback() {
    local i=0 source target rel kind label pid pending ok=yes
    [ -n "$LEGACY_ARCHIVE" ] && [ "$LEGACY_COMMITTED" != yes ] || return 0
    for target in ${LEGACY_ORIGINAL_FILES[@]+"${LEGACY_ORIGINAL_FILES[@]}"}; do
        rel="${LEGACY_ORIGINAL_RELS[$i]}"; source="$LEGACY_ARCHIVE/removed/$rel"; i=$((i+1))
        if [ -f "$source" ]; then
            if legacy_path_is_plain "$target" && [ ! -e "$target" ] && [ ! -L "$target" ]; then
                /bin/mv -n "$source" "$target" || ok=no
                [ ! -e "$source" ] || ok=no
            else
                say "WARNUNG: Ruecknahme ueberschreibt keine zwischenzeitlich angelegte Datei: $target" >&2; ok=no
            fi
        fi
    done
    i=0
    for kind in ${LEGACY_RESTORE_JOBS[@]+"${LEGACY_RESTORE_JOBS[@]}"}; do
        pid="${LEGACY_RESTORE_PIDS[$i]}"; pending="${LEGACY_RESTORE_PENDING[$i]}"; i=$((i+1))
        label=$(legacy_label "$kind"); target="$AGENTS/$label.plist"
        if [ "$pending" = yes ] && ! wait_job_stopped "$label" "$pid"; then
            say "WARNUNG: Alter Job oder Prozess ist noch aktiv; kein zweiter Job wird gestartet: $label (PID $pid)" >&2; ok=no; continue
        fi
        if [ "$kind" = scan ] && ! /usr/bin/cmp -s "$LEGACY_ARCHIVE/backup/scripts/clamav-daily-scan.sh" "$HOME/.local/bin/clamav-daily-scan.sh"; then
            say "WARNUNG: Geaendertes Scan-Skript wird nicht erneut gestartet: $label" >&2; ok=no; continue
        fi
        if (legacy_job_check "$kind") && /usr/bin/cmp -s "$LEGACY_ARCHIVE/backup/launchagents/$label.plist" "$target"; then
            if ! launchctl_cmd print "$DOMAIN/$label" >/dev/null 2>&1; then
                launchctl_cmd bootstrap "$DOMAIN" "$target" || { say "WARNUNG: Alter Job konnte nicht wiederhergestellt werden: $label" >&2; ok=no; }
            fi
        else
            say "WARNUNG: Geaenderter alter Job wird nicht erneut geladen: $label" >&2; ok=no
        fi
    done
    [ "$ok" = yes ] || say "WARNUNG: Ruecknahme braucht Pruefung. Sichere Kopien liegen hier: $LEGACY_ARCHIVE" >&2
}

uninstall_legacy() {
    local i=0 kind label file rel snapshot stamp record pid index
    event STAGE:uninstall_check
    launchctl_cmd print "$DOMAIN" >/dev/null 2>&1 || die 'Bitte in einer angemeldeten grafischen macOS-Sitzung starten.'
    legacy_preflight remove
    if [ "$LEGACY_FOUND" = no ]; then event LEGACY:NOT_FOUND; event RESULT:NOT_INSTALLED; event PACKAGE:RETAINED; return 0; fi
    legacy_path_is_plain "$MANAGEMENT_LOCK" || die 'Verlinkte Verwaltungssperre wird nicht verwendet.'
    lock install || die 'Eine Installation oder Deinstallation laeuft bereits.'
    legacy_preflight remove
    legacy_path_is_plain "$ARCHIVES" || die 'Verlinkter Archivpfad wird nicht verwendet.'
    private_dir "$ARCHIVES"
    stamp=$(/bin/date '+%Y%m%d-%H%M%S')
    LEGACY_ARCHIVE=$(/usr/bin/mktemp -d "$ARCHIVES/legacy-$stamp.XXXXXX")
    /bin/mkdir -p "$LEGACY_ARCHIVE/backup/launchagents" "$LEGACY_ARCHIVE/backup/scripts" "$LEGACY_ARCHIVE/removed/launchagents" "$LEGACY_ARCHIVE/removed/scripts" "$LEGACY_ARCHIVE/config-snapshots"
    LEGACY_ORIGINAL_FILES=("${LEGACY_FILES[@]}"); LEGACY_ORIGINAL_RELS=("${LEGACY_RELS[@]}")
    for file in "${LEGACY_ORIGINAL_FILES[@]}"; do
        rel="${LEGACY_ORIGINAL_RELS[$i]}"; i=$((i+1)); snapshot="$LEGACY_ARCHIVE/backup/$rel"
        legacy_file_is_owned "$file" || die "Alte Datei wurde veraendert: $file"
        /bin/cp -p "$file" "$snapshot"
        /usr/bin/cmp -s "$file" "$snapshot" || die "Sicherung der alten Datei stimmt nicht ueberein: $file"
        printf '%s -> removed/%s\n' "$file" "$rel" >> "$LEGACY_ARCHIVE/restore-map.txt"
    done
    # Shared Homebrew config originals remain where they are; snapshots only.
    for kind in clamd freshclam; do
        file="$PREFIX/etc/clamav/$kind.conf"
        if [ -e "$file" ] || [ -L "$file" ]; then
            legacy_file_is_owned "$file" || die "Geteilte ClamAV-Konfiguration kann nicht sicher gesichert werden: $file"
            /bin/cp -p "$file" "$LEGACY_ARCHIVE/config-snapshots/$kind.conf"
            /usr/bin/cmp -s "$file" "$LEGACY_ARCHIVE/config-snapshots/$kind.conf" || die "Konfigurationssicherung stimmt nicht ueberein: $file"
        fi
    done
    say 'Originale Logs, Quarantaene, Homebrew-Konfigurationen und Pakete bleiben an ihrem bisherigen Ort.' > "$LEGACY_ARCHIVE/README.txt"
    # Repeat all checks immediately before stopping the verified legacy jobs.
    legacy_preflight remove
    event STAGE:uninstall_stop
    for kind in scan update clamd; do
        label=$(legacy_label "$kind")
        if record=$(launchctl_cmd print "$DOMAIN/$label" 2>/dev/null || exit $?); then
            legacy_preflight remove
            pid=$(printf '%s\n' "$record" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')
            index=${#LEGACY_RESTORE_JOBS[@]}
            LEGACY_RESTORE_JOBS+=("$kind")
            LEGACY_RESTORE_PIDS+=("${pid:-0}"); LEGACY_RESTORE_PENDING+=(yes)
            launchctl_cmd bootout "$DOMAIN/$label"
            wait_job_stopped "$label" "${pid:-0}" || die "Alter Job oder Prozess wurde nicht innerhalb von 30 Sekunden beendet: $label"
            LEGACY_RESTORE_PENDING[$index]=no
        fi
    done
    legacy_preflight remove
    [ "${#LEGACY_LOADED[@]}" -eq 0 ] || die 'Ein alter Job wurde waehrend der Entfernung erneut geladen.'
    # Compare the complete preflight file set and every byte before first move.
    [ "${#LEGACY_FILES[@]}" -eq "${#LEGACY_ORIGINAL_FILES[@]}" ] || die 'Alte Konfiguration wurde waehrend der Entfernung veraendert.'
    i=0
    for file in "${LEGACY_ORIGINAL_FILES[@]}"; do
        [ "${LEGACY_FILES[$i]}" = "$file" ] || die 'Alte Konfiguration wurde waehrend der Entfernung veraendert.'
        rel="${LEGACY_ORIGINAL_RELS[$i]}"; i=$((i+1))
        /usr/bin/cmp -s "$file" "$LEGACY_ARCHIVE/backup/$rel" || die "Alte Datei wurde waehrend der Entfernung geaendert: $file"
    done
    event STAGE:uninstall_archive
    i=0
    for file in "${LEGACY_ORIGINAL_FILES[@]}"; do
        rel="${LEGACY_ORIGINAL_RELS[$i]}"; i=$((i+1))
        legacy_file_is_owned "$file" && /usr/bin/cmp -s "$file" "$LEGACY_ARCHIVE/backup/$rel" || die "Alte Datei wurde waehrend der Entfernung geaendert: $file"
        legacy_move "$file" "$LEGACY_ARCHIVE/removed/$rel"
        [ ! -e "$file" ] && [ ! -L "$file" ] && /usr/bin/cmp -s "$LEGACY_ARCHIVE/removed/$rel" "$LEGACY_ARCHIVE/backup/$rel" || die "Alte Datei konnte nicht sicher archiviert werden: $file"
    done
    LEGACY_COMMITTED=yes
    LEGACY_RESTORE_JOBS=(); LEGACY_RESTORE_PIDS=(); LEGACY_RESTORE_PENDING=()
    event "ARCHIVE:$LEGACY_ARCHIVE"
    event LEGACY:REMOVED
    event PACKAGE:RETAINED
    event RESULT:UNINSTALLED
    say "Alte Automatik entfernt. Archiv: $LEGACY_ARCHIVE"
    say "Logs und Quarantaene bleiben unveraendert: $HOME/Library/Logs/ClamAV; $HOME/ClamAV-Quarantine"
    say 'Homebrew, ClamAV-Paket, gemeinsame Konfigurationen und eine neuere eigene Installation bleiben erhalten.'
}

status() {
    local kind file
    assert_managed
    "$OPT/bin/clamdscan" --version
    if scanner_ready; then event DAEMON:READY; say 'clamd: erreichbar'; else event DAEMON:UNAVAILABLE; say 'clamd: NICHT erreichbar'; fi
    for kind in clamd update scan; do
        say "--- $LABEL.$kind ---"
        launchctl_cmd print "$DOMAIN/$LABEL.$kind" 2>/dev/null | \
            /usr/bin/awk '/state =|pid =|last exit code =|runs =/ {print}' || say 'Job nicht geladen.'
    done
    for file in "$LOGS/last-update.txt" "$LOGS/last-scan.txt"; do
        if [ -f "$file" ]; then /bin/cat "$file"; else say "Noch kein Ergebnis: $file"; fi
    done
    say "Logs: $LOGS"
    say 'LAEUFT ist kein abgeschlossenes Ergebnis; nach Abschluss erneut --status aufrufen.'
}

main() {
    local command="${1:---install}" kind
    [ "$#" -le 1 ] || die 'Bitte genau eine Option verwenden.'
    case "$command" in --help|-h) usage; return ;; esac
    platform_check
    case "$command" in
        --install) setup no ;;
        --allow-parallel) setup yes ;;
        --scan) daily_scan ;;
        --update) update_database ;;
        --status) status ;;
        --legacy-status) legacy_status ;;
        --uninstall-legacy) uninstall_legacy ;;
        --uninstall) uninstall no ;;
        --uninstall-package) uninstall yes ;;
        --repair-uninstall-package) repair_uninstall_package ;;
        --scan-now)
            assert_managed
            preflight_jobs
            launchctl_cmd kickstart "$DOMAIN/$LABEL.scan"
            event RESULT:SCAN_REQUESTED
            say "Scan ueber launchd angefordert. Ergebnis spaeter mit --status pruefen; Logs: $LOGS" ;;
        --restart|--stop)
            assert_managed
            preflight_jobs
            lock install || die 'Eine Installation laeuft.'
            lock scan || die 'Scan laeuft; zuerst dessen Abschluss abwarten.'
            lock update || die 'Update laeuft; zuerst dessen Abschluss abwarten.'
            for kind in scan update clamd; do stop_job "$kind"; done
            if [ "$command" = --restart ]; then
                bootstrap_job clamd
                wait_ready || die 'clamd startet nicht; Logs pruefen.'
                bootstrap_job update
                bootstrap_job scan
                say 'Eigene Jobs neu geladen. Mit --scan-now den Hintergrundscan testen.'
            else
                say 'Eigene Jobs fuer diese Sitzung gestoppt. Dateien/Quarantaene bleiben erhalten; Anmeldung laedt die Jobs erneut.'
            fi ;;
        *) usage; die "Unbekannte Option: $command" ;;
    esac
}

main "$@"
