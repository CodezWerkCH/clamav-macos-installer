#!/usr/bin/env python3
import os, pathlib, plistlib, shutil, subprocess, tempfile, json
ROOT=pathlib.Path(__file__).resolve().parent
SOURCE=ROOT.parents[2]/'src/backend/install.sh'
# Rewrite only the isolated runtime's HOME references; real HOME is untouched.
s=SOURCE.read_text().rsplit('\nmain "$@"',1)[0].replace('$HOME','$TEST_HOME').replace('PREFIX=/opt/homebrew','PREFIX="$TEST_ROOT/homebrew"')
RUNTIME=ROOT/'runtime-under-test.sh'; RUNTIME.write_text(s)
LABELS=['ch.ivan.clamav.dailyscan','ch.ivan.clamav.freshclam','sh.brew.clamav']
MOCK=r'''
STOP_TICKS=0
shutdown_pause() {
    STOP_TICKS=$((STOP_TICKS+1))
    printf '%s\n' "$STOP_TICKS" > "$TEST_ROOT/stop-ticks"
    case "$CASE" in
        async_job_exit|async_both_exit|cancel_wait)
            if [ "$STOP_TICKS" -ge 3 ]; then /bin/rm -f "$TEST_ROOT/loaded-sh.brew.clamav"; fi ;;
        timeout_then_rollback)
            if [ "$STOP_TICKS" -ge 153 ]; then /bin/rm -f "$TEST_ROOT/loaded-sh.brew.clamav"; fi ;;
    esac
    if [ "$CASE" = cancel_wait ] && [ "$STOP_TICKS" -eq 1 ]; then interrupted; fi
    return 0
}
launchctl_cmd() {
    local verb="$1" key="${2:-}" label="${2##*/}" p program
    printf '%s\n' "$*" >> "$TEST_ROOT/calls"
    case "$verb" in
      print)
        [ "$key" != "$DOMAIN" ] || return 0
        [ -f "$TEST_ROOT/loaded-$label" ] || return 113
        p="$AGENTS/$label.plist"
        case "$label" in
          ch.ivan.clamav.dailyscan) program="$TEST_HOME/.local/bin/clamav-daily-scan.sh" ;;
          ch.ivan.clamav.freshclam) program="$PREFIX/bin/freshclam" ;;
          sh.brew.clamav) program="$OPT/sbin/clamd" ;;
        esac
        if [ "$CASE" = foreign_source ] && [ "$label" = ch.ivan.clamav.dailyscan ]; then p=/somewhere/foreign.plist; fi
        printf '\tpath = %s\n\tprogram = %s\n\tstate = not running\n' "$p" "$program"
        printf '\targuments = {\n\t\t%s\n' "$program"
        case "$label" in
          ch.ivan.clamav.freshclam) printf '\t\t--config-file=%s/etc/clamav/freshclam.conf\n' "$PREFIX" ;;
          sh.brew.clamav) printf '\t\t--foreground\n' ;;
        esac
        if [ "$CASE" = loaded_extra_arg ]; then printf '\t\t--extra\n'; fi
        printf '\t}\n' 
        if [ "$CASE" = busy_scan ] && [ "$label" = ch.ivan.clamav.dailyscan ]; then printf '\tpid = 123\n'; fi
        if [ "$CASE" = busy_update ] && [ "$label" = ch.ivan.clamav.freshclam ]; then printf '\tpid = 124\n'; fi
        if [ "$label" = sh.brew.clamav ]; then printf '\tpid = 99999999\n'; fi
        return 0 ;;
      bootout)
        if [ "$CASE" = stop_failure ] && [ "$label" = ch.ivan.clamav.freshclam ]; then return 22; fi
        if [ "$CASE" = still_loaded ] && [ "$label" = ch.ivan.clamav.dailyscan ]; then return 0; fi
        if [ "$label" = sh.brew.clamav ]; then
            case "$CASE" in
                async_job_exit|async_both_exit|cancel_wait|timeout_then_rollback) return 0 ;;
                async_stop_failure) /bin/rm "$TEST_ROOT/loaded-$label"; return 22 ;;
            esac
        fi
        /bin/rm "$TEST_ROOT/loaded-$label"
        if [ "$CASE" = script_changed ] && [ "$label" = sh.brew.clamav ]; then printf '\n# changed\n' >> "$TEST_HOME/.local/bin/clamav-daily-scan.sh"; fi
        return 0 ;;
      bootstrap)
        p="$3"; label=$(/usr/bin/plutil -extract Label raw -o - "$p")
        : > "$TEST_ROOT/loaded-$label"; return 0 ;;
      *) printf 'Unexpected launchctl: %s\n' "$*" >&2; return 99 ;;
    esac
}
legacy_process_listing() {
    if [ "$CASE" = external_scan ]; then printf '123 /opt/homebrew/bin/clamscan clamscan --move=%s/ClamAV-Quarantine Documents\n' "$TEST_HOME"; fi
    if [ "$CASE" = external_script ]; then printf '123 /bin/zsh /bin/zsh %s/.local/bin/clamav-daily-scan.sh\n' "$TEST_HOME"; fi
    return 0
}
job_pid_alive() {
    if [ "$CASE" = daemon_still_alive ]; then return 0; fi
    case "$CASE" in
        async_job_exit) [ "$STOP_TICKS" -lt 3 ]; return $? ;;
        async_pid_exit|async_both_exit|cancel_wait|async_stop_failure) [ "$STOP_TICKS" -lt 5 ]; return $? ;;
        timeout_then_rollback) [ "$STOP_TICKS" -lt 155 ]; return $? ;;
    esac
    /bin/kill -0 "$1" 2>/dev/null
}
MOVE_COUNT=0
legacy_move() {
    MOVE_COUNT=$((MOVE_COUNT+1))
    if [ "$CASE" = move_failure ] && [ "$MOVE_COUNT" -eq 2 ]; then return 44; fi
    if [ "$CASE" = cancel_move ] && [ "$MOVE_COUNT" -eq 2 ]; then interrupted; fi
    /bin/mv -n "$1" "$2"
}
'''

def fixture(name):
    root=pathlib.Path(tempfile.mkdtemp(prefix=name+'-',dir=ROOT)); home=root/'home'; agents=home/'Library/LaunchAgents'; agents.mkdir(parents=True)
    prefix=root/'homebrew'; (prefix/'etc/clamav').mkdir(parents=True)
    script=home/'.local/bin/clamav-daily-scan.sh'; script.parent.mkdir(parents=True)
    script.write_text('#!/bin/zsh\nCLAMSCAN="/opt/homebrew/bin/clamscan"\nLOGDIR="$TEST_HOME/Library/Logs/ClamAV"\nQUARANTINE="$TEST_HOME/ClamAV-Quarantine"\nexit 0\n')
    args=[[str(script)],[str(prefix/'bin/freshclam'),'--config-file='+str(prefix/'etc/clamav/freshclam.conf')],[str(prefix/'opt/clamav/sbin/clamd'),'--foreground']]
    for label, argv in zip(LABELS,args):
        with (agents/(label+'.plist')).open('wb') as f: plistlib.dump({'Label':label,'ProgramArguments':argv},f)
        (root/('loaded-'+label)).touch()
    for kind in ['clamd','freshclam']: (prefix/'etc/clamav'/f'{kind}.conf').write_text('keep shared config\n')
    for d in ['ClamAV-Quarantine','Library/Logs/ClamAV','.clamav-automatik']:
        (home/d).mkdir(parents=True,exist_ok=True); (home/d/'keep-me').write_bytes(b'unchanged\x00data')
    if name=='no_legacy':
        for label in LABELS: (agents/(label+'.plist')).unlink(); (root/('loaded-'+label)).unlink()
        script.unlink()
    if name in ['extra_arg','loaded_extra_arg','wrong_label','program_override','numeric_dictionary']:
        p=agents/(LABELS[0]+'.plist'); data=plistlib.loads(p.read_bytes())
        if name=='extra_arg': data['ProgramArguments'].append('--surprise')
        if name=='wrong_label': data['Label']='foreign.job'
        if name=='program_override': data['Program']='/bin/rm'
        if name=='numeric_dictionary': data['ProgramArguments']={'0':str(script)}
        p.write_bytes(plistlib.dumps(data))
    if name=='symlink_script':
        target=home/'real-script'; script.rename(target); script.symlink_to(target)
    if name=='symlink_parent':
        target=home/'real-local'; (home/'.local').rename(target); (home/'.local').symlink_to(target)
    if name=='symlink_plist':
        p=agents/(LABELS[0]+'.plist'); target=home/'real.plist'; p.rename(target); p.symlink_to(target)
    if name=='symlink_config':
        p=prefix/'etc/clamav/clamd.conf'; target=prefix/'real.conf'; p.rename(target); p.symlink_to(target)
    if name=='archive_collision':
        prior=home/'.clamav-automatik-archiv/legacy-existing'; prior.mkdir(parents=True); (prior/'keep-me').write_text('previous archive')
    if name=='orphan_loaded': (agents/(LABELS[0]+'.plist')).unlink()
    return root,home,agents,script,prefix

cases=['normal','archive_collision','status','no_legacy','repeat','extra_arg','loaded_extra_arg','wrong_label','program_override','numeric_dictionary','symlink_script','symlink_parent','symlink_plist','symlink_config','foreign_source','orphan_loaded','busy_scan','busy_update','external_scan','external_script','stop_failure','still_loaded','script_changed','move_failure','cancel_move','daemon_still_alive','async_job_exit','async_pid_exit','async_both_exit','async_stop_failure','cancel_wait','timeout_then_rollback']
results=[]
for name in cases:
    root,home,agents,script,prefix=fixture(name)
    command='legacy_status' if name=='status' else 'uninstall_legacy'
    if name=='repeat': command='uninstall_legacy\nuninstall_legacy'
    test=root/'test.sh'; test.write_text('source "$TEST_RUNTIME"\n'+MOCK+'\n'+command+'\n')
    env=dict(os.environ,TEST_HOME=str(home),TEST_ROOT=str(root),TEST_RUNTIME=str(RUNTIME),CASE=name)
    done=subprocess.run(['/bin/bash',str(test)],env=env,capture_output=True,text=True)
    (root/'output.txt').write_text(done.stdout+done.stderr)
    expected_ok=name in ['normal','archive_collision','status','no_legacy','repeat','async_job_exit','async_pid_exit','async_both_exit']
    try:
        assert (done.returncode==0)==expected_ok, (done.returncode,done.stdout,done.stderr)
        for d in ['ClamAV-Quarantine','Library/Logs/ClamAV','.clamav-automatik']: assert (home/d/'keep-me').read_bytes()==b'unchanged\x00data'
        for kind in ['clamd','freshclam']: assert (prefix/'etc/clamav'/f'{kind}.conf').read_text()=='keep shared config\n'
        if name in ['normal','repeat','archive_collision','async_job_exit','async_pid_exit','async_both_exit']:
            assert not script.exists()
            for label in LABELS: assert not (agents/(label+'.plist')).exists(); assert not (root/('loaded-'+label)).exists()
            archives=list((home/'.clamav-automatik-archiv').iterdir())
            if name=='archive_collision':
                assert len(archives)==2
                assert (home/'.clamav-automatik-archiv/legacy-existing/keep-me').read_text()=='previous archive'
                archives=[a for a in archives if a.name!='legacy-existing']
            assert len(archives)==1
            archive=archives[0]
            assert (archive/'removed/scripts/clamav-daily-scan.sh').is_file()
            for label in LABELS: assert (archive/'removed/launchagents'/(label+'.plist')).read_bytes()==(archive/'backup/launchagents'/(label+'.plist')).read_bytes()
            if name=='repeat': assert '@@CLAMAV:RESULT:NOT_INSTALLED' in done.stdout
        elif name=='no_legacy':
            assert not (home/'.clamav-automatik-archiv').exists(); assert not (home/'.clamav-automatik-management.lock').exists()
        elif name=='status':
            assert '@@CLAMAV:LEGACY:FOUND' in done.stdout
            assert not (home/'.clamav-automatik-archiv').exists(); assert not (home/'.clamav-automatik-management.lock').exists()
        else:
            if name!='orphan_loaded': assert (agents/(LABELS[0]+'.plist')).exists()
            assert script.exists()
            for label in LABELS:
                if name=='script_changed' and label==LABELS[0]: continue
                if name=='daemon_still_alive' and label==LABELS[2]: continue
                assert (root/('loaded-'+label)).exists(), ('Job was not restored',label)
        fragments={
          'extra_arg':'Zusaetzliche Argumente', 'loaded_extra_arg':'Geladener alter Job verwendet andere Argumente',
          'wrong_label':'Unbekannte Kennung', 'program_override':'Abweichendes Programm', 'numeric_dictionary':'Ungueltige Argumentliste',
          'symlink_script':'Unbekannte oder verlinkte alte Scan-Datei', 'symlink_parent':'Unbekannte oder verlinkte alte Scan-Datei',
          'symlink_plist':'Alte Job-Datei gehoert nicht diesem Benutzer oder ist verlinkt', 'symlink_config':'Geteilte ClamAV-Konfiguration kann nicht sicher gesichert werden',
          'foreign_source':'Geladener alter Job hat eine fremde Quelle', 'orphan_loaded':'Geladener alter Job ohne verifizierbare Datei',
          'busy_scan':'Alter Scan oder Signaturupdate laeuft noch', 'busy_update':'Alter Scan oder Signaturupdate laeuft noch',
          'external_scan':'Alter Scan oder Signaturupdate laeuft noch', 'external_script':'Alter Scan oder Signaturupdate laeuft noch',
          'stop_failure':'command_failed:22:', 'still_loaded':'Alter Job oder Prozess wurde nicht innerhalb von 30 Sekunden beendet',
          'script_changed':'Alte Datei wurde waehrend der Entfernung geaendert', 'move_failure':'command_failed:44:',
          'daemon_still_alive':'Alter Job oder Prozess wurde nicht innerhalb von 30 Sekunden beendet',
          'timeout_then_rollback':'Alter Job oder Prozess wurde nicht innerhalb von 30 Sekunden beendet',
          'async_stop_failure':'command_failed:22:',
        }
        if name in fragments: assert fragments[name] in done.stderr, (fragments[name],done.stderr)
        calls=(root/'calls').read_text()
        if name in ['move_failure','cancel_move','script_changed','daemon_still_alive']:
            assert calls.count('bootout ')==3
        if name=='stop_failure': assert calls.count('bootout ')==2 and calls.count('bootstrap ')==1
        if name=='daemon_still_alive':
            assert calls.count('bootstrap ')==2
            assert 'kein zweiter Job wird gestartet' in done.stderr
        if name in ['async_job_exit','async_pid_exit','async_both_exit']:
            assert calls.count('bootstrap ')==0
            ticks=int((root/'stop-ticks').read_text())
            assert ticks==(3 if name=='async_job_exit' else 5), ticks
        if name in ['cancel_wait','async_stop_failure','timeout_then_rollback']:
            assert calls.count('bootstrap ')==3
            assert (root/'stop-ticks').is_file()
            if name=='cancel_wait': assert done.returncode==130
            if name=='async_stop_failure': assert done.returncode==22
            if name=='timeout_then_rollback': assert int((root/'stop-ticks').read_text())==155
        if name=='still_loaded':
            assert calls.count('bootstrap ')==0
            assert int((root/'stop-ticks').read_text())==300
        if name=='daemon_still_alive': assert int((root/'stop-ticks').read_text())==300
        if name=='status': assert 'bootout ' not in calls and 'bootstrap ' not in calls
        result={'case':name,'pass':True,'exit':done.returncode}
    except AssertionError as e:
        result={'case':name,'pass':False,'exit':done.returncode,'error':str(e),'directory':str(root)}
    results.append(result); print(json.dumps(result,ensure_ascii=False))
(ROOT/'test-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['pass'] for x in results) else 1)
