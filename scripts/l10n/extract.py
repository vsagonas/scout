#!/usr/bin/env python3
"""Merges the compiler's .stringsdata files of the full and the App Store edition into l10n/en/Localizable.strings.

Usage: extract.py <sd-full-dir> <sd-appstore-dir> [--write]
- keys come from every source file of Sources/Scout except the self-tests, galleries, test rigs and the store-screenshot scenes;
- the words of pixelLabel("…") calls are added (the compiler does not see them);
- the English file is `"key" = "key";` sorted by key, UTF-8, escaped, one entry per line;
- build/l10n/key-sources.txt says where each key is used; build/l10n/lint.txt lists code that probably shows English text unlocalized.
Never writes anything but l10n/en/Localizable.strings (with --write) and the two files under build/l10n.
"""
import glob, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'Sources', 'Scout')
SKIP = re.compile(r'(SelfTest|Gallery|TestRig|Tests?\.swift$|StoreAgentSamples|StoreCanvas|StoreScene|EyeTour|AppIconArt)')
EXCLUDE_KEYS = os.path.join(ROOT, 'l10n', 'exclude-keys.txt')   # keys that only a test or a drawn sample uses, one per line
UNREACHABLE = os.path.join(ROOT, 'l10n', 'unreachable-sources.txt')   # files nothing opens any more: their own keys are left out

def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')

def unescape_literal(s):
    return bytes(s, 'utf-8').decode('unicode_escape').encode('latin-1', 'ignore').decode('utf-8', 'ignore') if '\\' in s else s

def swift_files():
    for dp, _, fn in os.walk(SRC):
        for f in sorted(fn):
            if f.endswith('.swift') and not SKIP.search(f):
                yield os.path.join(dp, f)

def collect(dirs):
    keys = {}
    for d in dirs:
        for path in glob.glob(os.path.join(d, '*.stringsdata')):
            data = json.load(open(path, encoding='utf-8'))
            src = data.get('source', '')
            if not src.startswith(SRC) or SKIP.search(os.path.basename(src)):
                continue
            for table, entries in data.get('tables', {}).items():
                for e in entries:
                    if table != 'Localizable':
                        print('WARNING: table %s in %s (only Localizable is shipped)' % (table, src), file=sys.stderr)
                    where = '%s:%s' % (os.path.relpath(src, ROOT), e.get('location', {}).get('startingLine', '?'))
                    keys.setdefault(e['key'], set()).add(where)
    return keys

PIXEL = re.compile(r'pixelLabel\("((?:[^"\\]|\\.)*)"\)')
BOARD = re.compile(r'boardText\(String\(localized: "((?:[^"\\]|\\.)*)"')   # the LED board's own sentences (drawn in the 5x7 font) are compiler keys too

def pixel_keys():
    out = {}
    for path in swift_files():
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            for m in PIXEL.finditer(line):
                out.setdefault(m.group(1), set()).add('%s:%d' % (os.path.relpath(path, ROOT), n))
            for m in BOARD.finditer(line):
                out.setdefault(re.sub(r'\\\([^)]*\)', '%@', m.group(1)), set()).add('%s:%d' % (os.path.relpath(path, ROOT), n))
    return out

LINT = [
    ('kit takes a final String: wrap the literal in String(localized:) or pixelLabel()', re.compile(r'\b(RetroPixelText|RetroOSD|Dash90Text|LiveRetroFact|MiniLamp|LampOrMini|PolaroidPixelText|DashLabel)\((text: )?"[^"]*[A-Za-z]{2}')),
    ('AppKit text with a literal: use String(localized:)', re.compile(r'(NSMenuItem\(title: "|\.messageText = "|\.informativeText = "|\.placeholderString = "|\.prompt = "|\.toolTip = "|\.title = "[A-Z]|addButton\(withTitle: "|statusItem\.button\?\.toolTip = ")')),
    ('plural built by hand ("" : "s"): rephrase the English ("Agents: 3") or list it in l10n/PLURALS.txt', re.compile(r'\?\s*""\s*:\s*"(s|es)"|\bplural\b.*"s"')),
    ('sentence glued from pieces with + or "\\(a) \\(b)": one sentence with placeholders', re.compile(r'"[^"]*[a-z] " \+ |\+ " [a-z][^"]*"')),
    ('fixed English date/time/number format for display (Locale en_US)', re.compile(r'en_US|dateFormat = "(?!yyyy-MM-dd|HH:mm:ss|yyyyMMdd)')),
    ('Text(String(format:)): a format string that is not localizable', re.compile(r'Text\(String\(format: "')),
]

def lint():
    out = []
    for path in swift_files():
        rel = os.path.relpath(path, ROOT)
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            code = line.split('//')[0] if '"' not in line.split('//')[0][-1:] else line
            for msg, rx in LINT:
                if rx.search(code):
                    out.append('%s:%d: %s' % (rel, n, msg))
    return out

def main():
    dirs = [a for a in sys.argv[1:] if not a.startswith('--')]
    write = '--write' in sys.argv
    keys = collect(dirs)
    pixel = pixel_keys()
    for k, w in pixel.items():
        keys.setdefault(k, set()).update(w)
    keys.pop('', None)   # Toggle("", ...) and the like: an empty label is not a sentence
    if os.path.exists(EXCLUDE_KEYS):
        for line in open(EXCLUDE_KEYS, encoding='utf-8'):
            keys.pop(line.rstrip('\n'), None)
    dead = set()
    if os.path.exists(UNREACHABLE):
        dead = {l.strip() for l in open(UNREACHABLE, encoding='utf-8') if l.strip() and not l.startswith('#')}
    dropped = 0
    for k in list(keys):
        if dead and all(w.rsplit(':', 1)[0] in dead for w in keys[k]):
            del keys[k]
            dropped += 1
    if dropped:
        print('%d keys used only by unreachable files left out (l10n/unreachable-sources.txt)' % dropped)
    ordered = sorted(keys)
    body = ''.join('"%s" = "%s";\n' % (escape(k), escape(k)) for k in ordered)
    work = os.path.join(ROOT, 'build', 'l10n')
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, 'key-sources.txt'), 'w', encoding='utf-8') as f:
        for k in ordered:
            f.write('%s\t%s\n' % (escape(k), ' '.join(sorted(keys[k])[:3])))
    problems = lint()
    with open(os.path.join(work, 'lint.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(problems) + '\n')
    print('%d keys; %d lint lines (build/l10n/lint.txt); sources in build/l10n/key-sources.txt' % (len(ordered), len(problems)))
    if write:
        target = os.path.join(ROOT, 'l10n', 'en', 'Localizable.strings')
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'w', encoding='utf-8', newline='\n') as f:
            f.write(body)
        print('wrote', target)
        with open(os.path.join(ROOT, 'l10n', 'PIXEL-LABELS.txt'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('# Keys drawn in the 5x7 pixel font (capital Latin letters, digits and . , : ; ! ? - + / \' ( ) %% & # @ * only). Translate them in capitals\n')
            f.write('# and short; a translation with any other letter is not drawn (the English word is shown instead), so languages that do not\n')
            f.write('# write Latin letters (el, ru, uk, ar, ja, ko, zh-Hans, zh-Hant) may keep the English word for these keys.\n')
            for k in sorted(pixel):
                if k in keys:
                    f.write(k + '\n')
        print('wrote l10n/PIXEL-LABELS.txt')

main()
