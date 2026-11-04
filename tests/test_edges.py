#!/usr/bin/env python3
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import datetime,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]; APP=APP_PATH;WORKER=APP/'Contents/MacOS/NTFSWorker'
RUN=Path(tempfile.mkdtemp(prefix='edges-',dir=IMAGES_PATH));IMAGE=RUN/'disk.ntfs';IMAGE.touch();os.truncate(IMAGE,32*1024*1024);checks=[]
def call(action,*args,ok=True,worker=WORKER):
    r=subprocess.run([str(worker),'request'],input=json.dumps({'action':action,'target':{'kind':'image','path':str(IMAGE),'formatConfirmation':str(IMAGE)},'arguments':list(map(str,args))}),capture_output=True,text=True,timeout=60)
    assert r.returncode>=0,(action,'crash',r.returncode,r.stdout,r.stderr)
    data=json.loads(r.stdout);assert (r.returncode==0)==ok,(action,data,r.stderr)
    checks.append({'action':action,'expected_success':ok,'result':data});return data
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
call('format','EDGE')
keep=RUN/'keep';keep.write_bytes(os.urandom(1024));call('put',keep,'/keep.bin')
large=RUN/'large';large.touch();os.truncate(large,64*1024*1024)
call('put',large,'/too-large.bin',ok=False)
entries=call('ls','/')['entries'];assert [e['name'] for e in entries]==['keep.bin'],entries
call('get',RUN/'after-full','/keep.bin');assert sha(keep)==sha(RUN/'after-full')
# A failed transfer must leave the volume usable and its existing content intact.
call('put',keep,'/after.bin');call('remove','/after.bin')
call('put',keep,'/Case.bin');before=sha(IMAGE);call('put',keep,'/case.BIN',ok=False);call('rename','/keep.bin','/CASE.bin',ok=False);assert sha(IMAGE)==before
# Relocation proves the worker resolves resources within the app, not the work directory.
relocated=RUN/'Moved application.app';shutil.copytree(APP,relocated)
moved=relocated/'Contents/MacOS/NTFSWorker';call('ls','/',worker=moved)
# Conservative hibernation-file policy is tested last, since it blocks all further writes.
call('put',keep,'/hiberfil.sys');before=sha(IMAGE);call('mkdir','/blocked',ok=False);assert sha(IMAGE)==before
report={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'passed':True,'checks':len(checks),'run':str(RUN),'disk_full_preserved_existing_data':True,'partial_import_removed':True,'portable_resource_lookup':True,'hibernation_file_blocks_writes':True,'operations':checks}
(REPORTS_PATH/'edge-tests.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('PASS:',len(checks),'checks; disk-full cleanup; case collisions; app relocation; hibernation guard')
