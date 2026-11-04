#!/usr/bin/env python3
"""Check publishable files without including build output or local Git metadata."""
from pathlib import Path
import os,unicodedata

root=Path(__file__).resolve().parents[1]
errors=[];count=0
ignored={'.git','build','.cache','__pycache__'}
for directory,dirs,files in os.walk(root):
    dirs[:]=[d for d in dirs if d not in ignored]
    for name in files:
        path=Path(directory)/name;relative=path.relative_to(root)
        count+=1
        if name=='.DS_Store' or name.startswith('._') or path.suffix in {'.log','.dmg','.pyc'}:
            errors.append(f'{relative}: generated or system file')
        if path.is_symlink():
            errors.append(f'{relative}: unexpected source symlink');continue
        try:text=path.read_text(encoding='utf-8')
        except UnicodeError:continue
        for number,line in enumerate(text.splitlines(),1):
            if any(ord(c) in range(0x2012,0x2016) or 'ARROW' in unicodedata.name(c,'') for c in line):
                errors.append(f'{relative}:{number}: use ASCII punctuation')
            if ('/'+'Users/') in line or ('/'+'Volumes/UnionSine/') in line:
                errors.append(f'{relative}:{number}: local machine path')
        if path.suffix=='.py':
            try:compile(text,str(relative),'exec')
            except SyntaxError as error:errors.append(f'{relative}: {error}')
if (root/'Engine').exists():errors.append('Engine: binary modules do not belong in this repository')
if errors:raise SystemExit('\n'.join(errors))
print(f'PASS: {count} repository files, Python syntax and text hygiene')
