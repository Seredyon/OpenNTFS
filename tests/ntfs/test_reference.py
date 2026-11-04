#!/usr/bin/env python3
"""Cross-check the native reader against volumes written by a separate NTFS implementation.

The reference writer is the application's existing worker (set OPENNTFS_REFERENCE_WORKER to its
NTFSWorker binary). It only creates the disposable images; every comparison uses the original
host files. The test is skipped when no reference worker is available.

Usage: test_reference.py NATIVE_CLI OUTPUT_DIR
"""
import hashlib
import json
import os
import random
import subprocess
import sys
from pathlib import Path

native, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
reference = os.environ.get('OPENNTFS_REFERENCE_WORKER')
output.mkdir(parents=True, exist_ok=True)
if not reference or not Path(reference).is_file():
    (output / 'reference-results.json').write_text(json.dumps({'skipped': True, 'reason': 'no reference worker'}) + '\n')
    print('SKIP: OPENNTFS_REFERENCE_WORKER is not set')
    sys.exit(0)

work = output / 'reference'
work.mkdir(exist_ok=True)
for old in work.glob('*'):
    if old.is_file():
        old.unlink()
image = work / 'reference.ntfs'
checks = []


def request(action, *args, operations=None, ok=True):
    body = {'action': action, 'target': {'kind': 'image', 'path': str(image), 'formatConfirmation': str(image)},
            'arguments': list(map(str, args))}
    if operations is not None:
        body['operations'] = operations
    result = subprocess.run([reference, 'request'], input=json.dumps(body), capture_output=True, text=True, timeout=900)
    data = json.loads(result.stdout)
    assert (result.returncode == 0) == ok, (action, data)
    return data


def cli(command, *args, ok=True):
    result = subprocess.run([str(native), command, str(image), *map(str, args)], capture_output=True, timeout=600)
    assert (result.returncode == 0) == ok, (command, args, result.stderr.decode())
    checks.append(command)
    return result.stdout


rng = random.Random(1103)
image.touch()
os.truncate(image, 384 * 1024 * 1024)
request('format', 'REFERENCE')

files = {}          # NTFS path -> host file


def host_file(name, size, pattern=None):
    path = work / ('src-' + hashlib.sha1(name.encode()).hexdigest()[:16])
    if pattern is None:
        path.write_bytes(rng.randbytes(size))
    else:
        path.write_bytes((pattern * (size // len(pattern) + 1))[:size])
    return path


operations = []
for folder in ['/Docs', '/Docs/Nested', '/Docs/Nested/Deep', '/Ünïcødé папка', '/Big', '/Frag']:
    operations.append({'op': 'mkdir', 'args': [folder]})
for size in [0, 1, 600, 4095, 4096, 4097, 65536, 1048577]:
    name = f'/Docs/size-{size}.bin'
    files[name] = host_file(name, size)
for name in ['/Docs/Nested/Deep/привет мир.txt', '/Ünïcødé папка/日本語ファイル.txt', '/Docs/emoji 🚀 file.txt',
             '/Docs/Nested/UPPER.TXT', '/Docs/Nested/lower.txt', '/Docs/spaces and.dots...txt']:
    files[name] = host_file(name, rng.randrange(1, 9000))
for path, host in files.items():
    operations.append({'op': 'put', 'args': [str(host), path]})
# A directory large enough for a multi-level index B+ tree.
shared = host_file('shared', 300)
for i in range(3000):
    name = f'/Big/file {i:05d} {"x" * (i % 37)}.dat'
    operations.append({'op': 'put', 'args': [str(shared), name]})
    files[name] = shared
for start in range(0, len(operations), 4000):
    request('batch', operations=operations[start:start + 4000])

# Fragment the free space, then write a file that has to use hundreds of small holes, so its
# cluster map needs more space than one MFT record (an attribute list with extension records).
hole = host_file('hole', 8192)
fill = [{'op': 'put', 'args': [str(hole), f'/Frag/hole-{i:04d}']} for i in range(4000)]
request('batch', operations=fill)
# Use up the remaining contiguous space so that only the holes are left.
free = json.loads(cli('free'))
filler_size = free['freeClusters'] * free['clusterSize'] - 6 * 1024 * 1024
filler = work / 'filler'
with filler.open('wb') as handle:
    handle.truncate(filler_size)
request('put', filler, '/Frag/filler.bin')
filler.unlink()
request('batch', operations=[{'op': 'remove', 'args': [f'/Frag/hole-{i:04d}']} for i in range(0, 4000, 2)])
for i in range(1, 4000, 2):
    files[f'/Frag/hole-{i:04d}'] = hole
fragmented = host_file('fragmented', 1900 * 8192 - 777)
request('put', fragmented, '/Frag/fragmented.bin')
files['/Frag/fragmented.bin'] = fragmented

# Compare every directory listing and file with the host originals.
directories = {'/Frag': {'filler.bin'}}
for path in files:
    parent = path.rsplit('/', 1)[0] or '/'
    directories.setdefault(parent, set()).add(path.rsplit('/', 1)[1])
for folder in ['/Docs', '/Docs/Nested', '/Docs/Nested/Deep', '/Ünïcødé папка', '/Big', '/Frag']:
    parent = folder.rsplit('/', 1)[0] or '/'
    directories.setdefault(parent, set()).add(folder.rsplit('/', 1)[1])
for folder, names in directories.items():
    listed = json.loads(cli('list', folder))
    got = {entry['name'] for entry in listed}
    if folder == '/':
        system = {name for name in got if name.startswith('$')}
        assert {'$MFT', '$MFTMirr', '$LogFile', '$Volume', '$AttrDef', '$Bitmap', '$Boot', '$UpCase'} <= system | {'$Volume'}, system
        got -= system
    assert got == names, (folder, sorted(got ^ names)[:10])
    for entry in listed:
        child = (folder.rstrip('/') + '/' + entry['name'])
        if child in files:
            assert entry['size'] == files[child].stat().st_size, (child, entry['size'])
digests = {}
for path, host in files.items():
    if host not in digests:
        digests[host] = hashlib.sha256(host.read_bytes()).hexdigest()
    assert hashlib.sha256(cli('read', path)).hexdigest() == digests[host], path
# Case-insensitive lookups go through the index B+ tree.
for i in range(0, 3000, 97):
    name = f'/big/FILE {i:05d} {"X" * (i % 37)}.DAT'
    assert cli('read', name) == shared.read_bytes(), name
cli('read', '/Big/file 99999 missing.dat', ok=False)
info = json.loads(cli('stat', '/Frag/fragmented.bin'))
data = [a for a in info['attributes'] if a['type'] == '0x80' and a['name'] == '']
assert len(data) == 1 and data[0]['runs'] >= 500, info
free = json.loads(cli('free'))
assert 0 < free['freeClusters'] < free['totalClusters'], free
report = {'passed': True, 'files_compared': len(files), 'directories_compared': len(directories),
          'fragmented_runs': data[0]['runs'], 'fragmented_extension_records': info['extensionRecords'],
          'native_commands': len(checks), 'free_clusters': free['freeClusters'],
          'reference_writer': 'application worker (separate implementation)'}
(output / 'reference-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"PASS: {len(files)} files and {len(directories)} directories match; fragmented file has "
      f"{data[0]['runs']} runs in {info['extensionRecords']} extension records")
