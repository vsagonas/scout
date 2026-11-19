#!/usr/bin/env python3
"""Wraps the plain string literals of the given lines in String(localized: "..."), a helper for the localization pass.

Usage: scripts/l10n/wrap.py <file> <line>[-<line>] ...   (1-based; ranges allowed)
Only literals that hold a letter are wrapped; literals that are already wrapped (String(localized:), Text(, LocalizedStringKey, verbatim:),
dictionary keys, and interpolation-free identifiers you do not want touched must be reviewed by you: the script prints every changed line.
"""
import re, sys

LIT = re.compile(r'(?<![\w"\\])"((?:[^"\\]|\\.)*)"')

def wrap_line(line):
    out, last = [], 0
    for m in LIT.finditer(line):
        body = m.group(1)
        if not re.search(r'[A-Za-z]{2,}', re.sub(r'\\\([^)]*\)', '', body)):
            continue
        before = line[:m.start()]
        if before.rstrip().endswith('localized:') or before.rstrip().endswith('verbatim:'):
            continue
        out.append(line[last:m.start()])
        out.append('String(localized: "%s")' % body)
        last = m.end()
    out.append(line[last:])
    return ''.join(out)

def main():
    path = sys.argv[1]
    wanted = set()
    for a in sys.argv[2:]:
        if '-' in a:
            x, y = a.split('-'); wanted.update(range(int(x), int(y) + 1))
        else:
            wanted.add(int(a))
    lines = open(path, encoding='utf-8').read().split('\n')
    for n in sorted(wanted):
        new = wrap_line(lines[n - 1])
        if new != lines[n - 1]:
            lines[n - 1] = new
            print('%d: %s' % (n, new.strip()[:200]))
    open(path, 'w', encoding='utf-8').write('\n'.join(lines))

main()
