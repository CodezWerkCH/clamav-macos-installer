from pathlib import Path
import subprocess, tempfile, json, shlex, os
root=Path.cwd(); folder=root/'src/gui/version-tests'
source=(root/'src/backend/install.sh').read_text().rsplit('\nmain "$@"',1)[0]
lib=folder/'functions.sh';lib.write_text(source+'\n')
valid={'name':'clamav','tap':'homebrew/core','versions':{'stable':'1.5.4'},'revision':1,'installed':[{'version':'1.5.4_1'}]}
other={'name':'abseil','tap':'homebrew/core','versions':{'stable':'20260817.0'}}
cases=[('valid_revision',[valid],'ClamAV 1.5.4/28150/date',0,0),('wrong_first',[other,valid],'ClamAV 1.5.4',0,2),('extra_formula',[valid,other],'ClamAV 1.5.4',0,2),('missing_formula',[],'ClamAV 1.5.4',0,2),('foreign_source',[dict(valid,tap='foreign/tap')],'ClamAV 1.5.4',0,2),('bad_stable',[dict(valid,versions={'stable':'20260817.0'})],'ClamAV 1.5.4',0,2),('old_engine',[valid],'ClamAV 1.5.3',0,2),('bad_engine',[valid],'other 1.5.4',0,2),('engine_failure',[valid],'ClamAV 1.5.4',9,2),('no_database_suffix',[valid],'ClamAV 1.5.4',0,0)]
results=[]
for name,formulae,output,rc,expected in cases:
 d=Path(tempfile.mkdtemp(prefix=name+'-',dir=folder));(d/'bin').mkdir()
 metadata=d/'info.json';metadata.write_text(json.dumps({'formulae':formulae}))
 scanner=d/'bin/clamscan';scanner.write_text('#!/bin/bash\n[ "$1" = --version ] || exit 99\nprintf "%s\\n" '+shlex.quote(output)+'\nexit '+str(rc)+'\n');scanner.chmod(0o700)
 daemon=d/'bin/clamdscan';daemon.write_text('#!/bin/bash\nprintf DAEMON_CONTACTED >&2\nexit 98\n');daemon.chmod(0o700)
 script='source '+shlex.quote(str(lib))+'\nOPT='+shlex.quote(str(d))+'\nread_clamav_formula_info '+shlex.quote(str(metadata))+'\nscanner_version\nprintf VERIFIED\\n\n'
 r=subprocess.run(['/bin/bash','-c',script],capture_output=True,text=True)
 assert r.returncode==expected,(name,r.returncode,r.stdout,r.stderr)
 assert 'DAEMON_CONTACTED' not in r.stderr
 assert ('VERIFIED' in r.stdout)==(expected==0)
 results.append({'case':name,'passed':True})

print(str(len(results))+' isolated version checks passed')
