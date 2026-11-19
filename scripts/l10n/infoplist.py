#!/usr/bin/env python3
"""InfoPlist.strings helper (the permission texts and the app name macOS shows).

  infoplist.py gen-en                       writes l10n/en/InfoPlist.strings from Support/Info.plist and Support/Info-AppStore.plist
  infoplist.py bundle <full|appstore> <in> <out>
                                            turns a language's InfoPlist.strings (the full set, with the `KEY~appstore` variants) into the file
                                            that edition ships: the App Store edition gets the `~appstore` text under the real key and only the
                                            keys its Info.plist has; the full edition drops the `~appstore` keys.

The file holds every key of both plists. Where the two editions word a permission differently (Apple Events, Bluetooth) the real key carries the
full edition's text and `KEY~appstore` the App Store's; translators translate both. The English Info.plist files keep the English text themselves.
"""
import os, plistlib, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SUFFIX = '~appstore'

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def load(name):
    return plistlib.load(open(os.path.join(ROOT, 'Support', name), 'rb'))

def keys_of(plist):
    return {k: v for k, v in plist.items() if k == 'CFBundleDisplayName' or (k.startswith('NS') and k.endswith('UsageDescription'))}

def parse(path):
    out = {}
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out

def gen_en():
    full, store = keys_of(load('Info.plist')), keys_of(load('Info-AppStore.plist'))
    entries = dict(full)
    for k, v in store.items():
        if k not in full:
            entries[k] = v
        elif full[k] != v:
            entries[k + SUFFIX] = v
    target = os.path.join(ROOT, 'l10n', 'en', 'InfoPlist.strings')
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, 'w', encoding='utf-8', newline='\n') as f:
        for k in sorted(entries):
            f.write('"%s" = "%s";\n' % (k, esc(entries[k])))
    print('wrote %s (%d keys)' % (target, len(entries)))

def bundle(edition, src, dst):
    entries = parse(src)
    if edition == 'appstore':
        allowed = set(keys_of(load('Info-AppStore.plist')))
        out = {}
        for k, v in entries.items():
            if k.endswith(SUFFIX):
                continue
            if k in allowed:
                out[k] = entries.get(k + SUFFIX, v)
    else:
        out = {k: v for k, v in entries.items() if not k.endswith(SUFFIX)}
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        for k in sorted(out):
            f.write('"%s" = "%s";\n' % (k, out[k]))   # values are already escaped in the source file

if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'gen-en':
        gen_en()
    elif len(sys.argv) == 5 and sys.argv[1] == 'bundle':
        bundle(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__); sys.exit(2)
