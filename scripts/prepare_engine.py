#!/usr/bin/env python3
"""Adapt the supplied ARM64 executable's loader container without changing its __text."""
from pathlib import Path
import hashlib,json,struct,sys
source,destination,report=map(Path,sys.argv[1:4])
expected='d9a9656b630aae351a3f0ebbfc6f4e3b523d2b9d80f3a982bcab6dd724de41e2'
original=source.read_bytes()
if hashlib.sha256(original).hexdigest()!=expected:raise SystemExit('Unexpected NTFS_util build. Function addresses are valid only for the verified supplied build.')
data=bytearray(original);magic,cpu,sub,kind,count,size,flags,reserved=struct.unpack_from('<8I',data)
assert magic==0xfeedfacf and kind==2 and cpu==0x100000c
commands=[];position=32;changes=[];text_sections=[]
for _ in range(count):
    command,length=struct.unpack_from('<II',data,position);part=bytearray(data[position:position+length]);position+=length
    if command in (0x80000028,0xe,0x1d):changes.append('Remove loader command '+hex(command));continue
    if command==0x19:
        if part[8:24].split(b'\0')[0]==b'__PAGEZERO':struct.pack_into('<QQ',part,24,0x100000000,0);changes.append('Keep PAGEZERO ordinal with zero size')
        sections=struct.unpack_from('<I',part,64)[0]
        for i in range(sections):
            start=72+i*80
            if part[start:start+16].split(b'\0')[0]==b'__text':
                length=struct.unpack_from('<Q',part,start+40)[0];offset=struct.unpack_from('<I',part,start+48)[0];text_sections.append((offset,length))
    commands.append(part)
new=b''.join(commands);assert len(new)<=size
data[32:32+size]=new+b'\0'*(size-len(new))
struct.pack_into('<8I',data,0,magic,cpu,sub,8,len(commands),len(new),flags&~0x200000,reserved)
assert text_sections and all(data[o:o+n]==original[o:o+n] for o,n in text_sections)
destination.write_bytes(data);destination.chmod(0o755)
report.write_text(json.dumps({'original_sha256':expected,'changes':changes,'all_text_sections_unchanged':True,'text_sections':text_sections,'note':'Loader metadata only. All __text sections are verified byte-for-byte.'},indent=2))
