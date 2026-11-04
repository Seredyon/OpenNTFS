#!/usr/bin/env python3
"""Fails the build when an interface or worker string has no translation.

Keys are the English texts: L("…"), LK("…") and the plural key of LP(n, "one", "many") in
Sources/App/*.swift, plus every literal runtime_error("…") / check(…, "…") message of the worker.
Each <lang>.lproj/Localizable.strings (except en) must translate all of them with the same
placeholders; plural keys need three "|"-separated forms for Russian.
"""
import re, sys
from pathlib import Path

LIT = r'"((?:[^"\\]|\\.)*)"'

def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]; out.append({'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', "'": "'"}.get(n, '\\' + n)); i += 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def swift_keys(folder):
    keys, plurals = set(), set()
    for f in sorted(Path(folder).glob('*.swift')):
        text = f.read_text()
        for m in re.finditer(r'\bL[K]?\(\s*' + LIT, text): keys.add(unescape(m.group(1)))
        for m in re.finditer(r'\bLP\([^,]+,\s*' + LIT + r'\s*,\s*' + LIT, text):
            plurals.add(unescape(m.group(2)))
    return keys, plurals

# Native NTFS messages that reach the user carry a specific errno; internal structure checks
# (EIO) stay technical and are not translated.
USER_CODES = 'ENOSPC|EEXIST|ENOENT|ENOTEMPTY|EROFS|EPERM|ENOTDIR|EISDIR|EINVAL|ENAMETOOLONG|ENOTSUP|EBUSY|EFBIG|E2BIG|ESTALE|EILSEQ'


def native_keys(folder):
    keys = set()
    for f in sorted(Path(folder).glob('*.swift')):
        for m in re.finditer(r'NTFSError\(\s*' + LIT + r'\s*,\s*code:\s*(' + USER_CODES + r')\b', f.read_text()):
            if '\\(' not in m.group(1):
                keys.add(unescape(m.group(1)))
    return keys


def worker_keys(path):
    text = Path(path).read_text(); keys = set()
    for m in re.finditer(r'runtime_error\(\s*' + LIT + r'\s*\)', text): keys.add(unescape(m.group(1)))
    for m in re.finditer(r'\bcheck\([^;]*?,\s*' + LIT + r'\s*\)', text): keys.add(unescape(m.group(1)))
    return keys

def parse_strings(path):
    text = Path(path).read_text(encoding='utf-8')
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    table = {}
    for m in re.finditer(LIT + r'\s*=\s*' + LIT + r'\s*;', text):
        k, v = unescape(m.group(1)), unescape(m.group(2))
        if k in table: raise SystemExit(f'{path}: duplicate key {k!r}')
        table[k] = v
    return table

def placeholders(s):
    return sorted(re.findall(r'%(?:\d+\$)?(?:@|ld|d|lld|%)', s))

def main():
    swift_dir, resources = Path(sys.argv[1]), Path(sys.argv[2])
    keys, plurals = swift_keys(swift_dir)
    keys |= worker_keys(swift_dir.parent / 'NTFSWorker.mm')
    native_session = swift_dir.parent / 'NativeSession.h'
    if native_session.exists():
        keys |= worker_keys(native_session)
    keys |= native_keys(swift_dir.parent / 'NTFS')
    errors = []
    for lproj in sorted(resources.glob('*.lproj')):
        if lproj.name == 'en.lproj': continue
        table = parse_strings(lproj / 'Localizable.strings')
        for k in sorted(keys - plurals):
            if k not in table: errors.append(f'{lproj.name}: missing {k!r}')
            elif placeholders(k) != placeholders(table[k]): errors.append(f'{lproj.name}: placeholder mismatch for {k!r}')
        for k in sorted(plurals):
            v = table.get(k)
            if v is None: errors.append(f'{lproj.name}: missing plural {k!r}'); continue
            forms = v.split('|')
            if lproj.name == 'ru.lproj' and len(forms) != 3: errors.append(f'{lproj.name}: plural {k!r} needs 3 forms')
            for form in forms:
                if placeholders(form) != placeholders(k): errors.append(f'{lproj.name}: placeholder mismatch in plural {k!r}')
        unused = set(table) - keys - plurals
        if unused: print(f'note: {lproj.name}: {len(unused)} unused keys: ' + ', '.join(sorted(map(repr, unused))[:8]))
    if errors:
        print('\n'.join(errors)); print(f'Localization check FAILED ({len(errors)} problems)'); sys.exit(1)
    print(f'Localization check passed: {len(keys | plurals)} keys')

if __name__ == '__main__':
    main()
