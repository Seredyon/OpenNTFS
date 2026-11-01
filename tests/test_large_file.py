from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import hashlib,json,os,shutil,subprocess,tempfile,time
root=Path(__file__).resolve().parents[1];run=Path(tempfile.mkdtemp(prefix='large-',dir=IMAGES_PATH));image=run/'large.ntfs';source=run/'over-4GiB.bin';destination=run/'returned.bin';size=4*1024**3+65537
for p,n in [(image,6*1024**3),(source,size)]:
 with p.open('wb') as f:f.truncate(n)
with source.open('r+b') as f:
 for position in (0,2*1024**3,4*1024**3-1024,4*1024**3+32768):f.seek(position);f.write(os.urandom(1024))
worker=APP_PATH/'Contents/MacOS/NTFSWorker';measurements=[];started=time.monotonic()
def call(action,*args):
 t=time.monotonic();p=subprocess.run([str(worker),'request'],input=json.dumps({'action':action,'target':{'kind':'image','path':str(image),'formatConfirmation':str(image)},'arguments':list(map(str,args))}),capture_output=True,text=True,timeout=900)
 assert p.returncode==0,(action,p.stdout,p.stderr);data=json.loads(p.stdout);measurements.append({'action':action,'seconds':round(time.monotonic()-t,2),'result':data});print('OK',action,measurements[-1]['seconds'],'sec',flush=True);return data
report={'bytes':size,'physical_USB':False}
try:
 call('format','LARGEFILE');assert call('put',source,'/over-4GiB.bin')['bytes']==size
 entries=call('ls','/')['entries'];assert len(entries)==1 and entries[0]['size']==size
 assert call('get',destination,'/over-4GiB.bin')['bytes']==size
 def sha(path):
  with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
 expected=sha(source);assert expected==sha(destination);print('OK byte-for-byte SHA-256 equality',flush=True)
 # Independent reader extracts a stream; no additional large output file is created.
 seven=shutil.which('7zz') or shutil.which('7z')
 if seven:
  p=subprocess.Popen([seven,'x','-so',str(image),'over-4GiB.bin'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  independent=hashlib.file_digest(p.stdout,'sha256').hexdigest();error=p.stderr.read();assert p.wait(timeout=120)==0,error;assert expected==independent
 report.update(passed=True,sha256=expected,independent_7zip_verified=bool(seven))
 print('PASS: file larger than 4 GiB, complete round trip and independent NTFS read',flush=True)
except Exception as error:
 report.update(passed=False,error=str(error));raise
finally:
 report.update(operations=measurements,seconds=round(time.monotonic()-started,2))
 for path in (image,source,destination):path.unlink(missing_ok=True)
 report['large_temporary_files_removed']=True
 (REPORTS_PATH/'large-file-tests.json').write_text(json.dumps(report,indent=2))
