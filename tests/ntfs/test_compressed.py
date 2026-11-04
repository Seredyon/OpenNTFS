#!/usr/bin/env python3
"""LZNT1-compressed files.

A file written by the native writer is rewritten in place as a real NTFS compressed stream: its
$DATA attribute gets the compressed form (72-byte header, unit 4, sparse runs), its clusters hold
LZNT1 chunks built here per [MS-XCA] 2.5, and the clusters no longer used go back to $Bitmap.
The native reader must return the original bytes, also for reads inside a unit. When
OPENNTFS_REFERENCE_WORKER is set a separate NTFS implementation must read the same bytes, which
shows that the streams are valid LZNT1 and not just a format this reader agrees with itself on.
"""
import argparse, json, os, random, struct, subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
native = str(args.binary.resolve())
work = args.output.resolve() / 'compressed'
work.mkdir(parents=True, exist_ok=True)
reference = os.environ.get('OPENNTFS_REFERENCE_WORKER')
checker = os.environ.get('OPENNTFS_REFERENCE_CHECKER', reference)
CLUSTER, UNIT = 4096, 65536


def compress_chunk(chunk):
    """One LZNT1 chunk body. Greedy longest match; the tuple split moves with the position."""
    body, position = bytearray(), 0
    while position < len(chunk):
        flag_at = len(body)
        body.append(0)
        for bit in range(8):
            if position >= len(chunk):
                break
            length_bits, span = 12, max(position - 1, 0)
            while span >= 0x10:
                span >>= 1
                length_bits -= 1
            longest = (1 << length_bits) + 2
            best, distance = 0, 0
            for back in range(1, min(position, 1 << (16 - length_bits)) + 1):
                n = 0
                while n < longest and position + n < len(chunk) and chunk[position + n - back] == chunk[position + n]:
                    n += 1
                if n > best:
                    best, distance = n, back
            if best >= 3:
                body += struct.pack('<H', (distance - 1) << length_bits | (best - 3))
                body[flag_at] |= 1 << bit
                position += best
            else:
                body.append(chunk[position])
                position += 1
    return bytes(body)


def compress_unit(plain, short_chunks=False):
    """LZNT1 stream for one compression unit. short_chunks drops trailing zeros inside each chunk."""
    stream = bytearray()
    for start in range(0, len(plain), 4096):
        chunk = plain[start:start + 4096]
        if short_chunks and len(chunk) == 4096 and start + 4096 < len(plain):
            chunk = chunk.rstrip(b'\0') or b'\0'
        body = compress_chunk(chunk)
        if len(body) >= 4096 and len(chunk) == 4096:
            stream += struct.pack('<H', 0x3fff) + chunk
        else:
            stream += struct.pack('<H', 0xb000 | (len(body) - 1)) + body
    return bytes(stream)


def encode_runs(runs):
    out, previous = bytearray(), 0
    for lcn, count in runs:
        length = count.to_bytes(max(1, (count.bit_length() + 8) // 8), 'little')
        if lcn is None:
            delta = b''
        else:
            change = lcn - previous
            width = next(n for n in range(1, 9) if -(1 << (n * 8 - 1)) <= change < (1 << (n * 8 - 1)))
            delta = change.to_bytes(width, 'little', signed=True)
            previous = lcn
        out += bytes([len(delta) << 4 | len(length)]) + length + delta
    return bytes(out + b'\0')


def decode_runs(attribute):
    p = struct.unpack_from('<H', attribute, 32)[0]
    runs, lcn = [], 0
    while attribute[p]:
        lengths, offsets = attribute[p] & 15, attribute[p] >> 4
        count = int.from_bytes(attribute[p + 1:p + 1 + lengths], 'little')
        lcn += int.from_bytes(attribute[p + 1 + lengths:p + 1 + lengths + offsets], 'little', signed=True)
        runs.append((lcn, count))
        p += 1 + lengths + offsets
    return runs


class Volume:
    def __init__(self, name):
        self.path = work / f'{name}.ntfs'
        self.path.write_bytes(b'')
        os.truncate(self.path, 64 << 20)
        subprocess.run([native, 'format', str(self.path), 'Compressed'], check=True, capture_output=True)
        self.free = self.tool('free')

    def tool(self, *command):
        result = subprocess.run([native, command[0], str(self.path), *map(str, command[1:])], capture_output=True, timeout=120)
        assert result.returncode == 0, (command, result.stderr.decode())
        return result.stdout

    def put(self, remote, plain):
        local = work / 'plain.bin'
        local.write_bytes(plain)
        (work / 'ops.json').write_text(json.dumps([{'op': 'put', 'local': str(local), 'path': remote}]))
        self.tool('write', work / 'ops.json')
        local.unlink()

    def remove(self, remote):
        (work / 'ops.json').write_text(json.dumps([{'op': 'remove', 'path': remote}]))
        self.tool('write', work / 'ops.json')

    def compress(self, remote, plain, short_chunks=False):
        number = json.loads(self.tool('stat', remote))['number']
        data = bytearray(self.path.read_bytes())
        boot_mft = struct.unpack_from('<Q', data, 48)[0] * CLUSTER

        def load(n):
            at = boot_mft + n * 1024
            record = bytearray(data[at:at + 1024])
            assert record[:4] == b'FILE'
            usa, count = struct.unpack_from('<HH', record, 4)
            for i in range(1, count):
                record[i * 512 - 2:i * 512] = record[usa + i * 2:usa + i * 2 + 2]
            return record

        def store(n, record):
            usa, count = struct.unpack_from('<HH', record, 4)
            for i in range(1, count):
                record[usa + i * 2:usa + i * 2 + 2] = record[i * 512 - 2:i * 512]
                record[i * 512 - 2:i * 512] = record[usa:usa + 2]
            data[boot_mft + n * 1024:boot_mft + (n + 1) * 1024] = record

        def attribute(record, kind):
            at = struct.unpack_from('<H', record, 20)[0]
            while struct.unpack_from('<I', record, at)[0] != 0xffffffff:
                if struct.unpack_from('<I', record, at)[0] == kind:
                    return at, struct.unpack_from('<I', record, at + 4)[0]
                at += struct.unpack_from('<I', record, at + 4)[0]
            raise AssertionError(f'no attribute {kind:x}')

        record = load(number)
        at, length = attribute(record, 0x80)
        old = record[at:at + length]
        clusters = [lcn + i for lcn, count in decode_runs(old) for i in range(count)]
        free = list(clusters)
        runs, stored = [], 0
        size = len(plain)
        for start in range(0, size, UNIT):
            unit = plain[start:start + UNIT]
            if not any(unit):
                runs.append((None, 16))
                continue
            stream = compress_unit(unit, short_chunks)
            need = (len(stream) + CLUSTER - 1) // CLUSTER
            if need >= 16:
                stream, need = unit, 16
            used, free = free[:need], free[need:]
            assert used == list(range(used[0], used[0] + need))
            data[used[0] * CLUSTER:used[0] * CLUSTER + len(stream)] = stream
            tail = used[0] * CLUSTER + len(stream)
            data[tail:(used[0] + need) * CLUSTER] = bytes((used[0] + need) * CLUSTER - tail)
            runs.append((used[0], need))
            if need < 16:
                runs.append((None, 16 - need))
            stored += need
        encoded = encode_runs(runs)
        total = sum(count for _, count in runs)
        new = bytearray(72)
        new += encoded + bytes(-len(encoded) & 7)
        struct.pack_into('<IIBBHHH', new, 0, 0x80, len(new), 1, 0, 72, 1, struct.unpack_from('<H', old, 14)[0])
        struct.pack_into('<QQHH', new, 16, 0, total - 1, 72, 4)
        struct.pack_into('<QQQQ', new, 40, total * CLUSTER, size, size, stored * CLUSTER)
        record[at:at + length] = new
        used = struct.unpack_from('<I', record, 24)[0] + len(new) - length
        assert used <= 1024
        struct.pack_into('<I', record, 24, used)
        del record[1024:]
        record += bytes(1024 - len(record))
        si, _ = attribute(record, 0x10)
        record[si + struct.unpack_from('<H', record, si + 20)[0] + 33] |= 0x08
        fn, _ = attribute(record, 0x30)
        record[fn + struct.unpack_from('<H', record, fn + 20)[0] + 57] |= 0x08
        store(number, record)
        bitmap = load(6)
        at, length = attribute(bitmap, 0x80)
        (lcn, count), = decode_runs(bitmap[at:at + length])
        for cluster in free:
            data[lcn * CLUSTER + (cluster >> 3)] &= ~(1 << (cluster & 7)) & 0xff
        self.path.write_bytes(data)


rng = random.Random(77)
text = b''.join(b'Line %05d of a compressible NTFS stream: the quick brown fox\r\n' % i for i in range(3000))
noise = rng.randbytes(UNIT)
cases = {
    'mixed': text[:UNIT] + noise + bytes(UNIT) + text[UNIT:UNIT + 12288] + rng.randbytes(4096) + text[UNIT + 12288:UNIT + 26000],
    'runs of a byte': b'A' * 200000 + b'B' * 100,
    'one byte unit': text[:UNIT] + b'!',
    'exact units': text[:2 * UNIT],
}
gapped = bytearray()
for i in range(16):
    gapped += text[i * 1000:i * 1000 + 700] + bytes(4096 - 700)
cases['chunks ending in zeros'] = bytes(gapped) + text[:5000]

report = []
for index, (name, plain) in enumerate(cases.items()):
    short = name == 'chunks ending in zeros'
    volume = Volume(f'case{index}')
    remote = f'/case {index}.bin'
    volume.put(remote, plain)
    volume.compress(remote, plain, short_chunks=short)
    info = json.loads(volume.tool('stat', remote))
    assert any(a['compressed'] for a in info['attributes'] if a['type'] == '0x80'), info
    assert volume.tool('read', remote) == plain, f'{name}: native reader differs'
    for start, count in ((0, 10), (4090, 20), (UNIT - 5, 10), (2 * UNIT + 100, 5000), (len(plain) - 3, 100), (len(plain) + 5, 5)):
        assert volume.tool('read', remote, start, count) == plain[start:start + count], (name, start, count)
    outcome = {'case': name, 'bytes': len(plain)}
    check = json.loads(volume.tool('check', 'verify'))
    assert check['result'] == 'clean', (name, check)
    if reference:
        local = work / 'back.bin'
        local.unlink(missing_ok=True)
        body = {'action': 'get', 'target': {'kind': 'image', 'path': str(volume.path)}, 'arguments': [str(local), remote]}
        result = subprocess.run([reference, 'request'], input=json.dumps(body), capture_output=True, text=True, timeout=120)
        reply = json.loads(result.stdout)
        assert 'error' not in reply, (name, reply)
        assert local.read_bytes() == plain, f'{name}: reference reader differs'
        outcome['reference'] = 'identical'
        body = {'action': 'check', 'target': {'kind': 'image', 'path': str(volume.path)}, 'arguments': ['verify']}
        result = subprocess.run([checker, 'request'], input=json.dumps(body), capture_output=True, text=True, timeout=120)
        outcome['reference_check'] = json.loads(result.stdout)['result']
    volume.remove(remote)
    assert volume.tool('free') == volume.free, f'{name}: removal leaked clusters'
    assert json.loads(volume.tool('check', 'verify'))['result'] == 'clean'
    report.append(outcome)
    volume.path.unlink()
print(json.dumps({'status': 'PASS', 'cases': report}, indent=1, ensure_ascii=False))
