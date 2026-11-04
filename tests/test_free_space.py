#!/usr/bin/env python3
"""The free space a serving worker keeps must equal a fresh count of $Bitmap after every change."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH
import json, os, subprocess, tempfile
WORKER = APP_PATH / 'Contents/MacOS/NTFSWorker'
run = Path(tempfile.mkdtemp(prefix='space-', dir=IMAGES_PATH))
image = run / 'test.ntfs'; image.touch(); os.truncate(image, 96 * 1024 * 1024)
target = {'kind': 'image', 'path': str(image), 'formatConfirmation': str(image)}
served = subprocess.Popen([str(WORKER), 'serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

def call(action, *arguments, **extra):
    served.stdin.write(json.dumps({'action': action, 'target': target, 'arguments': list(arguments), **extra}) + '\n')
    served.stdin.flush()
    while True:
        reply = json.loads(served.stdout.readline())
        if 'progress' not in reply:
            return reply

def need(action, *arguments, **extra):
    reply = call(action, *arguments, **extra)
    assert 'error' not in reply, (action, reply)
    return reply

def fresh():
    done = subprocess.run([str(WORKER), 'request'], input=json.dumps({'action': 'health', 'target': target, 'arguments': []}), capture_output=True, text=True)
    return json.loads(done.stdout)['freeBytes']

def same(step):
    kept = need('health')['freeBytes']
    assert kept == fresh(), (step, kept, fresh())
    return kept

need('format', 'SPACE')
start = need('recount')['freeBytes']
assert start == fresh()
large = run / 'large.bin'; large.write_bytes(os.urandom(3 << 20))
small = run / 'small.bin'; small.write_bytes(os.urandom(300))
need('put', str(large), '/large.bin')
assert same('put') <= start - (3 << 20)
need('mkdir', '/folder'); same('mkdir')
need('rename', '/large.bin', '/folder/moved.bin'); same('rename')
need('put', str(small), '/folder/small.bin'); same('resident file')
need('batch', operations=[{'op': 'put', 'args': [str(large), f'/folder/{i}.bin']} for i in range(8)]); same('batch')
need('batch', operations=[{'op': 'remove', 'args': [f'/folder/{i}.bin']} for i in range(8)]); same('batch removal')
assert 'error' in call('put', str(run / 'missing.bin'), '/missing.bin')
same('failed write')
for path in ('/folder/moved.bin', '/folder/small.bin'):
    need('remove', path)
need('rmdir', '/folder')
assert same('removal') == start
need('check', 'repair')
assert need('health')['freeBytes'] == fresh() == start
served.stdin.close(); served.wait()
print('PASS: kept free space equals a fresh count')
