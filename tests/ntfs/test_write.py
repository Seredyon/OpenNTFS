#!/usr/bin/env python3
"""Native write tests on disposable images.

Images are formatted by a reference implementation (OPENNTFS_REFERENCE_WORKER, the application's
existing worker), written by the native code, then verified three ways: the native reader, the
reference implementation reading the same files back, and the reference consistency checker
(it must report no errors). Skipped when no reference worker is available.

Usage: test_write.py NATIVE_CLI OUTPUT_DIR
"""
import hashlib
import json
import os
import random
import struct
import subprocess
import sys
from pathlib import Path

native, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
reference = os.environ.get('OPENNTFS_REFERENCE_WORKER')
# Optional build of the reference worker whose checker also lists minor problems.
checker = os.environ.get('OPENNTFS_REFERENCE_CHECKER', reference)
output.mkdir(parents=True, exist_ok=True)
if not reference or not Path(reference).is_file():
    (output / 'write-results.json').write_text(json.dumps({'skipped': True}) + '\n')
    print('SKIP: OPENNTFS_REFERENCE_WORKER is not set')
    sys.exit(0)
work = output / 'write'
work.mkdir(exist_ok=True)
for old in work.iterdir():
    if old.is_file():
        old.unlink()
rng = random.Random(4011)
report = {'scenarios': []}


class Image:
    def __init__(self, name, megabytes):
        self.path = work / f'{name}.ntfs'
        self.path.touch()
        os.truncate(self.path, megabytes * 1024 * 1024)
        self.files = {}         # NTFS path -> bytes
        self.dirs = {'/'}
        assert self.ref('format', name.upper()[:10])['ok']

    def ref(self, action, *args, ok=True, program=None):
        body = {'action': action, 'target': {'kind': 'image', 'path': str(self.path), 'formatConfirmation': str(self.path)},
                'arguments': list(map(str, args))}
        result = subprocess.run([program or reference, 'request'], input=json.dumps(body), capture_output=True, text=True, timeout=900)
        data = json.loads(result.stdout)
        assert (result.returncode == 0) == ok, (action, args, data)
        return data

    def write(self, operations, ok=True, code=0):
        plan = work / 'ops.json'
        plan.write_text(json.dumps(operations))
        result = subprocess.run([str(native), 'write', str(self.path), str(plan)], capture_output=True, text=True, timeout=900)
        if ok:
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode == (code or 1), (result.returncode, result.stderr)
        return result

    def native(self, command, *args, ok=True):
        result = subprocess.run([str(native), command, str(self.path), *map(str, args)], capture_output=True, timeout=900)
        assert (result.returncode == 0) == ok, (command, args, result.stderr.decode())
        return result.stdout

    def check(self, expect='clean'):
        result = self.ref('check', 'verify', program=checker)
        problems = [line for line in result['log'].splitlines() if line and not line.startswith(' ') and not any(
            line.startswith(p) for p in ('Checking Volume', 'Type of', 'Serial', 'Volume label', 'Verifying', '$UpCase', 'Checking volume bitmap', 'No repairs', 'The volume'))]
        assert result['result'] == expect, (result['result'], problems)
        return result

    def verify(self):
        # Native reader.
        for folder in self.dirs:
            names = {e['name'] for e in json.loads(self.native('list', folder))}
            if folder == '/':
                names = {n for n in names if not n.startswith('$')}
            expected = {p.rsplit('/', 1)[1] for p in list(self.files) + list(self.dirs) if p != '/' and (p.rsplit('/', 1)[0] or '/') == folder}
            assert names == expected, (folder, sorted(names ^ expected)[:8])
        for path, data in self.files.items():
            assert self.native('read', path) == data, path
        # Reference implementation reads the same files.
        for folder in self.dirs:
            listed = {e['name']: e for e in self.ref('ls', folder)['entries']}
            for path, data in self.files.items():
                if (path.rsplit('/', 1)[0] or '/') == folder:
                    assert listed[path.rsplit('/', 1)[1]]['size'] == len(data), path
        sample = list(self.files.items())
        for path, data in rng.sample(sample, min(len(sample), 40)):
            out = work / 'readback'
            if out.exists():
                out.unlink()
            self.ref('get', out, path)
            assert out.read_bytes() == data, path
        # Reference consistency checker.
        self.check()


def host(data):
    path = work / ('src-' + hashlib.sha1(data).hexdigest()[:20])
    if not path.exists():
        path.write_bytes(data)
    return str(path)


def descriptor(sid_users=False):
    """A self-relative security descriptor: owner/group Administrators, DACL Everyone full access."""
    def sid(authority, *subs):
        return struct.pack('<BB', 1, len(subs)) + authority.to_bytes(6, 'big') + b''.join(struct.pack('<I', s) for s in subs)
    admins = sid(5, 32, 544)
    everyone = sid(1, 0) if not sid_users else sid(5, 32, 545)
    ace = struct.pack('<BBHI', 0, 0x13, 8 + len(everyone), 0x1f01ff) + everyone
    acl = struct.pack('<BBHHH', 2, 0, 8 + len(ace), 1, 0) + ace
    owner = 20
    group = owner + len(admins)
    dacl = group + len(admins)
    return (struct.pack('<BBHIIII', 1, 0, 0x8004, owner, group, 0, dacl) + admins + admins + acl).hex()


def scenario(name, function):
    function()
    report['scenarios'].append(name)
    print('ok', name)


# 1. Files and folders of many sizes, nested paths and Unicode names.
def basic():
    image = Image('basic', 160)
    ops = []
    for folder in ['/Docs', '/Docs/Nested', '/Docs/Nested/Deep', '/Ünïcødé папка 日本']:
        ops.append({'op': 'mkdir', 'path': folder})
        image.dirs.add(folder)
    for size in [0, 1, 300, 600, 700, 4095, 4096, 4097, 65536, 1048577, 7 * 1024 * 1024 + 3]:
        data = rng.randbytes(size)
        path = f'/Docs/size-{size}.bin'
        ops.append({'op': 'put', 'local': host(data), 'path': path})
        image.files[path] = data
    for path in ['/Docs/Nested/Deep/привет мир.txt', '/Ünïcødé папка 日本/emoji 🚀.txt', '/Root file.txt']:
        data = rng.randbytes(rng.randrange(1, 5000))
        ops.append({'op': 'put', 'local': host(data), 'path': path})
        image.files[path] = data
    image.write(ops)
    image.verify()
    # The reference implementation can keep writing into folders created natively.
    extra = rng.randbytes(12345)
    image.ref('put', host(extra), '/Docs/Nested/added-by-reference.bin')
    image.files['/Docs/Nested/added-by-reference.bin'] = extra
    image.verify()
    # Name collisions are refused, case-insensitively, without changing the volume.
    image.write([{'op': 'put', 'local': host(b'x'), 'path': '/docs/SIZE-0.BIN'}], ok=False)
    image.write([{'op': 'mkdir', 'path': '/DOCS'}], ok=False)
    image.verify()


# 2. A large folder: the index grows from the record into a multi-level tree; MFT grows too.
def large_folder():
    image = Image('large', 256)
    image.dirs.add('/Many')
    ops = [{'op': 'mkdir', 'path': '/Many'}]
    for i in range(3000):
        data = f'file {i}\n'.encode() * (i % 7 + 1)
        path = f'/Many/item {i:05d} {"z" * (i % 41)}.txt'
        ops.append({'op': 'put', 'local': host(data), 'path': path})
        image.files[path] = data
    image.write(ops)
    image.verify()
    names = list(image.files)
    rng.shuffle(names)
    removed = names[:1700]
    image.write([{'op': 'remove', 'path': p} for p in removed])
    for p in removed:
        del image.files[p]
    image.verify()
    # Lookups through the rebuilt tree, case-insensitively.
    for p in names[1700:1760]:
        assert image.native('read', p.upper()) == image.files[p], p


# 3. Rename within a folder, across folders, case-only, and folders with contents.
def rename():
    image = Image('rename', 96)
    ops = [{'op': 'mkdir', 'path': '/A'}, {'op': 'mkdir', 'path': '/B'}, {'op': 'mkdir', 'path': '/A/Inner'}]
    image.dirs |= {'/A', '/B'}
    payload = {'/A/one.txt': b'one', '/A/two.txt': b'two' * 3000, '/A/Inner/three.txt': b'three'}
    for path, data in payload.items():
        ops.append({'op': 'put', 'local': host(data), 'path': path})
    ops += [{'op': 'rename', 'from': '/A/one.txt', 'to': '/A/uno.txt'},
            {'op': 'rename', 'from': '/A/two.txt', 'to': '/B/two moved.txt'},
            {'op': 'rename', 'from': '/A/uno.txt', 'to': '/A/UNO.txt'},
            {'op': 'rename', 'from': '/A/Inner', 'to': '/B/Inner renamed'}]
    image.write(ops)
    image.files = {'/A/UNO.txt': b'one', '/B/two moved.txt': b'two' * 3000, '/B/Inner renamed/three.txt': b'three'}
    image.dirs |= {'/B/Inner renamed'}
    image.verify()
    image.write([{'op': 'rename', 'from': '/B', 'to': '/B/Inner renamed/loop'}], ok=False)
    image.write([{'op': 'rename', 'from': '/A/UNO.txt', 'to': '/B/TWO MOVED.TXT'}], ok=False)
    image.write([{'op': 'remove', 'path': '/B/Inner renamed', 'directory': True}], ok=False)
    image.write([{'op': 'remove', 'path': '/B/Inner renamed/three.txt'}, {'op': 'remove', 'path': '/B/Inner renamed', 'directory': True}])
    del image.files['/B/Inner renamed/three.txt']
    image.dirs.discard('/B/Inner renamed')
    image.verify()


# 4. Security descriptors are stored once in $Secure and shared.
def security():
    image = Image('security', 96)
    sd, other = descriptor(), descriptor(sid_users=True)
    image.dirs.add('/Secure')
    ops = [{'op': 'mkdir', 'path': '/Secure', 'sd': sd}]
    for i in range(20):
        data = f'{i}'.encode()
        ops.append({'op': 'put', 'local': host(data), 'path': f'/Secure/f{i}', 'sd': sd if i % 2 else other})
        image.files[f'/Secure/f{i}'] = data
    image.write(ops)
    for i in range(20):
        got = json.loads(image.native('security', f'/Secure/f{i}'))['descriptor']
        assert got == (sd if i % 2 else other), i
    assert json.loads(image.native('security', '/Secure'))['descriptor'] == sd
    image.write([{'op': 'setsd', 'path': '/Secure/f0', 'sd': sd}])
    assert json.loads(image.native('security', '/Secure/f0'))['descriptor'] == sd
    image.verify()


# 5. Full volume and fragmented free space.
def space():
    image = Image('space', 64)
    image.write([{'op': 'put', 'local': host(rng.randbytes(80 * 1024 * 1024)), 'path': '/too-big.bin'}], ok=False)
    image.check()
    image.dirs.add('/holes')
    ops = [{'op': 'mkdir', 'path': '/holes'}]
    for i in range(600):
        data = rng.randbytes(16384)
        ops.append({'op': 'put', 'local': host(data), 'path': f'/holes/{i:04d}'})
        image.files[f'/holes/{i:04d}'] = data
    image.write(ops)
    free = json.loads(image.native('free'))
    filler = rng.randbytes(free['freeClusters'] * free['clusterSize'] - 640 * 1024)
    image.write([{'op': 'put', 'local': host(filler), 'path': '/filler.bin'}])
    image.files['/filler.bin'] = filler
    image.write([{'op': 'remove', 'path': f'/holes/{i:04d}'} for i in range(0, 600, 2)])
    for i in range(0, 600, 2):
        del image.files[f'/holes/{i:04d}']
    fragmented = rng.randbytes(150 * 16384)
    image.write([{'op': 'put', 'local': host(fragmented), 'path': '/fragmented.bin'}])
    image.files['/fragmented.bin'] = fragmented
    runs = [a for a in json.loads(image.native('stat', '/fragmented.bin'))['attributes'] if a['type'] == '0x80'][0]['runs']
    assert runs > 20, runs
    image.verify()
    report['fragmented_runs'] = runs


# 6. Interrupted sessions: the volume stays marked dirty and the reference checker repairs it.
def interrupted():
    image = Image('interrupted', 96)
    data = rng.randbytes(2 * 1024 * 1024)
    image.write([{'op': 'mkdir', 'path': '/Work'}, {'op': 'put', 'local': host(data), 'path': '/Work/kept.bin'}])
    image.dirs.add('/Work')
    image.files['/Work/kept.bin'] = data
    image.write([{'op': 'put', 'local': host(rng.randbytes(500000)), 'path': '/Work/lost.bin'}, {'op': 'abort'}], ok=False, code=3)
    assert json.loads(image.native('info'))['dirty'] is True
    image.write([{'op': 'mkdir', 'path': '/Refused'}], ok=False)
    result = image.ref('check', 'repair')
    assert result['writable'], result
    # The interrupted file's record was written before its folder entry; the repair recovers it
    # into its folder (it is not committed data). The native writer then removes it.
    names = {e['name'] for e in json.loads(image.native('list', '/Work'))}
    assert names <= {'kept.bin', 'lost.bin'} and 'kept.bin' in names, names
    if 'lost.bin' in names:
        image.write([{'op': 'remove', 'path': '/Work/lost.bin'}])
    report['interrupted_recovered_orphan'] = 'lost.bin' in names
    image.verify()
    # A failed operation inside a session still commits the earlier ones cleanly.
    image.write([{'op': 'put', 'local': host(b'before'), 'path': '/before.txt'}, {'op': 'fail'}], ok=False)
    image.files['/before.txt'] = b'before'
    assert json.loads(image.native('info'))['dirty'] is False
    image.verify()


# 7. A file whose cluster map needs several MFT records (attribute list with extension records):
#    written, read by both implementations, renamed and moved, then removed.
def attribute_list():
    image = Image('attrlist', 96)
    image.dirs |= {'/holes', '/moved'}
    ops = [{'op': 'mkdir', 'path': '/holes'}, {'op': 'mkdir', 'path': '/moved'}]
    hole = rng.randbytes(8192)
    for i in range(2400):
        ops.append({'op': 'put', 'local': host(hole), 'path': f'/holes/{i:04d}'})
    image.write(ops)
    free = json.loads(image.native('free'))
    filler = rng.randbytes(free['freeClusters'] * free['clusterSize'] - 400 * 1024)
    image.write([{'op': 'put', 'local': host(filler), 'path': '/filler.bin'}])
    image.files['/filler.bin'] = filler
    image.write([{'op': 'remove', 'path': f'/holes/{i:04d}'} for i in range(0, 2400, 2)])
    for i in range(1, 2400, 2):
        image.files[f'/holes/{i:04d}'] = hole
    data = rng.randbytes(1100 * 8192 - 5)
    image.write([{'op': 'put', 'local': host(data), 'path': '/fragmented.bin'}])
    info = json.loads(image.native('stat', '/fragmented.bin'))
    runs = [a for a in info['attributes'] if a['type'] == '0x80'][0]['runs']
    assert runs > 500 and info['extensionRecords'] >= 2, info
    image.files['/fragmented.bin'] = data
    image.verify()
    image.write([{'op': 'rename', 'from': '/fragmented.bin', 'to': '/moved/Fragmented.BIN'}])
    del image.files['/fragmented.bin']
    image.files['/moved/Fragmented.BIN'] = data
    image.verify()
    before = json.loads(image.native('free'))['freeClusters']
    image.write([{'op': 'remove', 'path': '/moved/Fragmented.BIN'}])
    del image.files['/moved/Fragmented.BIN']
    assert json.loads(image.native('free'))['freeClusters'] >= before + 1100 * 2, 'clusters of the fragmented file were not released'
    image.verify()
    report['attribute_list'] = {'runs': runs, 'extension_records': info['extensionRecords']}


for name, function in [('attribute_list', attribute_list), ('basic', basic), ('large_folder', large_folder), ('rename', rename), ('security', security),
                       ('space', space), ('interrupted', interrupted)]:
    scenario(name, function)
report['passed'] = True
report['verification'] = ['native reader', 'reference reader (ls/get)', 'reference consistency checker (clean)']
(output / 'write-results.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS: write scenarios', ', '.join(report['scenarios']))
