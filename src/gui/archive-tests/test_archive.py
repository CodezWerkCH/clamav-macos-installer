from pathlib import Path
import subprocess, tempfile, json, os
ROOT=Path(__file__).resolve().parents[3]
helper=ROOT/'src/gui/package-archive-test'
results=[]
for case in ['orphan','repeat','collision','multiple','receipt','linked','symlink_keg','hidden','special','public_archive','unknown_identity','empty','missing','mixed_receipts','verification_failure']:
 with tempfile.TemporaryDirectory(prefix='clamav-archive-test-') as tmp:
  t=Path(tmp);p=t/'brew';h=t/'home';h.mkdir();rack=p/'Cellar/clamav';k=rack/'1.5.4';(k/'.brew').mkdir(parents=True);(k/'.brew/clamav.rb').write_text('class Clamav; end');(k/'bin').mkdir();(k/'bin/clamscan').write_bytes(b'original\0\xff');(k/'link').symlink_to('bin/clamscan');os.chmod(k/'bin/clamscan',0o555)
  if case=='receipt':(k/'INSTALL_RECEIPT.json').write_text('{}')
  if case=='linked':(p/'opt').mkdir();(p/'opt/clamav').symlink_to(k)
  if case=='symlink_keg':k.rename(t/'external');k.symlink_to(t/'external')
  if case=='hidden':(rack/'.unexpected').write_text('keep')
  if case=='special':os.mkfifo(k/'pipe')
  if case=='unknown_identity':(k/'.brew/clamav.rb').unlink()
  if case in ['multiple','mixed_receipts','verification_failure']:
   q=rack/'1.5.4_1';(q/'.brew').mkdir(parents=True);(q/'.brew/clamav.rb').write_text('formula')
   if case=='mixed_receipts':(q/'INSTALL_RECEIPT.json').write_text('{}')
  archive=h/'.clamav-automatik-archiv'
  if case in ['public_archive','collision']:
   archive.mkdir(mode=0o755 if case=='public_archive' else 0o700);(archive/'keep').write_text('existing archive')
  if case in ['empty','missing']:
   import shutil
   shutil.rmtree(k)
   if case=='missing':rack.rmdir()
  r=subprocess.run([helper,p,h],capture_output=True,text=True,env={**os.environ, "ARCHIVE_TEST_CHANGE": "1" if case=="verification_failure" else "0"})
  success=case in ['orphan','repeat','collision','multiple','empty','missing']
  assert (r.returncode==0)==success,(case,r.stderr)
  if success:
   assert not rack.exists()
   for a in archive.glob('paketrest-*'):
    entries=json.loads((a/'manifest.json').read_text());assert entries
    old=a/('clamav-'+a.name.split('-')[1])
    if (old/'bin/clamscan').exists():assert (old/'bin/clamscan').read_bytes()==b'original\0\xff'
   if case=='repeat':assert subprocess.run([helper,p,h]).returncode==0
  else:
   assert k.exists()
   if case=="verification_failure":assert "restored=true" in r.stderr
  if case in ['collision','public_archive']:assert (archive/'keep').read_text()=='existing archive'
  results.append(case);print('PASS',case)
print(len(results),'archive checks passed')
