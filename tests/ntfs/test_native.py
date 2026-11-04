#!/usr/bin/env python3
"""Read-only integration tests with independent, hand-encoded NTFS fixtures."""
import argparse
import hashlib
import fcntl
import json
import random
import struct
import subprocess
from pathlib import Path


def align(n, size=8):
    return (n + size - 1) // size * size


def put(buffer, offset, fmt, *values):
    struct.pack_into('<' + fmt, buffer, offset, *values)


def resident(kind, value, name='', flags=0):
    encoded = name.encode('utf-16-le')
    start = align(24 + len(encoded))
    result = bytearray(align(start + len(value)))
    put(result, 0, 'IIBBHHH', kind, len(result), 0, len(encoded) // 2, 24 if encoded else 0, flags, 0)
    put(result, 16, 'IH', len(value), start)
    result[24:24 + len(encoded)] = encoded
    result[start:start + len(value)] = value
    return result


def nonresident(kind, mappings, size, name='', valid=None, flags=0):
    encoded = name.encode('utf-16-le')
    runs = bytearray()
    previous = 0
    clusters = 0
    for lcn, count in mappings:
        length = count.to_bytes(max(1, (count.bit_length() + 7) // 8), 'little')
        if lcn is None:
            delta = b''
        else:
            change = lcn - previous
            width = next(n for n in range(1, 9) if -(1 << (n * 8 - 1)) <= change < (1 << (n * 8 - 1)))
            delta = change.to_bytes(width, 'little', signed=True)
            previous = lcn
        runs += bytes([len(delta) << 4 | len(length)]) + length + delta
        clusters += count
    runs += b'\0'
    start = align(64 + len(encoded))
    result = bytearray(align(start + len(runs)))
    put(result, 0, 'IIBBHHH', kind, len(result), 1, len(encoded) // 2, 64 if encoded else 0, flags, 0)
    put(result, 16, 'QQHH', 0, clusters - 1, start, 0)
    put(result, 40, 'QQQ', sum(n for lcn, n in mappings if lcn is not None) * 4096, size, size if valid is None else valid)
    result[64:64 + len(encoded)] = encoded
    result[start:start + len(runs)] = runs
    return result


def protect(record, offset):
    count = len(record) // 512 + 1
    put(record, 4, 'HH', offset, count)
    put(record, offset, 'H', 0xace1)
    for sector in range(1, count):
        tail = sector * 512 - 2
        record[offset + sector * 2:offset + sector * 2 + 2] = record[tail:tail + 2]
        put(record, tail, 'H', 0xace1)
    return record


def mft_record(number, attrs, directory=False):
    record = bytearray(1024)
    record[:4] = b'FILE'
    put(record, 16, 'HHHHIIQ', 1, 1, 56, 3 if directory else 1, 0, 1024, 0)
    put(record, 44, 'I', number)
    cursor = 56
    for attr in attrs:
        record[cursor:cursor + len(attr)] = attr
        cursor += len(attr)
    assert cursor + 8 <= 1024
    put(record, cursor, 'I', 0xffffffff)
    put(record, 24, 'I', cursor + 8)
    return protect(record, 48)


def index_entry(number, name, parent=5, size=0, directory=False, sequence=1):
    encoded = name.encode('utf-16-le')
    key = bytearray(66 + len(encoded))
    put(key, 0, 'Q', parent | 1 << 48)
    put(key, 40, 'QQI', align(size, 4096), size, 0x10000000 if directory else 0)
    key[64:66] = bytes([len(encoded) // 2, 1])
    key[66:] = encoded
    entry = bytearray(align(16 + len(key)))
    put(entry, 0, 'QHHH', number | sequence << 48, len(entry), len(key), 0)
    entry[16:16 + len(key)] = key
    return entry


def index_end(child=None):
    result = bytearray(16 if child is None else 24)
    put(result, 8, 'HHH', len(result), 0, 2 if child is None else 3)
    if child is not None:
        put(result, 16, 'Q', child)
    return result


def index_root(entries, child=None):
    body = b''.join(entries) + index_end(child)
    result = bytearray(32 + len(body))
    put(result, 0, 'III', 0x30, 1, 4096)
    result[12] = 1
    put(result, 16, 'IIIB', 16, 16 + len(body), 16 + len(body), 1 if child is not None else 0)
    result[32:] = body
    return resident(0x90, result, '$I30')


def fixture(sector=512):
    image = bytearray(8 * 1024 * 1024)
    image[3:11] = b'NTFS    '
    put(image, 11, 'HB', sector, 4096 // sector)
    put(image, 40, 'QQQ', len(image) // sector - 1, 4, 20)
    image[64] = 246
    image[68] = 244
    put(image, 72, 'Q', 0x123456789abcdef0)
    put(image, 510, 'H', 0xaa55)
    def record(number, attrs, directory=False):
        image[4 * 4096 + number * 1024:4 * 4096 + (number + 1) * 1024] = mft_record(number, attrs, directory)
    record(0, [nonresident(0x80, [(4, 16)], 65536)])
    volume_info = bytearray(12)
    volume_info[8:10] = b'\x03\x01'
    record(3, [resident(0x60, 'Native test'.encode('utf-16-le')), resident(0x70, volume_info)])
    upcase = bytearray(131072)
    for i in range(65536):
        upper = chr(i).upper()
        put(upcase, i * 2, 'H', ord(upper) if len(upper) == 1 and ord(upper) <= 65535 else i)
    image[32 * 4096:64 * 4096] = upcase
    record(10, [nonresident(0x80, [(32, 32)], len(upcase))])
    small = 'Hello from independent NTFS code!\n'.encode()
    unicode_data = 'Привет, 世界! 🚀\n'.encode()
    record(16, [resident(0x80, small)])
    record(19, [resident(0x80, unicode_data)])
    record(17, [index_root([index_entry(18, 'fragmented.bin', parent=17, size=16384)])], True)
    record(18, [nonresident(0x80, [(80, 1), (78, 1), (None, 1), (82, 1)], 16384, valid=12295, flags=0x8000)])
    image[80 * 4096:81 * 4096] = b'A' * 4096
    image[78 * 4096:79 * 4096] = b'B' * 4096
    image[82 * 4096:83 * 4096] = b'C' * 4096
    # NTFS keeps index entries sorted by their $UpCase form (UTF-16 code units).
    root_entries = [index_entry(17, 'Folder', directory=True), index_entry(16, 'Hello.txt', size=len(small)),
                    index_entry(19, 'Привет-世界-🚀.txt', size=len(unicode_data))]
    block = bytearray(4096)
    block[:4] = b'INDX'
    body = b''.join(root_entries) + index_end()
    put(block, 16, 'Q', 0)
    put(block, 24, 'IIIB', 40, 40 + len(body), 4096 - 24, 0)
    block[64:64 + len(body)] = body
    image[70 * 4096:71 * 4096] = protect(block, 40)
    record(5, [index_root([], child=0), nonresident(0xa0, [(70, 1)], 4096, '$I30'), resident(0xb0, b'\x01', '$I30')], True)
    expected = {'/Hello.txt': small, '/Привет-世界-🚀.txt': unicode_data,
                '/Folder/fragmented.bin': b'A' * 4096 + b'B' * 4096 + b'\0' * 4096 + b'C' * 7 + b'\0' * (4096 - 7)}
    return image, expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = []
    def run(image, command, *extra, fail=None):
        result = subprocess.run([str(args.binary.resolve()), command, str(image), *map(str, extra)], capture_output=True, timeout=10)
        if fail:
            assert result.returncode == 1 and fail in result.stderr.decode(), (result.returncode, result.stderr)
        else:
            assert result.returncode == 0, result.stderr.decode()
        checks.append({'command': command, 'arguments': list(map(str, extra)), 'expected_error': fail})
        return result.stdout
    for sector in (512, 4096):
        data, expected = fixture(sector)
        image = args.output / f'fixture-{sector}.ntfs'
        image.write_bytes(data)
        before = hashlib.sha256(data).hexdigest()
        info = json.loads(run(image, 'info'))
        assert info['label'] == 'Native test' and info['readOnly']
        entries = json.loads(run(image, 'list'))
        assert {e['name'] for e in entries} == {'Hello.txt', 'Folder', 'Привет-世界-🚀.txt'}
        for path, content in expected.items():
            assert run(image, 'read', path) == content
        assert run(image, 'read', '/hello.TXT') == expected['/Hello.txt']
        assert run(image, 'read', '/пРИВЕТ-世界-🚀.TXT') == expected['/Привет-世界-🚀.txt']
        content = expected['/Folder/fragmented.bin']
        for start, count in [(0, 0), (4090, 30), (8188, 4099), (12290, 100), (16380, 999), (16384, 4), (2**64 - 1, 20)]:
            assert run(image, 'read', '/Folder/fragmented.bin', start, count) == content[start:start + count]
        run(image, 'read', '/missing', fail='File not found')
        run(image, 'list', '/Hello.txt', fail='Not a directory')
        run(image, 'read', '/../Hello.txt', fail='Relative path')
        link = args.output / f'link-{sector}.ntfs'
        if link.is_symlink():
            link.unlink()
        link.symlink_to(image.resolve())
        run(link, 'info', fail='Cannot open image')
        with image.open('rb') as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(image, 'info', fail='in use by a writer')
        assert hashlib.sha256(image.read_bytes()).hexdigest() == before
    base, _ = fixture()
    bad = args.output / 'malformed.ntfs'
    def corrupt(label, offset, value, command='info', extra=(), message=''):
        data = bytearray(base)
        data[offset:offset + len(value)] = value
        bad.write_bytes(data)
        run(bad, command, *extra, fail=message)
    corrupt('signature', 3, b'BROKEN!!', message='Not an NTFS')
    corrupt('zero sector', 11, b'\0\0', message='sector or cluster')
    corrupt('volume overflow', 40, b'\xff' * 8, message='overflow')
    corrupt('bad fixup', 4 * 4096 + 510, b'\0\0', message='torn-write')
    corrupt('overlapping usa', 4 * 4096 + 4, struct.pack('<H', 508), message='update sequence')
    corrupt('zero attribute', 4 * 4096 + 60, b'\0' * 4, message='attribute length')
    corrupt('huge mft run', 4 * 4096 + 56 + 64 + 1, b'\xff', message='runlist')
    corrupt('index torn', 70 * 4096 + 510, b'\0\0', command='list', message='torn-write')
    corrupt('index bounds', 70 * 4096 + 28, b'\xff' * 4, command='list', message='index bounds')
    corrupt('stale reference', 70 * 4096 + 64 + 6, b'\x02\0', command='list', extra=('/Folder',), message='Stale NTFS')
    corrupt('attribute list', 4 * 4096 + 16 * 1024 + 56, struct.pack('<I', 0x20), command='read', extra=('/Hello.txt',), message='Invalid attribute list')
    corrupt('compression', 4 * 4096 + 18 * 1024 + 56 + 12, b'\x01\0', command='read', extra=('/Folder/fragmented.bin',), message='compression unit')
    # A cyclic child reference must be rejected before recursive traversal can loop.
    cyclic = bytearray(base)
    used = struct.unpack_from('<I', cyclic, 70 * 4096 + 28)[0]
    terminal = 70 * 4096 + 24 + used - 16
    put(cyclic, terminal + 8, 'HHH', 24, 0, 3)
    put(cyclic, terminal + 16, 'Q', 0)
    put(cyclic, 70 * 4096 + 28, 'I', used + 8)
    bad.write_bytes(cyclic)
    run(bad, 'list', fail='Cycle in directory index')
    # Corruption inputs must result in a value or a reported error, never a process crash.
    rng = random.Random(21103)
    for i in range(48):
        data = bytearray(base)
        start = rng.choice([0, 4 * 4096, 4 * 4096 + 5 * 1024, 70 * 4096])
        for _ in range(4):
            data[start + rng.randrange(128)] = rng.randrange(256)
        bad.write_bytes(data)
        result = subprocess.run([str(args.binary.resolve()), 'list', str(bad)], capture_output=True, timeout=10)
        assert result.returncode in (0, 1), (i, result.returncode, result.stderr)
    report = {'passed': True, 'functional_checks': len(checks), 'corruption_smoke_cases': 48,
              'image_hashes_unchanged': True, 'proprietary_engine_used': False,
              'checks': checks}
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(checks)} functional checks, 48 corruption smoke cases, unchanged images')


if __name__ == '__main__':
    main()
