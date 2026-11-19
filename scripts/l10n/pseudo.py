#!/usr/bin/env python3
"""Generates the pseudo language from l10n/en/Localizable.strings: every value wrapped like `[! ... !]`, vowels accented, about 40% longer,
placeholders and escapes kept. A view that shows English words with no `[!` / `!]` around them is not localized (or is user data).
Pixel-font words (l10n/PIXEL-LABELS.txt) cannot carry brackets (the 5x7 font has none), so they are wrapped in `!` only.

Usage: pseudo.py <out Localizable.strings> [<out InfoPlist.strings>]
The result is for DEBUG builds only (scripts/build-app.sh debug with SCOUT_PSEUDO=1); a store build never contains it.
"""
import os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
ACCENT = str.maketrans('aeiouAEIOUyY', 'àéîöüÀÉÎÖÜýÝ')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ 0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|L)?[@dDuUxXoOfeEgGcCsSpaA%]|\\(?:n|t|r|"|\\)')
PARSE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')

def pseudo(value, pixel):
    parts, last, letters = [], 0, 0
    for m in PLACEHOLDER.finditer(value):
        parts.append((False, value[last:m.start()]))
        parts.append((True, m.group(0)))
        last = m.end()
    parts.append((False, value[last:]))
    out, plain = [], []
    for keep, text in parts:
        if keep:
            out.append(text)
        else:
            out.append(text.translate(ACCENT))
            plain.append(text.translate(ACCENT))
            letters += len(text)
    body = ''.join(out)
    pad = ''.join(plain)
    extra = max(2, int(round(letters * 0.4)))
    filler = (pad.strip() + ' ') * 3
    body += ' ' + filler[:extra].rstrip()
    return '!%s!' % body if pixel else '[! %s !]' % body

def main():
    out = sys.argv[1]
    pixels = set()
    pf = os.path.join(ROOT, 'l10n', 'PIXEL-LABELS.txt')
    if os.path.exists(pf):
        pixels = {l.rstrip('\n') for l in open(pf, encoding='utf-8') if l.strip() and not l.startswith('#')}
    with open(os.path.join(ROOT, 'l10n', 'en', 'Localizable.strings'), encoding='utf-8') as src, open(out, 'w', encoding='utf-8', newline='\n') as dst:
        for line in src:
            m = PARSE.match(line)
            if not m:
                continue
            key, value = m.group(1), m.group(2)
            if value == '%@':
                dst.write('"%s" = "%s";\n' % (key, value))
                continue
            dst.write('"%s" = "%s";\n' % (key, pseudo(value, key in pixels)))
    if len(sys.argv) > 2:
        with open(os.path.join(ROOT, 'l10n', 'en', 'InfoPlist.strings'), encoding='utf-8') as src, open(sys.argv[2], 'w', encoding='utf-8', newline='\n') as dst:
            for line in src:
                m = PARSE.match(line)
                if m:
                    key = m.group(1)
                    dst.write('"%s" = "%s";\n' % (key, m.group(2) if key == 'CFBundleDisplayName' else pseudo(m.group(2), False)))

main()
