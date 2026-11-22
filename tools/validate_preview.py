# -*- coding: utf-8 -*-
"""Validate preview/index.html: JS syntax (via node --check) and i18n key coverage.

Run: python tools/validate_preview.py
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HTML = (ROOT / 'preview' / 'index.html').read_text(encoding='utf-8')
errors = []

match = re.search(r'<script>([\s\S]*?)</script>', HTML)
if not match:
    print('ERROR: no <script> block found')
    sys.exit(1)
script = match.group(1)

# 1. JS syntax check through Node
with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as tmp:
    tmp.write(script)
    tmp_path = tmp.name
try:
    proc = subprocess.run(['node', '--check', tmp_path], capture_output=True, text=True)
    if proc.returncode != 0:
        errors.append('JS syntax: ' + proc.stderr.strip()[:800])
finally:
    pathlib.Path(tmp_path).unlink(missing_ok=True)

# 2. i18n dictionaries
# 结构为 `const I18N = { zh: { ... }, en: { ... } };`，用正则定位以容忍空白差异。
zh_m = re.search(r'\bzh\s*:\s*\{', HTML)
en_m = re.search(r'\ben\s*:\s*\{', HTML)
if not zh_m or not en_m:
    print('ERROR: cannot locate zh/en i18n dictionaries in preview/index.html')
    sys.exit(1)
zh_part = HTML[zh_m.end():en_m.start()]
en_tail = HTML[en_m.end():]
en_end = en_tail.find('};')
en_part = en_tail[:en_end] if en_end >= 0 else en_tail


def strip_strings(text):
    """去掉字符串字面量，避免把值里的 `xxx:` 误当成键。"""
    return re.sub(r'"[^"\n]*"|\'[^\'\n]*\'', ' ', text)


# 预览页 i18n 字典使用裸标识符键（appName: "..."），一行可有多个键。
KEY_RE = r'([A-Za-z_][A-Za-z0-9_]*)\s*:'
zh = set(re.findall(KEY_RE, strip_strings(zh_part)))
en = set(re.findall(KEY_RE, strip_strings(en_part)))

for key in sorted(zh - en):
    errors.append('i18n: ZH key missing in EN: %s' % key)
for key in sorted(en - zh):
    errors.append('i18n: EN key missing in ZH: %s' % key)

# 3. used keys
used = set()
for pattern in [
    r"\bt\(\s*'([A-Za-z0-9_.]+)'",
    r"\b(?:kv|head|toast|field)\(\s*'([A-Za-z0-9_.]+)'",
    r"(?:title|desc|btn):\s*'([A-Za-z0-9_.]+\.[A-Za-z0-9_.]+)'",
]:
    used |= set(re.findall(pattern, script))
for key in sorted(used - zh):
    errors.append('i18n: key used but missing: %s' % key)

# 4. 交互函数：预览页用 onclick="fn(...)" 直接绑定，需确认 fn 已定义
handlers = set(re.findall(r'function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', script))
handlers |= set(re.findall(r'(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s*)?(?:function|\()', script))
callbacks = set(re.findall(r'onclick="([A-Za-z_][A-Za-z0-9_]*)\s*\(', HTML))
callbacks |= set(re.findall(r"addEventListener\('click',\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", script))
for fn in sorted(callbacks - handlers):
    errors.append('handler: onclick references undefined function: %s' % fn)

print('script length    : %d chars' % len(script))
print('i18n keys        : ZH=%d EN=%d used=%d' % (len(zh), len(en), len(used)))
print('handlers         : %d defined / %d referenced' % (len(handlers), len(callbacks)))
print('')
if errors:
    print('ERRORS (%d):' % len(errors))
    for e in errors:
        print('  - ' + e)
    sys.exit(1)
print('RESULT: PASS - JS syntax and i18n coverage OK')
