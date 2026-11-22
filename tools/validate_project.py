# -*- coding: utf-8 -*-
"""Static consistency check for the HarmonyOS project (no SDK required).

Checks:
  1. every relative ETS import resolves to an existing file
  2. every static i18n key exists in both ZH and EN dictionaries
  3. every $r('app.media.*') reference has a generated asset
  4. every AppConstants / Theme member reference is defined
  5. every .json / .json5 file parses
  6. ArkTS-restricted syntax (non-null assertion, any, numeric separators)

Run: python tools/validate_project.py
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ETS_DIR = ROOT / 'entry' / 'src' / 'main' / 'ets'
ETS_FILES = sorted(ETS_DIR.rglob('*.ets'))
ALL_TEXT = '\n'.join(p.read_text(encoding='utf-8') for p in ETS_FILES)

errors = []
warnings = []


def rel(p):
    return str(p.relative_to(ROOT)).replace('\\', '/')


# 1. relative imports
for f in ETS_FILES:
    text = f.read_text(encoding='utf-8')
    for match in re.finditer(r"from\s+'(\.[^']+)'", text):
        target = (f.parent / match.group(1)).with_suffix('.ets')
        if not target.exists():
            errors.append('%s: unresolved import %s' % (rel(f), match.group(1)))

# 2. i18n dictionaries
i18n = (ETS_DIR / 'common' / 'i18n' / 'I18n.ets').read_text(encoding='utf-8')
zh_part = i18n.split('const ZH:')[1].split('const EN:')[0]
en_part = i18n.split('const EN:')[1].split('/** 取文案')[0]
zh_keys = set(re.findall(r"'([A-Za-z0-9_.]+)':\s*'", zh_part))
en_keys = set(re.findall(r"'([A-Za-z0-9_.]+)':\s*'", en_part))
# i18n keys always contain a dot; plain identifiers such as ForEach keys are excluded.
KEY_PATTERN = r"([A-Za-z0-9_]+\.[A-Za-z0-9_.]+)"
used_keys = set()
for f in ETS_FILES:
    if f.name == 'I18n.ets':
        continue  # the doc comment contains an illustrative t('a.b', lang)
    text = f.read_text(encoding='utf-8')
    used_keys |= set(re.findall(r"\btf?\('" + KEY_PATTERN + r"'", text))
    used_keys |= set(re.findall(r"(?:TitleKey|DescKey)\s*:\s*'" + KEY_PATTERN + r"'", text))
    used_keys |= set(re.findall(r"showToast\('" + KEY_PATTERN + r"'", text))
    used_keys |= set(re.findall(r"emptyTitleKey:\s*'" + KEY_PATTERN + r"'", text))
    used_keys |= set(re.findall(r"emptyDescKey:\s*'" + KEY_PATTERN + r"'", text))

for key in sorted(used_keys - zh_keys):
    errors.append('i18n: key used but missing in ZH: %s' % key)
for key in sorted(zh_keys - en_keys):
    errors.append('i18n: ZH key missing in EN: %s' % key)
for key in sorted(en_keys - zh_keys):
    errors.append('i18n: EN key missing in ZH: %s' % key)

# 3. media resources
media = {p.stem for p in (ROOT / 'entry' / 'src' / 'main' / 'resources' / 'base' / 'media').glob('*')}
refs = set(re.findall(r"\$r\('app\.media\.([A-Za-z0-9_]+)'\)", ALL_TEXT))
for name in sorted(refs - media):
    errors.append('media: missing resource app.media.%s' % name)

# 4. constants and theme members
def members(path, class_name):
    text = (ETS_DIR / path).read_text(encoding='utf-8')
    defined = set(re.findall(r'static readonly (\w+)', text))
    defined |= set(re.findall(r'static (\w+)\(', text))
    return defined

app_defined = members('common/constants/AppConstants.ets', 'AppConstants')
theme_defined = members('common/constants/Theme.ets', 'Theme')
for name in sorted(set(re.findall(r'AppConstants\.(\w+)', ALL_TEXT)) - app_defined):
    errors.append('AppConstants: undefined member %s' % name)
for name in sorted(set(re.findall(r'Theme\.(\w+)', ALL_TEXT)) - theme_defined):
    errors.append('Theme: undefined member %s' % name)

# 5. json / json5 (skip generated build/cache output, which is not source)
SKIP_DIRS = {'build', '.hvigor', 'node_modules', 'oh_modules', '.git', '.workbuddy', 'outputs', 'cache'}
json_files = [p for p in sorted(list(ROOT.rglob('*.json')) + list(ROOT.rglob('*.json5')))
              if not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)]
def strip_json5_comments(text):
    """Remove // and /* */ comments that are outside string literals."""
    out = []
    i, n, in_str, quote, block = 0, len(text), False, '', False
    while i < n:
        c = text[i]
        if block:
            if c == '*' and i + 1 < n and text[i + 1] == '/':
                block = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                in_str = False
            i += 1
            continue
        if c in ('"', "'"):
            in_str, quote = True, c
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] not in ('\n', '\r'):
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            block = True
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


for p in json_files:
    try:
        text = strip_json5_comments(p.read_text(encoding='utf-8'))
        # JSON5 allows trailing commas; remove them before strict JSON parse.
        text = re.sub(r',\s*([}\]])', r'\1', text)
        json.loads(text)
    except Exception as exc:
        errors.append('%s: invalid JSON/JSON5: %s' % (rel(p), exc))

# 6. ArkTS restricted syntax
for f in ETS_FILES:
    text = f.read_text(encoding='utf-8')
    if re.search(r'!\.', text):
        warnings.append('%s: non-null assertion (!.) found' % rel(f))
    if re.search(r':\s*any\b|\bas\s+any\b', text):
        warnings.append('%s: `any` type found' % rel(f))
    if re.search(r'\d_\d', text):
        warnings.append('%s: numeric separator found' % rel(f))

print('ETS files        : %d' % len(ETS_FILES))
print('i18n keys        : ZH=%d EN=%d used=%d' % (len(zh_keys), len(en_keys), len(used_keys)))
print('media assets     : %d files, %d referenced' % (len(media), len(refs)))
print('json/json5 files : %d (source only)' % len(json_files))
print('')
if warnings:
    print('WARNINGS (%d):' % len(warnings))
    for w in warnings:
        print('  - ' + w)
    print('')
if errors:
    print('ERRORS (%d):' % len(errors))
    for e in errors:
        print('  - ' + e)
    sys.exit(1)
print('RESULT: PASS - no consistency errors')
