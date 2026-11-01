#!/usr/bin/env python3
"""Write the installer window layout (.DS_Store) into a mounted, writable DMG volume.

Finder reads the window size, icon view options, background picture and icon positions from
this file, so no Finder automation is needed (works on CI runners and without permissions).
The background picture is referenced by a classic alias record built from the mounted
volume's real identifiers, as Finder itself would store it.

Usage: make_dsstore.py <mount point> <volume name> <app name>
"""
import os, plistlib, struct, sys, time
from pathlib import Path

WINDOW = (200, 120, 640, 428)            # x, y, width, height (content 640x400 plus title bar)
ICON_SIZE, TEXT_SIZE = 128, 13
POSITIONS = {'app': (160, 180), 'Applications': (480, 180)}
BACKGROUND = '.background/background.tiff'
HFS_EPOCH = 2082844800                   # seconds from 1904-01-01 to 1970-01-01


def pascal(text, size):
    data = text.encode('utf-8')[:size - 1]
    return bytes([len(data)]) + data + b'\0' * (size - 1 - len(data))


def alias(mount, volume_name, relative):
    """Classic (version 2) alias record for a file on the mounted HFS+ volume, laid out the way
    Finder writes it: local-time dates in the header, UTC 16.16 dates in tags 16 and 17, and a
    Carbon path with a NUL before the file name."""
    target = Path(mount) / relative
    folder = target.parent
    volume_stat, file_stat, folder_stat = os.stat(mount), os.stat(target), os.stat(folder)

    def local(seconds):                  # HFS+ keeps these two dates in local time
        return (int(seconds) + time.localtime(seconds).tm_gmtoff + HFS_EPOCH) & 0xffffffff

    def precise(seconds):                # UTC, 16.16 fixed point since 1904
        return struct.pack('>Q', int((seconds + HFS_EPOCH) * 65536))

    record = struct.pack('>h28pI2shI64pII4s4shhI2s10s',
                         0,                                   # kind: file
                         volume_name.encode('utf-8')[:27],
                         local(volume_stat.st_birthtime),
                         b'H+',                               # file system
                         5,                                   # disk type: ejectable
                         folder_stat.st_ino,                  # parent folder CNID
                         target.name.encode('utf-8')[:63],
                         file_stat.st_ino,                    # file CNID
                         local(file_stat.st_birthtime),
                         b'\0\0\0\0', b'\0\0\0\0',            # creator, type
                         -1, -1,                              # levels from / to
                         0, b'\0\0', b'\0' * 10)

    def tag(number, data):
        out = struct.pack('>hh', number, len(data)) + data
        return out + (b'\0' if len(data) % 2 else b'')

    parts = Path(relative).parts
    extras = tag(0, folder.name.encode('utf-8'))                                  # parent folder name
    extras += tag(16, precise(volume_stat.st_birthtime))                           # volume date (UTC)
    extras += tag(17, precise(file_stat.st_birthtime))                             # file date (UTC)
    extras += tag(1, struct.pack('>I', folder_stat.st_ino))                        # CNID path
    extras += tag(2, (volume_name + ':' + ':\0'.join(parts)).encode('utf-8'))      # Carbon path
    name16, volume16 = target.name.encode('utf-16-be'), volume_name.encode('utf-16-be')
    extras += struct.pack('>hhh', 14, len(name16) + 2, len(name16) // 2) + name16  # Unicode file name
    extras += struct.pack('>hhh', 15, len(volume16) + 2, len(volume16) // 2) + volume16
    extras += tag(18, ('/' + '/'.join(parts)).encode('utf-8'))                     # POSIX path in volume
    extras += tag(19, ('/Volumes/' + volume_name).encode('utf-8'))                 # volume mount point
    extras += struct.pack('>hh', -1, 0)
    body = record + extras
    return struct.pack('>4shh', b'\0\0\0\0', 8 + len(body), 2) + body


def entry(name, code, kind, value):
    name16 = name.encode('utf-16-be')
    head = struct.pack('>I', len(name16) // 2) + name16 + code + kind
    if kind == b'blob':
        return head + struct.pack('>I', len(value)) + value
    if kind == b'long':
        return head + struct.pack('>I', value)
    if kind == b'type':
        return head + value
    raise ValueError(kind)


def ds_store(records):
    """A one-node DSDB B-tree inside a buddy-allocated file, the layout Finder writes."""
    records = sorted(records, key=lambda r: (r[0].lower(), r[1]))
    leaf = struct.pack('>II', 0, len(records)) + b''.join(entry(*r) for r in records)
    if len(leaf) > 4096:
        raise ValueError('layout does not fit one B-tree node')
    # Block addresses are offsets from byte 4 of the file, OR-ed with log2 of the block size.
    dsdb_address, root_address, leaf_address = 32, 2048, 4096
    dsdb = struct.pack('>IIIII', 2, 0, len(records), 1, 4096)
    offsets = [root_address | 11, dsdb_address | 5, leaf_address | 12]
    root = struct.pack('>II', len(offsets), 0) + b''.join(struct.pack('>I', o) for o in offsets)
    root += b'\0' * (4 * (256 - len(offsets)))
    root += struct.pack('>I', 1) + bytes([4]) + b'DSDB' + struct.pack('>I', 1)
    free = {n: [] for n in range(32)}
    for n in range(6, 11):
        free[n].append(1 << n)               # 64 .. 1024 are unused
    for n in range(13, 31):
        free[n].append(1 << n)               # everything after the leaf block
    for n in range(32):
        root += struct.pack('>I', len(free[n])) + b''.join(struct.pack('>I', o) for o in free[n])
    if len(root) > 2048:
        raise ValueError('allocator block overflow')
    data = bytearray(4 + leaf_address + 4096)
    data[0:36] = struct.pack('>I4sIII16s', 1, b'Bud1', root_address, len(root), root_address, b'\0' * 16)
    data[4 + dsdb_address:4 + dsdb_address + len(dsdb)] = dsdb
    data[4 + root_address:4 + root_address + len(root)] = root
    data[4 + leaf_address:4 + leaf_address + len(leaf)] = leaf
    return bytes(data)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    mount, volume_name, app = sys.argv[1], sys.argv[2], sys.argv[3]
    if not (Path(mount) / BACKGROUND).is_file():
        raise SystemExit('Background picture missing: ' + BACKGROUND)
    x, y, width, height = WINDOW
    window = {
        'ContainerShowSidebar': False, 'PreviewPaneVisibility': False, 'ShowPathbar': False,
        'ShowSidebar': False, 'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'SidebarWidth': 0, 'WindowBounds': '{{%d, %d}, {%d, %d}}' % (x, y, width, height),
    }
    view = {
        'viewOptionsVersion': 1, 'backgroundType': 2, 'backgroundImageAlias': alias(mount, volume_name, BACKGROUND),
        'backgroundColorRed': 0.08, 'backgroundColorGreen': 0.10, 'backgroundColorBlue': 0.13,
        'arrangeBy': 'none', 'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
        'iconSize': float(ICON_SIZE), 'textSize': float(TEXT_SIZE), 'labelOnBottom': True,
        'showIconPreview': False, 'showItemInfo': False, 'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
    }

    def location(point):
        return struct.pack('>IIII', point[0], point[1], 0xffffffff, 0xffff0000)

    records = [
        ('.', b'bwsp', b'blob', plistlib.dumps(window, fmt=plistlib.FMT_BINARY)),
        ('.', b'icvp', b'blob', plistlib.dumps(view, fmt=plistlib.FMT_BINARY)),
        ('.', b'vSrn', b'long', 1),
        ('.', b'vstl', b'type', b'icnv'),
        (app, b'Iloc', b'blob', location(POSITIONS['app'])),
        ('Applications', b'Iloc', b'blob', location(POSITIONS['Applications'])),
    ]
    (Path(mount) / '.DS_Store').write_bytes(ds_store(records))


if __name__ == '__main__':
    main()
