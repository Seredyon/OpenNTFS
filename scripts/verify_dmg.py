#!/usr/bin/env python3
"""Verify a DMG with a read-only mount, or independent 7-Zip extraction."""
import argparse,hashlib,json,os,plistlib,shutil,subprocess,tempfile
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('dmg',type=Path)
parser.add_argument('--extract',action='store_true',help='Use 7zz/7z when mounting inside the build folder is unavailable.')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
dmg=args.dmg.resolve();output=dmg.parent
cache=output/'.cache/tmp';cache.mkdir(parents=True,exist_ok=True)
os.environ['TMPDIR']=str(cache)+'/'
subprocess.run(['hdiutil','verify',str(dmg),'-quiet'],check=True)
checksum=dmg.with_suffix(dmg.suffix+'.sha256').read_text().split()
assert checksum==[hashlib.sha256(dmg.read_bytes()).hexdigest(),dmg.name],'DMG checksum mismatch'
workspace=Path(tempfile.mkdtemp(prefix='verify-dmg-',dir=cache));attached=False
try:
    if args.extract:
        seven=shutil.which('7zz') or shutil.which('7z')
        if not seven:raise SystemExit('--extract requires 7-Zip (7zz or 7z).')
        # HFS extended attributes are exposed by 7-Zip as colon-named streams.
        # Exclude these pseudo-files while retaining every signed data file.
        subprocess.run([seven,'x','-y',str(dmg),'-o'+str(workspace),'-xr!*:*','OpenNTFS/OpenNTFS.app/*'],check=True,stdout=subprocess.DEVNULL)
        app=workspace/'OpenNTFS/OpenNTFS.app'
        listing=subprocess.check_output([seven,'l','-slt',str(dmg),'OpenNTFS/Applications'],text=True)
        assert 'Mode = l' in listing,'Applications must be a symbolic link'
        link=subprocess.check_output([seven,'x','-so',str(dmg),'-xr!*:*','OpenNTFS/Applications'])
        assert link==b'/Applications','Incorrect Applications link'
    else:
        subprocess.run(['hdiutil','attach',str(dmg),'-readonly','-nobrowse','-noautoopen','-mountpoint',str(workspace)],check=True,stdout=subprocess.DEVNULL)
        attached=True
        app=workspace/'OpenNTFS.app'
        assert (workspace/'Applications').is_symlink()
        assert os.readlink(workspace/'Applications')=='/Applications'
        layout=(workspace/'.DS_Store').read_bytes()
        assert layout[4:8]==b'Bud1' and b'icvp' in layout and b'Iloc' in layout,'Installer window layout missing'
        assert (workspace/'.background/background.tiff').is_file(),'Installer background missing'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString']==(root/'VERSION').read_text().strip()
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    def payload(folder):
        return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}
    assert payload(app)==payload(output/'OpenNTFS.app'),'DMG payload differs from the built app'
    report={'passed':True,'verification_method':'7zip-extraction' if args.extract else 'read-only-mount','signature_valid':True,'checksum_valid':True,'all_payload_files_match_build':True,'applications_shortcut_valid':True,'version':info['CFBundleShortVersionString']}
    (output/'validation').mkdir(exist_ok=True)
    (output/'validation/dmg-tests.json').write_text(json.dumps(report,indent=2)+'\n')
finally:
    if attached:subprocess.run(['hdiutil','detach',str(workspace),'-quiet'],check=True)
    shutil.rmtree(workspace)
print('PASS: DMG checksum, signed app, full payload, Applications shortcut'+('' if args.extract else ' and window layout'))
