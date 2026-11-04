"""Regression: USB partition geometry must not carry into a later image request."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH, SOURCE_PATH
import json, os, struct, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = SOURCE_PATH/'Sources/NTFSWorker.mm'
with tempfile.TemporaryDirectory(prefix='target-state-', dir=IMAGES_PATH) as directory:
    run = Path(directory)
    macos = run/'Contents/MacOS'; macos.mkdir(parents=True)
    harness = run/'state_test.mm'
    harness.write_text('#define main productionMain\n#include '+json.dumps(str(source))+'\n#undef main\n' + '''
int main(int argc, char**argv){
 struct rlimit noCore{0,0};setrlimit(RLIMIT_CORE,&noCore);
 @autoreleasepool{
  // Simulate leftover metadata from an earlier USB request without accessing any device.
  partitionOffset=16384;volumeFlags=0x80;
  int result=processRequest([NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile],argv[0]);
  if(result)return result;
  return partitionOffset==0&&volumeFlags==0?0:3;
 }
}
''')
    worker = macos/'StateTest'
    common = ['-std=c++17','-fobjc-arc','-O2','-arch','arm64','-mmacosx-version-min=13.0','-fmodules-cache-path='+os.environ['CLANG_MODULE_CACHE_PATH']]
    # The worker source linked with the NTFS implementation built by build.sh.
    core = APP_PATH.parent/'.cache/NativeNTFSCore.o'
    subprocess.run(['xcrun','clang++',*common,'-I',str(SOURCE_PATH/'Sources'),'-c',str(harness),'-o',str(run/'state_test.o')],check=True)
    subprocess.run(['xcrun','swiftc','-target','arm64-apple-macosx13.0',str(run/'state_test.o'),str(core),'-lc++','-framework','Foundation','-framework','IOKit','-o',str(worker)],check=True)
    image = run/'fresh.ntfs';image.touch();os.truncate(image,64*1024*1024)
    request = {'action':'format','target':{'kind':'image','path':str(image),'formatConfirmation':str(image)},'arguments':['STATE-TEST']}
    result = subprocess.run([str(worker)],input=json.dumps(request),text=True,capture_output=True)
    assert result.returncode==0,(result.returncode,result.stdout,result.stderr)
    assert json.loads(result.stdout)['ok']
    with image.open('rb') as stream:
        boot=stream.read(512)
    assert boot[3:11]==b'NTFS    ' and boot[510:512]==b'\x55\xaa'
    assert struct.unpack_from('<I',boot,28)[0]==0,'Stale USB offset was written into the image BPB'
report={'passed':True,'simulated_previous_usb_partition_offset':16384,'formatted_image_hidden_sectors':0,
        'request_metadata_reset':True,'physical_device_access':False,'temporary_files_removed':True}
(REPORTS_PATH/'target-state-tests.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: image formatting resets previous USB geometry and flags; no physical device accessed')
