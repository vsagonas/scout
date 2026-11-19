#!/usr/bin/env python3
"""Checks translated app strings against the English files.

Usage: scripts/l10n/check.py <code> [<code> ...]       e.g.  scripts/l10n/check.py de fr pt-BR
       scripts/l10n/check.py --all                      every Support/Resources/*.lproj that exists
Checks Support/Resources/<code>.lproj/Localizable.strings and InfoPlist.strings against l10n/en/*.strings.

ERRORS (exit status 1): file missing or not UTF-8 / starts with a BOM; a line that is not `"key" = "value";`; a key twice; keys missing or
added; an empty value; placeholders (%@ %d %lld %lf %u %1$@ ...) that differ in kind or count from the English value; `%%` not kept; an escape
other than \\" \\\\ \\n; a different number of \\n; an English sentence (three or more words) copied unchanged (brand names, numbers and symbols
excepted, and the pixel-font words of l10n/PIXEL-LABELS.txt in languages that do not write Latin letters); `...` instead of the one `…` character
(or `…` dropped); Arabic-Indic or other non-Western digits; an em or en dash used as a separator; the plural forms asked by l10n/PLURALS.txt missing.
WARNINGS (printed, exit status stays 0): a translation over 200% of an English value of up to 25 characters; a one or two word value equal to
English (cognates are normal: Radio, Pomodoro); `›`, `•`, a modifier symbol or an emoji of the English value dropped.

l10n/PLURALS.txt (only when a counted word could not be rephrased): one line per key, `key<TAB>English singular<TAB>English plural`. The translation
then holds all the plural forms of its language separated by ` || ` (the CLDR categories in order: one, few, many, other; only the ones the
language uses), each form with the same placeholders.
"""
import os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
RES = os.path.join(ROOT, 'Support', 'Resources')
CODES = ['ar', 'cs', 'da', 'de', 'el', 'es', 'fi', 'fr', 'hr', 'hu', 'it', 'ja', 'ko', 'nb', 'nl', 'pl', 'pt-BR', 'pt-PT', 'ro', 'ru', 'sk', 'sv', 'tr', 'uk', 'zh-Hans', 'zh-Hant']
LATER = ['bg', 'et', 'ga', 'lv', 'lt', 'mt', 'sl']
NON_LATIN = {'el', 'ru', 'uk', 'ar', 'ja', 'ko', 'zh-Hans', 'zh-Hant', 'bg'}
# CLDR plural categories used by each language (cardinal), in the order the ` || ` forms are written.
PLURAL_FORMS = {'ar': 6, 'cs': 4, 'pl': 4, 'ru': 4, 'uk': 4, 'sk': 4, 'hr': 3, 'ro': 3, 'lt': 4, 'lv': 3, 'sl': 4, 'ga': 5, 'mt': 5, 'ja': 1, 'ko': 1, 'zh-Hans': 1, 'zh-Hant': 1}
BRANDS = {w.lower() for w in (
    'Scout Claude Code Codex OpenAI GPT Anthropic Mac macOS AirPods AirDrop Spotlight Keychain Zoom Meet Teams Webex Spotify Safari Chrome Arc Edge Brave '
    'Opera Firefox yt-dlp ffmpeg deno cwebp Homebrew brew Open-Meteo LRCLIB SwiftTerm Frankfurter Bluetooth Wi-Fi iCloud iPhone Apple Music Notes Google '
    'YouTube Instagram TikTok Vimeo Reddit Haiku Sonnet Opus Nook Pomodoro Pocket Pockets Polaroid LED CRT AI API JSON ZIP PDF PNG JPEG HEIC TIFF MP3 MP4 '
    'M4A WebP URL Esc Return Space Option Shift Command Control Delete USB CPU GPU SSD RAM wpm OK 8-bit').split()}

PLACEHOLDER = re.compile(r'%(?:(\d+)\$)?[-+ 0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|L)?([@dDuUxXoOfeEgGcCsSpaA%])')
ESCAPE = re.compile(r'\\(.)')
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
NON_WESTERN_DIGITS = re.compile('[٠-٩۰-۹०-९০-৯๐-๙０-９]')
SEPARATOR_DASH = re.compile('[–—]')
MODIFIERS = '⌘⌥⇧⌃'

class Report:
    def __init__(self):
        self.errors, self.warnings = [], []
    def error(self, where, msg): self.errors.append('ERROR %s: %s' % (where, msg))
    def warn(self, where, msg): self.warnings.append('warning %s: %s' % (where, msg))

def parse(path, report, where):
    """-> ordered dict key -> raw (still escaped) value, or None when the file cannot be used."""
    try:
        raw = open(path, 'rb').read()
    except OSError:
        report.error(where, 'file is missing')
        return None
    if raw.startswith(b'\xef\xbb\xbf'):
        report.error(where, 'starts with a BOM (UTF-8 without BOM, please)')
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError as e:
        report.error(where, 'not UTF-8 (%s)' % e)
        return None
    out = {}
    for n, line in enumerate(text.lstrip('﻿').split('\n'), 1):
        if not line.strip():
            continue
        m = LINE.match(line)
        if not m:
            report.error('%s:%d' % (where, n), 'not one entry of the form "key" = "value"; -> %s' % line[:80])
            continue
        key, value = m.group(1), m.group(2)
        if key in out:
            report.error('%s:%d' % (where, n), 'key twice: %s' % key[:60])
        out[key] = value
    return out

def placeholders(value):
    """-> (list of (position or None, conversion) for real placeholders, count of %%)"""
    found, percents = [], 0
    for m in PLACEHOLDER.finditer(value):
        conv = m.group(3)
        if conv == '%':
            percents += 1
        else:
            found.append((m.group(1), (m.group(2) or '') + conv))
    return found, percents

def signature(items):
    return sorted((pos or '', conv) for pos, conv in items)

def kinds(items):
    return sorted(conv for _, conv in items)

def letters_only(value):
    plain = PLACEHOLDER.sub(' ', ESCAPE.sub(' ', value))
    return re.findall(r"[^\W\d_][\w'’-]*", plain, flags=re.UNICODE)

def is_exempt_copy(en_value):
    words = letters_only(en_value)
    if not words:
        return True
    return all(w.lower().strip("'’-") in BRANDS or len(w) < 2 for w in words)

def check_file(code, name, en, tr, report, pixel, plurals):
    where_base = '%s %s' % (code, name)
    for key in en:
        if key not in tr:
            report.error(where_base, 'key missing: %s' % key[:70])
    for key in tr:
        if key not in en:
            report.error(where_base, 'key added or changed (not in English): %s' % key[:70])
    for key, en_value in en.items():
        if key not in tr:
            continue
        value = tr[key]
        where = '%s: %s' % (where_base, key[:48])
        if not value.strip():
            report.error(where, 'empty value')
            continue
        for esc in ESCAPE.finditer(value):
            if esc.group(1) not in '"\\n':
                report.error(where, 'escape \\%s is not allowed (only \\" \\\\ \\n)' % esc.group(1))
        if value.count('\\n') != en_value.count('\\n'):
            report.error(where, 'number of \\n differs (%d, English %d)' % (value.count('\\n'), en_value.count('\\n')))
        en_ph, en_pc = placeholders(en_value)
        tr_ph, tr_pc = placeholders(value)
        is_plural = key in plurals
        forms = value.split(' || ') if is_plural else [value]
        if is_plural:
            want = PLURAL_FORMS.get(code, 2)
            if len(forms) != want:
                report.error(where, 'plural key needs %d forms separated by " || " (found %d)' % (want, len(forms)))
        for form in forms:
            f_ph, f_pc = placeholders(form)
            if kinds(f_ph) != kinds(en_ph) and not (is_plural and len(f_ph) <= len(en_ph)):
                report.error(where, 'placeholders differ: English %s, translation %s' % (sorted(c for _, c in en_ph), sorted(c for _, c in f_ph)))
            elif any(p for p, _ in f_ph) and not is_plural:
                if sorted(p or '' for p, _ in f_ph) != sorted(str(i + 1) for i in range(len(f_ph))):
                    report.error(where, 'positional placeholders must be %1$ %2$ ... each once')
                else:   # each position must keep the type English has at that position (English written %@ %@ reads as 1, 2, ...)
                    en_by_pos = {str(i + 1): c for i, (p, c) in enumerate(en_ph) if p is None} or {p: c for p, c in en_ph if p}
                    tr_by_pos = {p: c for p, c in f_ph}
                    if en_by_pos != tr_by_pos:
                        report.error(where, 'positional placeholders change the type of an argument')
            if f_pc != en_pc and not is_plural:
                report.error(where, '%% count differs (%d, English %d)' % (f_pc, en_pc))
        if value == en_value and not is_plural:
            exempt = is_exempt_copy(en_value) or (key in pixel and code in NON_LATIN)
            if not exempt:
                if len(letters_only(en_value)) >= 3:
                    report.error(where, 'English sentence copied unchanged')
                else:
                    report.warn(where, 'same as English (fine for a cognate)')
        if '...' in value:
            report.error(where, 'three dots: use the single character …')
        if '…' in en_value and '…' not in value:
            report.error(where, 'the … of the English value is missing')
        if NON_WESTERN_DIGITS.search(value):
            report.error(where, 'non-Western digits: write 0-9 in every language')
        if SEPARATOR_DASH.search(value):
            report.error(where, 'em/en dash used as a separator: use a colon, a comma or a hyphen')
        for sym in ('›', '•') + tuple(MODIFIERS):
            if sym in en_value and sym not in value:
                report.warn(where, 'English has %s, the translation does not' % sym)
        if len(en_value) <= 25 and value != en_value and len(value) > 2 * len(en_value) and not is_plural:
            report.warn(where, 'translation is %d%% of the English length (%d vs %d characters)' % (100 * len(value) // max(1, len(en_value)), len(value), len(en_value)))

def main():
    args = sys.argv[1:]
    if not args or args in (['-h'], ['--help']):
        print(__doc__); return 2
    if args == ['--all']:
        args = sorted(d[:-6] for d in os.listdir(RES) if d.endswith('.lproj')) if os.path.isdir(RES) else []
    en = {}
    report = Report()
    for name in ('Localizable.strings', 'InfoPlist.strings'):
        en[name] = parse(os.path.join(ROOT, 'l10n', 'en', name), report, 'l10n/en/' + name)
        if en[name] is None:
            print('\n'.join(report.errors)); return 1
    pixel = set()
    pf = os.path.join(ROOT, 'l10n', 'PIXEL-LABELS.txt')
    if os.path.exists(pf):
        pixel = {l.rstrip('\n') for l in open(pf, encoding='utf-8') if l.strip() and not l.startswith('#')}
    plurals = set()
    qf = os.path.join(ROOT, 'l10n', 'PLURALS.txt')
    if os.path.exists(qf):
        plurals = {l.split('\t')[0] for l in open(qf, encoding='utf-8') if l.strip() and not l.startswith('#')}
    status = 0
    for code in args:
        if code not in CODES and code not in LATER:
            print('ERROR %s: not a language code of CODES or LATER in scripts/l10n/check.py' % code); status = 1; continue
        rep = Report()
        folder = os.path.join(RES, code + '.lproj')
        if not os.path.isdir(folder):
            rep.error(code, 'Support/Resources/%s.lproj does not exist' % code)
        else:
            for name in ('Localizable.strings', 'InfoPlist.strings'):
                tr = parse(os.path.join(folder, name), rep, '%s %s' % (code, name))
                if tr is not None:
                    check_file(code, name, en[name], tr, rep, pixel if name == 'Localizable.strings' else set(), plurals if name == 'Localizable.strings' else set())
        for line in rep.errors + rep.warnings:
            print(line)
        print('%s: %d errors, %d warnings' % (code, len(rep.errors), len(rep.warnings)))
        if rep.errors:
            status = 1
    return status

if __name__ == '__main__':
    sys.exit(main())
