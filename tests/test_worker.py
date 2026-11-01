#!/usr/bin/env python3
"""Black-box tests. Only new disposable images under build/test-images are written."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import ctypes,datetime,fcntl,hashlib,json,os,plistlib,shutil,struct,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
WORKER=APP_PATH/'Contents/MacOS/NTFSWorker'
RUN=Path(tempfile.mkdtemp(prefix='product-',dir=IMAGES_PATH))
IMAGE=RUN/'disk.ntfs'; IMAGE.touch(); os.truncate(IMAGE,128*1024*1024)
def registry_id(device):
    library=ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
    library.IOBSDNameMatching.argtypes=[ctypes.c_uint,ctypes.c_uint,ctypes.c_char_p];library.IOBSDNameMatching.restype=ctypes.c_void_p
    library.IOServiceGetMatchingService.argtypes=[ctypes.c_uint,ctypes.c_void_p];library.IOServiceGetMatchingService.restype=ctypes.c_uint
    library.IORegistryEntryGetRegistryEntryID.argtypes=[ctypes.c_uint,ctypes.POINTER(ctypes.c_uint64)];library.IOObjectRelease.argtypes=[ctypes.c_uint]
    service=library.IOServiceGetMatchingService(0,library.IOBSDNameMatching(0,0,device.encode()));value=ctypes.c_uint64()
    assert service and library.IORegistryEntryGetRegistryEntryID(service,ctypes.byref(value))==0
    library.IOObjectRelease(service);return value.value
checks=[]
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def call(action,*arguments,ok=True,target=None,unchanged=False):
    if target is None:target={'kind':'image','path':str(IMAGE),'formatConfirmation':str(IMAGE)}
    before=digest(IMAGE) if unchanged else None
    request={'action':action,'target':target,'arguments':list(map(str,arguments)),'uid':os.getuid()}
    result=subprocess.run([str(WORKER),'request'],input=json.dumps(request),text=True,capture_output=True,timeout=45)
    assert result.returncode>=0,(action,'worker crashed',result.returncode,result.stderr)
    try:data=json.loads(result.stdout)
    except Exception:raise AssertionError((action,result.returncode,result.stdout,result.stderr))
    assert (result.returncode==0)==ok,(action,arguments,result.returncode,data,result.stderr)
    if not ok:assert 'error' in data
    if unchanged:assert before==digest(IMAGE),(action,'unexpected disk modification')
    checks.append({'action':action,'expected_success':ok,'result':data,'image_unchanged':unchanged})
    return data
call('format','Проверка')
for path in ['/Документы','/Документы/世界','/Пустая']:call('mkdir',path)
fixtures={}
for name,length in [('empty',0),('small.txt',1234),('случайный-世界.bin',10*1024*1024+17),('emoji-🚀.txt',512)]:
    p=RUN/name;p.write_bytes(os.urandom(length));fixtures[name]=p
    call('put',p,'/Документы/世界/'+name)
entries=call('ls','/Документы/世界',unchanged=True)['entries'];assert len(entries)==len(fixtures)
for entry in entries:
    out=RUN/('out-'+entry['name']);call('get',out,'/Документы/世界/'+entry['name'],unchanged=True)
    assert digest(out)==digest(fixtures[entry['name']]);assert entry['size']==out.stat().st_size
# Rejections must neither crash nor change the NTFS bytes.
for action,args in [('put',(fixtures['small.txt'],'/Документы/世界/small.txt')),('rename',('/Документы/世界/empty','/Документы/世界/small.txt')),('rename',('/Документы','/Документы/世界/inside')),('mkdir',('/Документы',)),('rmdir',('/Документы',)),('rmdir',('/Документы/世界/small.txt',)),('remove',('/Документы',)),('remove',('/missing',)),('mkdir',('/$MFT',)),('mkdir',('/../bad',)),('mkdir',('/bad:name',)),('mkdir',('/'+'a'*256,)),('ls',('/missing',)),('get',(RUN/'absent-output','/missing'))]:call(action,*args,ok=False,unchanged=True)
call('rename','/Документы/世界/small.txt','/Документы/世界/новое.txt')
call('rename','/Документы/世界/emoji-🚀.txt','/Документы/emoji-🚀.txt')
call('remove','/Документы/世界/empty');call('rmdir','/Пустая')
call('get',RUN/'existing-out','/Документы/世界/новое.txt')
old=digest(RUN/'existing-out');call('get',RUN/'existing-out','/Документы/世界/новое.txt',ok=False,unchanged=True);assert old==digest(RUN/'existing-out')
for i in range(80):
    path=f'/Документы/item-{i:03}.txt';call('put',fixtures['small.txt'],path)
for i in range(0,80,2):call('remove',f'/Документы/item-{i:03}.txt')
listing=call('ls','/Документы',unchanged=True)['entries'];assert len(listing)==42
assert not any(e['name'].startswith('.openntfs-') for e in listing)
# Image lease, symlink, missing confirmation, invalid filesystem.
with IMAGE.open('r+b') as locked:
    fcntl.flock(locked,fcntl.LOCK_EX|fcntl.LOCK_NB);call('ls','/',ok=False,unchanged=True)
link=RUN/'link.ntfs';link.symlink_to(IMAGE);call('ls','/',ok=False,target={'kind':'image','path':str(link)},unchanged=True)
call('format','DANGER',ok=False,target={'kind':'image','path':str(IMAGE)},unchanged=True)
blank=RUN/'blank.ntfs';blank.touch();os.truncate(blank,32*1024*1024);call('ls','/',ok=False,target={'kind':'image','path':str(blank)},unchanged=True)
# Dirty-volume check on a separate copy; original remains unchanged.
dirty=RUN/'dirty.ntfs';shutil.copyfile(IMAGE,dirty)
with dirty.open('r+b') as f:
    boot=f.read(512);sector=struct.unpack_from('<H',boot,11)[0];cluster=boot[13]*sector;n=struct.unpack_from('<b',boot,64)[0];record=(1<<-n) if n<0 else n*cluster
    base=struct.unpack_from('<Q',boot,48)[0]*cluster+3*record;f.seek(base);data=bytearray(f.read(record));at=struct.unpack_from('<H',data,20)[0]
    while struct.unpack_from('<I',data,at)[0]!=0x70:at+=struct.unpack_from('<I',data,at+4)[0]
    value=struct.unpack_from('<H',data,at+20)[0];f.seek(base+at+value+10);f.write(b'\x01\x00')
dirty_before=digest(dirty);call('mkdir','/denied',ok=False,target={'kind':'image','path':str(dirty)},unchanged=True);assert dirty_before==digest(dirty)
# Read-only discovery/preflight must reject all current APFS/system partitions without authorization.
disks=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','list','-plist','external','physical']))
protected=[]
for disk in disks.get('AllDisksAndPartitions',[]):
    parent=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',disk['DeviceIdentifier']]))
    for part in disk.get('Partitions',[]):
        info=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',part['DeviceIdentifier']]))
        registry=registry_id(info['DeviceIdentifier'])
        target={'kind':'volume','device':info['DeviceIdentifier'],'parent':parent['DeviceIdentifier'],'identity':info.get('DiskUUID','ioreg:'+str(registry)),'registryID':registry,'size':info.get('IOKitSize'),'offset':info.get('PartitionMapPartitionOffset'),'parentSize':parent.get('IOKitSize'),'tree':parent.get('DeviceTreePath')}
        if info.get('Content') in ['Microsoft Basic Data','Windows_NTFS']:
            call('inspect',target=target,unchanged=True)
            stale=dict(target,registryID=registry+1);call('inspect',ok=False,target=stale,unchanged=True)
            stale=dict(target,identity='wrong-identity');call('inspect',ok=False,target=stale,unchanged=True)
            continue
        call('inspect',ok=False,target=target,unchanged=True);protected.append(info['DeviceIdentifier'])
call('inspect',ok=False,target={'kind':'volume','device':'disk0;echo bad'},unchanged=True)
# Independent NTFS reader checks exported bytes and on-disk directory metadata.
seven=shutil.which('7zz') or shutil.which('7z')
if seven:
    extract=RUN/'independent';extract.mkdir()
    r=subprocess.run([seven,'x',str(IMAGE),'-o'+str(extract),'-y'],capture_output=True,text=True,timeout=60)
    assert r.returncode==0,r.stdout+r.stderr
    assert digest(extract/'Документы/世界/новое.txt')==digest(fixtures['small.txt'])
    assert digest(extract/'Документы/世界/случайный-世界.bin')==digest(fixtures['случайный-世界.bin'])
    assert digest(extract/'Документы/emoji-🚀.txt')==digest(fixtures['emoji-🚀.txt'])
else:print('note: 7-Zip (7zz) not installed; independent NTFS extraction skipped')
report={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'run':str(RUN),'checks':len(checks),'passed':True,'independent_7zip_verified':bool(seven),'protected_partitions_rejected':protected,'physical_USB_writes_tested':False,'operations':checks}
(REPORTS_PATH/'worker-tests.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(f'PASS: {len(checks)} checks; independent NTFS extraction: {bool(seven)}; protected partitions {protected}; no physical disk writes')
print('Test image:',IMAGE)
