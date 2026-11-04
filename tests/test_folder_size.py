#!/usr/bin/env python3
"""Folder totals must equal the bytes of the files inside, nested folders included."""
from pathlib import Path
import sys as _sys; _sys.path.insert(0, str(Path(__file__).resolve().parent)); from paths import APP_PATH, IMAGES_PATH
import json, os, subprocess, tempfile
WORKER = APP_PATH / 'Contents/MacOS/NTFSWorker'
run = Path(tempfile.mkdtemp(prefix='folders-', dir=IMAGES_PATH))
image = run / 'test.ntfs'; image.touch(); os.truncate(image, 64 * 1024 * 1024)
target = {'kind': 'image', 'path': str(image), 'formatConfirmation': str(image)}

def call(action, *arguments, ok=True):
    done = subprocess.run([str(WORKER), 'request'], input=json.dumps({'action': action, 'target': target, 'arguments': list(arguments)}), capture_output=True, text=True)
    reply = json.loads(done.stdout)
    assert ('error' not in reply) == ok, (action, arguments, reply)
    return reply

call('format', 'FOLDERS')
sizes = {'/a/one.bin': 1234, '/a/b/two.bin': 5000000, '/a/b/c/три.bin': 700, '/a/empty.bin': 0, '/top.bin': 321}
for folder in ('/a', '/a/b', '/a/b/c', '/a/nothing', '/other'):
    call('mkdir', folder)
for index, (remote, size) in enumerate(sizes.items()):
    local = run / f'{index}.bin'; local.write_bytes(os.urandom(size))
    call('put', str(local), remote)
inner = 5000000 + 700
reply = call('foldersize', '/a')
assert reply['bytes'] == 1234 + inner, reply
assert reply['folders'] == {'/a': 1234 + inner, '/a/b': inner, '/a/b/c': 700, '/a/nothing': 0}, reply
assert call('foldersize', '/a/nothing')['bytes'] == 0
everything = call('foldersize', '/')
assert everything['bytes'] == sum(sizes.values()), everything
assert everything['folders']['/other'] == 0 and everything['folders']['/a/b/c'] == 700, everything
call('remove', '/a/b/c/три.bin')
assert call('foldersize', '/a')['bytes'] == 1234 + 5000000
assert 'error' in call('foldersize', '/missing', ok=False)
print('PASS: folder totals match the files inside')
