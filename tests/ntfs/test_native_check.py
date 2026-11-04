#!/usr/bin/env python3
"""Native check/repair on damaged disposable images, compared with a reference checker.

Volumes are formatted and filled by the native code, then damaged directly. The native check
must report the problem without changing the image (verify), refuse to clear the mark when
problems exist (safe), and repair it so that the reference checker (OPENNTFS_REFERENCE_CHECKER,
optional) reports a clean volume and the files are intact.

Usage: test_native_check.py NATIVE_CLI OUTPUT_DIR
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
reference = os.environ.get('OPENNTFS_REFERENCE_CHECKER')
work = output / 'native-check'
work.mkdir(parents=True, exist_ok=True)
for old in work.iterdir():
    if old.is_file():
        old.unlink()
rng = random.Random(77)
results = []


def run(*args, ok=True, code=None):
    result = subprocess.run([str(native), *map(str, args)], capture_output=True, timeout=900)
    if code is not None:
        assert result.returncode == code, (args, result.returncode, result.stderr.decode())
    else:
        assert (result.returncode == 0) == ok, (args, result.stderr.decode())
    return result.stdout


def check(image, mode):
    return json.loads(run('check', image, mode))


def reference_check(image):
    if not reference:
        return None
    body = {'action': 'check', 'target': {'kind': 'image', 'path': str(image)}, 'arguments': ['verify']}
    result = subprocess.run([reference, 'request'], input=json.dumps(body), capture_output=True, text=True, timeout=900)
    return json.loads(result.stdout)['result']


def digest(image):
    with image.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


class Volume:
    def __init__(self, name):
        self.path = work / f'{name}.ntfs'
        self.path.touch()
        os.truncate(self.path, 96 * 1024 * 1024)
        run('format', self.path, name.upper()[:10])
        self.files = {}
        plan = [{'op': 'mkdir', 'path': '/Data'}]
        for i in range(12):
            data = rng.randbytes(rng.choice([100, 5000, 70000, 300000]))
            local = work / f'{name}-{i}'
            local.write_bytes(data)
            plan.append({'op': 'put', 'local': str(local), 'path': f'/Data/file{i}.bin'})
            self.files[f'/Data/file{i}.bin'] = data
        self.write(plan)

    def write(self, plan, **kw):
        path = work / 'plan.json'
        path.write_text(json.dumps(plan))
        return run('write', self.path, path, **kw)

    def geometry(self):
        with self.path.open('rb') as f:
            boot = f.read(512)
        cluster = boot[13] * struct.unpack_from('<H', boot, 11)[0]
        return cluster, struct.unpack_from('<Q', boot, 48)[0] * cluster, struct.unpack_from('<Q', boot, 56)[0] * cluster

    def record(self, number):
        cluster, mft, _ = self.geometry()
        with self.path.open('rb') as f:
            f.seek(mft + number * 1024)
            raw = bytearray(f.read(1024))
        usa, count = struct.unpack_from('<HH', raw, 4)
        for i in range(1, count):
            raw[i * 512 - 2:i * 512] = raw[usa + 2 * i:usa + 2 * i + 2]
        return raw

    def put_record(self, number, raw):
        # Re-apply the fixups and write the record (and its mirror copy for records 0-3).
        raw = bytearray(raw)
        usa, count = struct.unpack_from('<HH', raw, 4)
        seq = struct.unpack_from('<H', raw, usa)[0]
        for i in range(1, count):
            raw[usa + 2 * i:usa + 2 * i + 2] = raw[i * 512 - 2:i * 512]
            struct.pack_into('<H', raw, i * 512 - 2, seq)
        cluster, mft, mirror = self.geometry()
        with self.path.open('r+b') as f:
            f.seek(mft + number * 1024)
            f.write(raw)
            if number < 4:
                f.seek(mirror + number * 1024)
                f.write(raw)

    def attribute(self, raw, kind, name=''):
        offset = struct.unpack_from('<H', raw, 20)[0]
        while struct.unpack_from('<I', raw, offset)[0] != 0xffffffff:
            length = struct.unpack_from('<I', raw, offset + 4)[0]
            nlen, noff = raw[offset + 9], struct.unpack_from('<H', raw, offset + 10)[0]
            if struct.unpack_from('<I', raw, offset)[0] == kind and raw[offset + noff:offset + noff + 2 * nlen].decode('utf-16-le') == name:
                return offset
            offset += length
        raise KeyError(kind)

    def runs(self, raw, offset):
        pos = offset + struct.unpack_from('<H', raw, offset + 32)[0]
        lcn, out = 0, []
        while raw[pos]:
            h = raw[pos]
            ln = int.from_bytes(raw[pos + 1:pos + 1 + (h & 15)], 'little')
            ob = h >> 4
            lcn += int.from_bytes(raw[pos + 1 + (h & 15):pos + 1 + (h & 15) + ob], 'little', signed=True)
            out.append((lcn, ln))
            pos += 1 + (h & 15) + ob
        return out

    def bitmap_bit(self, clusterNumber, value):
        cluster, _, _ = self.geometry()
        raw = self.record(6)
        lcn, _ = self.runs(raw, self.attribute(raw, 0x80))[0]
        with self.path.open('r+b') as f:
            f.seek(lcn * cluster + clusterNumber // 8)
            byte = f.read(1)[0]
            byte = byte | (1 << clusterNumber % 8) if value else byte & ~(1 << clusterNumber % 8)
            f.seek(lcn * cluster + clusterNumber // 8)
            f.write(bytes([byte]))

    def set_dirty(self):
        raw = self.record(3)
        at = self.attribute(raw, 0x70)
        value = at + struct.unpack_from('<H', raw, at + 20)[0]
        struct.pack_into('<H', raw, value + 10, struct.unpack_from('<H', raw, value + 10)[0] | 1)
        self.put_record(3, raw)

    def number_of(self, path):
        return json.loads(run('stat', self.path, path))['number']

    def intact(self):
        for path, data in self.files.items():
            assert run('read', self.path, path) == data, path


def scenario(name, damage, expect, after_repair_files=None):
    volume = Volume(name)
    damage(volume)
    before = digest(volume.path)
    verify = check(volume.path, 'verify')
    assert digest(volume.path) == before, (name, 'verify changed the image')
    assert verify['result'] == expect, (name, verify)
    referenced = reference_check(volume.path)
    # Errors and clean volumes must agree with the reference; minor findings may be stricter here.
    if referenced is not None and expect != 'minor':
        assert (referenced == 'clean') == (expect == 'clean'), (name, 'reference', referenced, verify)
    safe = check(volume.path, 'safe')
    if expect != 'clean':
        assert digest(volume.path) == before and safe['dirtyAfter'] == verify['dirtyBefore'], (name, safe)
    repaired = check(volume.path, 'repair')
    assert repaired['result'] in ('clean', 'repaired'), (name, repaired)
    assert not repaired['dirtyAfter'], (name, repaired)
    again = check(volume.path, 'verify')
    assert again['result'] == 'clean' and not again['dirtyBefore'], (name, again)
    referenced_after = reference_check(volume.path)
    if referenced_after is not None:
        assert referenced_after == 'clean', (name, 'reference after repair', referenced_after)
    if after_repair_files:
        after_repair_files(volume)
    volume.intact()
    # The repaired volume accepts writes.
    volume.write([{'op': 'mkdir', 'path': '/After repair'}])
    assert check(volume.path, 'verify')['result'] == 'clean'
    results.append({'scenario': name, 'verify': verify['result'], 'reference_before': referenced,
                    'repaired': repaired['repaired'], 'reference_after': referenced_after})
    print('ok', name, verify['result'], '->', repaired['result'])


def clean(volume):
    pass


def dirty_only(volume):
    volume.set_dirty()


def lost_clusters(volume):
    # Free clusters marked as used, as on a volume where a failed write leaked its space.
    cluster, _, _ = volume.geometry()
    total = 96 * 1024 * 1024 // cluster
    for c in range(total // 3, total // 3 + 500):
        volume.bitmap_bit(c, True)
    volume.set_dirty()


def used_marked_free(volume):
    raw = volume.record(volume.number_of('/Data/file3.bin'))
    try:
        offset = volume.attribute(raw, 0x80)
    except KeyError:
        return
    if raw[offset + 8] == 0:
        raw = volume.record(volume.number_of('/Data/file2.bin'))
        offset = volume.attribute(raw, 0x80)
    for lcn, length in volume.runs(raw, offset):
        for c in range(lcn, lcn + length):
            volume.bitmap_bit(c, False)


def record_marked_free(volume):
    number = volume.number_of('/Data/file5.bin')
    cluster, _, _ = volume.geometry()
    raw = volume.record(0)
    lcn, _ = volume.runs(raw, volume.attribute(raw, 0xb0))[0]
    with volume.path.open('r+b') as f:
        f.seek(lcn * cluster + number // 8)
        byte = f.read(1)[0] & ~(1 << number % 8)
        f.seek(lcn * cluster + number // 8)
        f.write(bytes([byte]))


def entry_to_free_record(volume):
    number = volume.number_of('/Data/file7.bin')
    raw = volume.record(number)
    struct.pack_into('<H', raw, 22, struct.unpack_from('<H', raw, 22)[0] & ~1)
    volume.put_record(number, raw)
    del volume.files['/Data/file7.bin']


def wrong_links(volume):
    number = volume.number_of('/Data/file1.bin')
    raw = volume.record(number)
    struct.pack_into('<H', raw, 18, 3)
    volume.put_record(number, raw)


def orphan(volume):
    # A session that ends before its commit: the record exists, the folder entry does not.
    local = work / 'orphan-src'
    local.write_bytes(b'orphaned file contents' * 100)
    volume.write([{'op': 'put', 'local': str(local), 'path': '/Data/orphan.bin'}, {'op': 'abort'}], code=3)


def orphan_files(volume):
    names = {e['name'] for e in json.loads(run('list', volume.path, '/Data'))}
    assert 'orphan.bin' in names, names


for name, damage, expect, extra in [
        ('clean', clean, 'clean', None),
        ('dirty-only', dirty_only, 'clean', None),
        ('lost-clusters', lost_clusters, 'minor', None),
        ('used-marked-free', used_marked_free, 'errors', None),
        ('record-marked-free', record_marked_free, 'errors', None),
        ('entry-to-free-record', entry_to_free_record, 'errors', None),
        ('wrong-links', wrong_links, 'minor', None),
        ('orphan', orphan, 'errors', orphan_files)]:
    scenario(name, damage, expect, extra)

report = {'passed': True, 'scenarios': results, 'reference_checker': bool(reference)}
(output / 'native-check-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'PASS: {len(results)} check and repair scenarios', '(reference checker agrees)' if reference else '')
