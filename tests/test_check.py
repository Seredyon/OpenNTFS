"""Volume check (the engine's chkntfs) on disposable images.

- verify never writes (image hash unchanged), also on dirty and damaged volumes;
- safe clears the dirty flag only when no errors are found, and never repairs;
- repair fixes damaged metadata, after which verify reports a clean volume and writing works;
- a hibernated volume is refused; the checker never reads the worker's request pipe.
"""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(Path(__file__).resolve().parent))
from paths import APP_PATH, IMAGES_PATH, REPORTS_PATH
import hashlib, json, os, struct, subprocess, tempfile

worker = APP_PATH / 'Contents/MacOS/NTFSWorker'
run = Path(tempfile.mkdtemp(prefix='check-', dir=IMAGES_PATH))
checks = []


def call(image, action, *args, ok=True):
    r = subprocess.run([str(worker), 'request'], input=json.dumps({'action': action, 'target': {'kind': 'image', 'path': str(image), 'formatConfirmation': str(image)}, 'arguments': list(map(str, args))}), capture_output=True, text=True, timeout=600)
    data = json.loads(r.stdout)
    assert (r.returncode == 0) == ok, (action, args, data, r.stderr[-2000:])
    checks.append({'image': image.name, 'action': action, 'arguments': list(map(str, args)), 'success_expected': ok, 'response': {k: v for k, v in data.items() if k != 'log'}})
    return data


def digest(image):
    with image.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def geometry(image):
    with image.open('rb') as f:
        boot = f.read(512)
    cluster = boot[13] * struct.unpack_from('<H', boot, 11)[0]
    code = struct.unpack_from('<b', boot, 64)[0]
    record = (1 << -code) if code < 0 else code * cluster
    return struct.unpack_from('<Q', boot, 48)[0] * cluster, record


def set_flags(image, flags):
    """Sets $Volume flags the way a driver does: in $MFT and in its mirror $MFTMirr."""
    mft, record = geometry(image)
    with image.open('rb') as f:
        boot = f.read(512)
    mirror = struct.unpack_from('<Q', boot, 56)[0] * boot[13] * struct.unpack_from('<H', boot, 11)[0]
    with image.open('r+b') as f:
        for base in (mft, mirror):
            f.seek(base + record * 3); data = f.read(record); at = struct.unpack_from('<H', data, 20)[0]
            while struct.unpack_from('<I', data, at)[0] != 0x70: at += struct.unpack_from('<I', data, at + 4)[0]
            f.seek(base + record * 3 + at + struct.unpack_from('<H', data, at + 20)[0] + 10); f.write(struct.pack('<H', flags))


def record_of(image, name):
    """Offset of the (first, contiguous) MFT record whose $FILE_NAME is `name`."""
    mft, record = geometry(image)
    needle = name.encode('utf-16-le')
    with image.open('rb') as f:
        for i in range(16, 4096):
            f.seek(mft + i * record); data = f.read(record)
            if data[:4] == b'FILE' and needle in data:
                return mft + i * record, record
    raise AssertionError('record not found: ' + name)


def make(name, files):
    image = run / (name + '.ntfs'); image.touch(); os.truncate(image, 96 * 1024 * 1024)
    call(image, 'format', name.upper()[:10])
    for remote, size in files:
        local = run / (name + '-' + remote.strip('/').replace('/', '_'))
        local.write_bytes(os.urandom(size))
        call(image, 'put', local, remote)
    return image


def check(image, mode, ok=True):
    return call(image, 'check', mode, ok=ok)


fixture = run / 'fixture'; fixture.write_bytes(os.urandom(20000))

# 1. Clean volume: verify reports clean and changes nothing.
clean = make('clean', [('/a.bin', 5000), ('/b.bin', 70000)])
before = digest(clean); r = check(clean, 'verify')
assert r['result'] == 'clean' and not r['dirtyBefore'] and not r['dirtyAfter'] and r['writable'], r
assert r['totalBytes'] > 90 * 1024 * 1024, r
assert '%' not in r['log'], 'progress output leaked into the log'
assert digest(clean) == before, 'verify modified a clean image'

# 2. Dirty flag only: verify leaves it, safe clears it, writing works again.
dirty = make('dirty', [('/keep.bin', 30000)])
set_flags(dirty, 0x0001)
call(dirty, 'put', fixture, '/blocked.bin', ok=False)
before = digest(dirty); r = check(dirty, 'verify')
assert r['result'] == 'clean' and r['dirtyBefore'] and r['dirtyAfter'] and not r['writable'], r
assert digest(dirty) == before, 'verify modified a dirty image'
r = check(dirty, 'safe')
assert r['result'] == 'clean' and r['dirtyBefore'] and not r['dirtyAfter'] and r['writable'], r
assert call(dirty, 'health')['flags'] & 1 == 0
call(dirty, 'put', fixture, '/after.bin'); call(dirty, 'get', run / 'dirty-roundtrip', '/after.bin')
assert (run / 'dirty-roundtrip').read_bytes() == fixture.read_bytes()
assert check(dirty, 'verify')['result'] == 'clean'

# 3. A Windows volume (informational flag 0x0080) marked dirty: the safe check makes it writable.
upgraded = make('upgraded', [('/x.bin', 4096)])
set_flags(upgraded, 0x0081)
r = check(upgraded, 'safe')
assert r['result'] == 'clean' and r['flagsAfter'] & 1 == 0 and r['writable'], r
call(upgraded, 'put', fixture, '/y.bin')

# 4. Damaged metadata: a file record marked unused while its directory entry remains.
damaged = make('damaged', [('/good.bin', 12000), ('/broken.bin', 9000), ('/other.bin', 40000)])
offset, size = record_of(damaged, 'broken.bin')
with damaged.open('r+b') as f:
    f.seek(offset + 0x16); flags = struct.unpack('<H', f.read(2))[0]; f.seek(offset + 0x16); f.write(struct.pack('<H', flags & ~1))
set_flags(damaged, 0x0001)
before = digest(damaged); r = check(damaged, 'verify')
assert r['result'] == 'errors' and r['dirtyAfter'] and not r['writable'], r
assert digest(damaged) == before, 'verify modified a damaged image'
r = check(damaged, 'safe')
assert r['result'] == 'errors' and r['dirtyAfter'] and not r['writable'], ('safe mode must keep the dirty flag when errors exist', r)
r = check(damaged, 'repair')
assert r['result'] in ('repaired', 'clean') and not r['dirtyAfter'] and r['writable'], r
r = check(damaged, 'verify')
assert r['result'] == 'clean', ('volume not clean after repair', r)
listing = {e['name'] for e in call(damaged, 'ls', '/')['entries']}
assert {'good.bin', 'other.bin'} <= listing, listing
call(damaged, 'get', run / 'damaged-good', '/good.bin')
assert (run / 'damaged-good').read_bytes() == (run / 'damaged-good.bin').read_bytes()
call(damaged, 'put', fixture, '/new.bin')
assert check(damaged, 'verify')['result'] == 'clean'

# 5. Volume bitmap out of sync: a file's clusters marked free (a later write would overwrite it).
def data_runs(image, offset, size):
    """(lcn, length) runs of the unnamed non-resident $DATA attribute in the record at `offset`."""
    with image.open('rb') as f:
        f.seek(offset); d = bytearray(f.read(size))
    usa, count = struct.unpack_from('<HH', d, 4)
    for k in range(1, count): d[k * 512 - 2:k * 512] = d[usa + 2 * k:usa + 2 * k + 2]
    at = struct.unpack_from('<H', d, 20)[0]
    while struct.unpack_from('<I', d, at)[0] != 0xffffffff:
        kind, length = struct.unpack_from('<II', d, at)
        if kind == 0x80 and d[at + 8] and d[at + 9] == 0:
            pos = at + struct.unpack_from('<H', d, at + 32)[0]; lcn = 0; runs = []
            while d[pos]:
                header = d[pos]; ls, os_ = header & 15, header >> 4
                count_ = int.from_bytes(d[pos + 1:pos + 1 + ls], 'little')
                delta = int.from_bytes(d[pos + 1 + ls:pos + 1 + ls + os_], 'little', signed=True)
                lcn += delta; runs.append((lcn, count_)); pos += 1 + ls + os_
            return runs
        at += length
    raise AssertionError('no non-resident $DATA')

shifted = make('bitmap', [('/one.bin', 3000), ('/two.bin', 200000)])
mft, size = geometry(shifted)
with shifted.open('rb') as f:
    boot = f.read(512)
cluster = boot[13] * struct.unpack_from('<H', boot, 11)[0]
bitmap_runs = data_runs(shifted, mft + 6 * size, size)
file_runs = data_runs(shifted, *record_of(shifted, 'two.bin'))
with shifted.open('r+b') as f:
    for lcn, count in file_runs:
        for c in range(lcn, lcn + count):
            byte, bit = divmod(c, 8); base = 0
            for run_lcn, run_count in bitmap_runs:
                if byte < base + run_count * cluster:
                    position = run_lcn * cluster + (byte - base); break
                base += run_count * cluster
            f.seek(position); value = f.read(1)[0]; f.seek(position); f.write(bytes([value & ~(1 << bit) & 0xff]))
before = digest(shifted); r = check(shifted, 'verify')
assert r['result'] in ('errors', 'minor'), r
assert digest(shifted) == before
r = check(shifted, 'repair')
assert r['result'] in ('repaired', 'clean') and r['writable'], r
assert check(shifted, 'verify')['result'] == 'clean'
call(shifted, 'get', run / 'bitmap-two', '/two.bin')
assert (run / 'bitmap-two').read_bytes() == (run / 'bitmap-two.bin').read_bytes()
call(shifted, 'put', fixture, '/three.bin')
call(shifted, 'get', run / 'bitmap-two-again', '/two.bin')
assert (run / 'bitmap-two-again').read_bytes() == (run / 'bitmap-two.bin').read_bytes(), 'repaired bitmap let a new file overwrite an old one'

# 6. Hibernated volume: write modes are refused before anything is written.
hiber = make('hiber', [('/hiberfil.sys', 4096)])
set_flags(hiber, 0x0001)
before = digest(hiber)
for mode in ('safe', 'repair'):
    r = check(hiber, mode, ok=False)
    assert 'hibernation' in r['error'], r
assert digest(hiber) == before
assert check(hiber, 'verify')['result'] in ('clean', 'minor')
call(clean, 'check', 'everything', ok=False)

# 7. Serve mode: progress lines, and requests queued behind a check are not consumed by it.
set_flags(dirty, 0x0001)
target = {'kind': 'image', 'path': str(dirty)}
requests = ''.join(json.dumps(x) + '\n' for x in (
    {'action': 'check', 'target': target, 'arguments': ['safe'], 'progress': True},
    {'action': 'health', 'target': target, 'arguments': []},
    {'action': 'ls', 'target': target, 'arguments': ['/']}))
r = subprocess.run([str(worker), 'serve'], input=requests, capture_output=True, text=True, timeout=600)
lines = [json.loads(x) for x in r.stdout.splitlines() if x.strip()]
progress = [x for x in lines if 'progress' in x and 'ok' not in x and 'error' not in x]
final = [x for x in lines if x not in progress]
assert len(final) == 3, final
assert final[0]['result'] == 'clean' and not final[0]['dirtyAfter'], final[0]
assert final[1]['flags'] & 1 == 0 and final[1]['engineState'] == 2, final[1]
assert {'keep.bin', 'after.bin'} <= {e['name'] for e in final[2]['entries']}, final[2]
assert progress and all(0 <= x['progress'] <= 100 and x.get('item', 0) >= 0 for x in progress), progress
assert max(x.get('item', 0) for x in progress) >= 2, 'expected several checking stages'
checks.append({'serve_mode': True, 'progress_lines': len(progress), 'stages': max(x.get('item', 0) for x in progress) + 1, 'responses': len(final)})

# 8. The engine marks the volume dirty itself when it meets an inconsistency while writing
#    (here: deleting a file whose MFT record is already marked free in $MFT:$BITMAP).
#    The response must say so, and the check must then find and repair the problem.
def mft_bitmap_position(image, number):
    mft, size = geometry(image)
    with image.open('rb') as f:
        boot = f.read(512); f.seek(mft); d = bytearray(f.read(size))
    cluster = boot[13] * struct.unpack_from('<H', boot, 11)[0]
    usa, count = struct.unpack_from('<HH', d, 4)
    for k in range(1, count): d[k * 512 - 2:k * 512] = d[usa + 2 * k:usa + 2 * k + 2]
    at = struct.unpack_from('<H', d, 20)[0]
    while struct.unpack_from('<I', d, at)[0] != 0xffffffff:
        kind, length = struct.unpack_from('<II', d, at)
        if kind == 0xb0:
            byte, bit = divmod(number, 8)
            if d[at + 8] == 0:
                return mft + at + struct.unpack_from('<H', d, at + 20)[0] + byte, bit, True
            pos = at + struct.unpack_from('<H', d, at + 32)[0]; header = d[pos]; ls, os_ = header & 15, header >> 4
            lcn = int.from_bytes(d[pos + 1 + ls:pos + 1 + ls + os_], 'little', signed=True)
            return lcn * cluster + byte, bit, False
        at += length
    raise AssertionError('$MFT has no $BITMAP')

marked = make('marked', [('/keep.bin', 5000), ('/victim.bin', 5000)])
offset, size = record_of(marked, 'victim.bin')
mft, _ = geometry(marked)
number = (offset - mft) // size
position, bit, resident = mft_bitmap_position(marked, number)
with marked.open('r+b') as f:
    f.seek(position); value = f.read(1)[0]; assert value & (1 << bit), 'record not marked in use'
    f.seek(position); f.write(bytes([value & ~(1 << bit)]))
    if resident:  # keep $MFTMirr in step for the first records' copies
        pass
r = subprocess.run([str(worker), 'request'], input=json.dumps({'action': 'batch', 'target': {'kind': 'image', 'path': str(marked)}, 'arguments': [], 'operations': [{'op': 'remove', 'args': ['/victim.bin']}]}), capture_output=True, text=True, timeout=600)
response = json.loads(r.stdout)
checks.append({'image': marked.name, 'action': 'batch remove on inconsistent MFT bitmap', 'response': response})
assert response.get('volumeMarkedDirty') is True, ('engine did not report the dirty mark', response)
assert call(marked, 'health')['flags'] & 1, 'volume should be dirty on disk'
call(marked, 'put', fixture, '/refused.bin', ok=False)
r = check(marked, 'verify')
assert r['dirtyAfter'] and not r['writable'], r
r = check(marked, 'repair' if r['result'] == 'errors' else 'safe')
assert r['writable'], r
assert check(marked, 'verify')['result'] == 'clean'
call(marked, 'get', run / 'marked-keep', '/keep.bin')
assert (run / 'marked-keep').read_bytes() == (run / 'marked-keep.bin').read_bytes()

report = {'passed': True, 'checks': len(checks), 'operations': checks}
(REPORTS_PATH / 'check-tests.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print('PASS:', len(checks), 'checks; verify read-only, safe clears only clean dirty volumes, repair fixes damage, hibernation refused, stdin untouched')
