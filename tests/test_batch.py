#!/usr/bin/env python3
"""Batch operations: group commit, progress, cancellation and rollback, collation-safe collisions,
case-only rename and speed versus single requests. Disposable image only."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import json,os,signal,subprocess,tempfile,time,hashlib,sys
ROOT=Path(__file__).resolve().parents[1]
WORKER=APP_PATH/'Contents/MacOS/NTFSWorker'
RUN=Path(tempfile.mkdtemp(prefix='batch-',dir=IMAGES_PATH))
IMAGE=RUN/'disk.ntfs'; IMAGE.touch(); os.truncate(IMAGE,1024*1024*1024)
target={'kind':'image','path':str(IMAGE),'formatConfirmation':str(IMAGE)}
p=subprocess.Popen([str(WORKER),'serve'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
def send(action,*args,operations=None,progress=False,on_progress=None):
    req={'action':action,'target':target,'arguments':list(map(str,args)),'uid':os.getuid()}
    if operations is not None:req['operations']=operations
    if progress:req['progress']=True
    p.stdin.write(json.dumps(req)+'\n');p.stdin.flush()
    while True:
        o=json.loads(p.stdout.readline())
        if 'progress' in o and 'ok' not in o and 'error' not in o:
            if on_progress:on_progress(o)
            continue
        return o
def names(path):return {e['name'] for e in send('ls',path)['entries']}
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
checks={}
assert send('format','BATCH').get('ok')
src=RUN/'src';src.mkdir()
files=[]
for i in range(300):
    f=src/f'f{i:03}.bin';f.write_bytes(os.urandom(1000+i*37));files.append(f)
big=src/'big.bin';big.write_bytes(os.urandom(48*1024*1024))
# Speed: 100 single puts vs one batch of 300 + big
t=time.time()
for f in files[:100]:assert send('put',f,'/single-'+f.name).get('ok')
single=(time.time()-t)/100
ops=[{'op':'mkdir','args':['/Tree']},{'op':'mkdir','args':['/Tree/Sub']}]
ops+=[{'op':'put','args':[str(f),('/Tree/' if i%2 else '/Tree/Sub/')+f.name]} for i,f in enumerate(files)]
ops+=[{'op':'put','args':[str(big),'/Tree/big.bin']}]
items=[]
t=time.time();r=send('batch',operations=ops,progress=True,on_progress=lambda o:items.append(o.get('item')));batch_time=time.time()-t
checks['batch_ok']=r.get('ok') is True and r['completed']==len(ops)
checks['batch_progress_items']=len(items)>0 and max(i for i in items if i is not None)==len(ops)-1
checks['per_file_ms_single']=round(single*1000,1);checks['per_file_ms_batch']=round(batch_time*1000/len(ops),1)
checks['batch_faster']=batch_time/len(ops)<single
# Read back everything in one read-only batch and compare
out=RUN/'out';out.mkdir()
gets=[{'op':'get','args':[str(out/(('a-' if i%2 else 'b-')+f.name)),('/Tree/' if i%2 else '/Tree/Sub/')+f.name]} for i,f in enumerate(files)]
gets.append({'op':'get','args':[str(out/'big.bin'),'/Tree/big.bin']})
before=sha(IMAGE)
r=send('batch',operations=gets)
checks['get_batch_ok']=r.get('ok') is True and r['completed']==len(gets)
checks['get_batch_read_only']=before==sha(IMAGE)
checks['contents_equal']=all(sha(out/(('a-' if i%2 else 'b-')+f.name))==sha(f) for i,f in enumerate(files)) and sha(out/'big.bin')==sha(big)
checks['no_temporaries']=not any(n.startswith('.openntfs-') for d in ['/','/Tree','/Tree/Sub'] for n in names(d))
# Error in the middle: third put collides -> earlier committed? pending rolled back, no temps
ops=[{'op':'put','args':[str(files[0]),'/E1.bin']},{'op':'put','args':[str(files[1]),'/E2.bin']},{'op':'put','args':[str(files[2]),'/Tree']},{'op':'put','args':[str(files[3]),'/E4.bin']}]
r=send('batch',operations=ops)
root=names('/')
checks['error_reported_with_count']='error' in r and r.get('completed')==0
checks['error_rolled_back_pending']=not ({'E1.bin','E2.bin','E4.bin'}&root) and not any(n.startswith('.openntfs-') for n in root)
# Duplicate differing only by case inside one batch
r=send('batch',operations=[{'op':'put','args':[str(files[0]),'/Dup.bin']},{'op':'put','args':[str(files[1]),'/dup.BIN']}])
checks['case_duplicate_in_batch_rejected']='error' in r and 'Dup.bin' not in names('/')
# Collisions follow the volume's own $UpCase table (shared with the engine): either the name is
# rejected as existing, or both names coexist and each opens to its own content. Never a crash.
assert send('put',files[0],'/file.txt').get('ok')
r=send('put',files[1],'/fıle.txt');root=names('/')
if 'error' in r: checks['upcase_consistent']='fıle.txt' not in root
else:
    o1,o2=RUN/'u1',RUN/'u2'
    checks['upcase_consistent']=send('get',o1,'/file.txt').get('ok') is True and send('get',o2,'/fıle.txt').get('ok') is True and sha(o1)==sha(files[0]) and sha(o2)==sha(files[1])
assert send('put',files[2],'/Mixed.TXT').get('ok')
r=send('put',files[3],'/mIXED.txt')
checks['ascii_case_collision_rejected']='error' in r and 'mIXED.txt' not in names('/')
checks['worker_alive_after_collision']='entries' in send('ls','/')
# Case-only rename
r=send('rename','/file.txt','/FILE.txt');root=names('/')
checks['case_only_rename']=r.get('ok') is True and 'FILE.txt' in root and 'file.txt' not in root and not any(n.startswith('.openntfs-') for n in root)
# Cancellation in the middle of a large batch
ops=[{'op':'put','args':[str(big),f'/C/{i}.bin']} for i in range(6)]
assert send('mkdir','/C').get('ok')
sent=[False]
def cancel(o):
    if not sent[0] and o['progress']>40*1024*1024:os.kill(p.pid,signal.SIGUSR1);sent[0]=True
r=send('batch',operations=ops,progress=True,on_progress=cancel)
c=names('/C')
checks['cancel_reported']=r.get('error')=='Operation cancelled'
checks['cancel_no_partial_or_temp']=all(n.endswith('.bin') and not n.startswith('.openntfs-') for n in c) and len(c)==r.get('completed',-1)
p.stdin.close();checks['clean_exit']=p.wait(timeout=60)==0
import shutil;shutil.rmtree(RUN)
ok=all(v for k,v in checks.items() if not k.startswith('per_file_ms'))
report={'success':ok,'checks':checks}
(REPORTS_PATH/'batch-tests.json').write_text(json.dumps(report,indent=1,sort_keys=True))
print(json.dumps(report,indent=1));sys.exit(0 if ok else 1)
