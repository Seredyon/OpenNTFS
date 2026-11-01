#!/usr/bin/env python3
"""Regression: read-only lookups in folders mixing upper/lower-case names (missing $UpCase).
Uses fresh request-mode processes for reads, like reopening the volume. Disposable image only."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import json,os,subprocess,tempfile,hashlib,sys
ROOT=Path(__file__).resolve().parents[1]
WORKER=APP_PATH/'Contents/MacOS/NTFSWorker'
RUN=Path(tempfile.mkdtemp(prefix='mixedcase-',dir=IMAGES_PATH))
IMAGE=RUN/'disk.ntfs'; IMAGE.touch(); os.truncate(IMAGE,128*1024*1024)
def call(action,*args):
    r=subprocess.run([str(WORKER),'request'],input=json.dumps({'action':action,'target':{'kind':'image','path':str(IMAGE),'formatConfirmation':str(IMAGE)},'arguments':list(map(str,args)),'uid':os.getuid()}),text=True,capture_output=True,timeout=60)
    return json.loads(r.stdout)
src=RUN/'f.bin'; src.write_bytes(os.urandom(70000)); want=hashlib.sha256(src.read_bytes()).hexdigest()
assert call('format','MIXED').get('ok')
layout=['/Album/','/Album/a_b.txt','/Album/photo.png','/Album/Sub/','/Album/Sub/deep.txt','/Album/trailing_','/Album/ZETA.TXT','/Album/Ёлка.txt','/Album/ёжик/','/Album/ёжик/Файл.TXT','/A/','/A/a.txt','/A/S/','/A/S/x.txt']
files=[]
for p in layout:
    r=call('mkdir',p.rstrip('/')) if p.endswith('/') else call('put',src,p)
    assert r.get('ok'),(p,r)
    if not p.endswith('/'): files.append(p)
results={}
before=hashlib.sha256(IMAGE.read_bytes()).hexdigest()
for f in files:
    out=RUN/('out-'+str(len(results)))
    r=call('get',out,f)
    results[f]=r.get('ok') is True and hashlib.sha256(out.read_bytes()).hexdigest()==want
for d in ['/Album','/Album/Sub','/Album/ёжик','/A/S']:
    results['ls '+d]='entries' in call('ls',d)
after=hashlib.sha256(IMAGE.read_bytes()).hexdigest()
results['read_only_image_unchanged']=before==after
for f in RUN.iterdir(): f.unlink()
RUN.rmdir()
report={'success':all(results.values()),'checks':results}
(REPORTS_PATH/'mixed-case-tests.json').write_text(json.dumps(report,indent=1,ensure_ascii=False,sort_keys=True))
print(json.dumps(report,indent=1,ensure_ascii=False)); sys.exit(0 if report['success'] else 1)
