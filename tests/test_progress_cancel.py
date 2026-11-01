#!/usr/bin/env python3
"""Serve-mode test: progress lines, SIGUSR1 cancellation, cleanup, Windows-style security, fixsec.
Only a disposable image under build/test-images is written."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import json,os,signal,subprocess,tempfile,time,hashlib,sys
ROOT=Path(__file__).resolve().parents[1]
WORKER=APP_PATH/'Contents/MacOS/NTFSWorker'
RUN=Path(tempfile.mkdtemp(prefix='progress-',dir=IMAGES_PATH))
IMAGE=RUN/'disk.ntfs'; IMAGE.touch(); os.truncate(IMAGE,768*1024*1024)
target={'kind':'image','path':str(IMAGE),'formatConfirmation':str(IMAGE)}
p=subprocess.Popen([str(WORKER),'serve'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
checks={}
def send(action,*args,progress=False,cancel_after=None):
    req={'action':action,'target':target,'arguments':list(map(str,args)),'uid':os.getuid()}
    if progress:req['progress']=True
    p.stdin.write(json.dumps(req)+'\n');p.stdin.flush()
    lines=0;last=-1;sent=False
    while True:
        obj=json.loads(p.stdout.readline())
        if 'progress' in obj:
            assert obj['progress']>=last;last=obj['progress'];lines+=1
            if cancel_after is not None and not sent and last>=cancel_after:os.kill(p.pid,signal.SIGUSR1);sent=True
            continue
        return obj,lines,last
r,_,_=send('format','PROGRESS');assert r.get('ok'),r
big=RUN/'big.bin'
with big.open('wb') as f:
    for i in range(320):f.write(os.urandom(1024*1024))
r,lines,last=send('put',big,'/cancelled.bin',progress=True,cancel_after=64*1024*1024)
checks['put_cancelled']=r.get('error')=='Operation cancelled';checks['put_progress_lines']=lines
listing,_,_=send('ls','/')
checks['no_temporary_left']=not any(e['name'].startswith('.openntfs-') or e['name']=='cancelled.bin' for e in listing['entries'])
r,lines,last=send('put',big,'/big.bin',progress=True)
checks['put_ok']=r.get('ok') is True and r['bytes']==big.stat().st_size and last==r['bytes'] and lines>=2
out=RUN/'partial.bin'
r,lines,last=send('get',out,'/big.bin',progress=True,cancel_after=32*1024*1024)
checks['get_cancelled']=r.get('error')=='Operation cancelled';checks['partial_export_removed']=not out.exists()
r,_,_=send('get',out,'/big.bin');checks['get_ok']=r.get('ok') is True
checks['roundtrip_sha256']=hashlib.sha256(out.read_bytes()).hexdigest()==hashlib.sha256(big.read_bytes()).hexdigest()
r,_,_=send('ls','/');checks['session_alive_after_cancel']='entries' in r
# Many folder/file operations through one process exercise OpenDir/CloseDir reference counting.
for i in range(40):
    assert send('mkdir',f'/d{i}')[0].get('ok');assert send('put',RUN/'partial.bin' if False else big if i==0 else __file__,f'/d{i}/f.py')[0].get('ok')
r,_,_=send('fixsec','/d1');checks['fixsec_new_objects_untouched']=r.get('fixed')==0 and r.get('checked')==2
p.stdin.close();checks['clean_exit']=p.wait(timeout=30)==0
for f in RUN.iterdir():f.unlink()
RUN.rmdir()
checks['success']=all(v for k,v in checks.items() if k!='put_progress_lines') and checks['put_progress_lines']>=1
print(json.dumps(checks,indent=1))
(REPORTS_PATH/'progress-cancel-tests.json').write_text(json.dumps(checks,indent=1,sort_keys=True))
sys.exit(0 if checks['success'] else 1)
