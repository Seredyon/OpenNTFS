from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import hashlib,json,os,struct,subprocess,tempfile
root=Path(__file__).resolve().parents[1];run=Path(tempfile.mkdtemp(prefix='flags-',dir=IMAGES_PATH));image=run/'test.ntfs';image.touch();os.truncate(image,64*1024*1024);fixture=run/'source';fixture.write_bytes(os.urandom(8193));worker=APP_PATH/'Contents/MacOS/NTFSWorker';checks=[]
def call(action,*args,ok=True):
 r=subprocess.run([str(worker),'request'],input=json.dumps({'action':action,'target':{'kind':'image','path':str(image),'formatConfirmation':str(image)},'arguments':list(map(str,args))}),capture_output=True,text=True)
 assert r.returncode>=0,(action,r.returncode);data=json.loads(r.stdout);assert (r.returncode==0)==ok,(action,data,r.stderr);checks.append({'action':action,'success_expected':ok,'response':data});return data
call('format','FLAGS')
with image.open('r+b') as f:
 boot=f.read(512);cluster=boot[13]*struct.unpack_from('<H',boot,11)[0];code=struct.unpack_from('<b',boot,64)[0];record=(1<<-code) if code<0 else code*cluster;position=struct.unpack_from('<Q',boot,48)[0]*cluster+record*3;f.seek(position);data=f.read(record);at=struct.unpack_from('<H',data,20)[0]
 while struct.unpack_from('<I',data,at)[0]!=0x70:at+=struct.unpack_from('<I',data,at+4)[0]
 flagpos=position+at+struct.unpack_from('<H',data,at+20)[0]+10

def set_flags(flags):
 with image.open('r+b') as f:f.seek(flagpos);f.write(struct.pack('<H',flags))
def hash_image():
 with image.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
set_flags(0x80);before=hash_image();health=call('health');assert health['flags']==0x80 and health['engineState']==2 and health['journalRecoveryNeeded']==False;assert before==hash_image()
call('put',fixture,'/test.bin');call('get',run/'roundtrip','/test.bin');assert fixture.read_bytes()==(run/'roundtrip').read_bytes();assert call('health')['flags']==0x80
call('remove','/test.bin');assert call('health')['flags']==0x80
space=run/'space.bin';space.write_bytes(bytes(1<<20));free=call('health')['freeBytes'];assert free>0
call('put',space,'/space.bin');assert call('health')['freeBytes']<=free-(1<<20);call('remove','/space.bin');assert call('health')['freeBytes']==free
for flags in (1,0x81,2,4,0x10,0x20,0x4000):
 set_flags(flags);before=hash_image();call('put',fixture,'/must-not-exist',ok=False);assert before==hash_image()
set_flags(0x80);assert call('ls','/')['entries']==[]
report={'passed':True,'checks':len(checks),'windows_0x0080_allowed':True,'0x0080_preserved_after_writes':True,'dirty_and_pending_states_rejected_without_writes':True,'operations':checks}
(REPORTS_PATH/'volume-flags-tests.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print('PASS:',len(checks),'checks; 0x0080 reads/writes correctly; dirty/pending flags blocked; flags preserved')
