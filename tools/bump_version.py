#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
版本号统一递增工具。

用法：
    python tools/bump_version.py            # 补丁位 +1（1.2.1 -> 1.2.2），默认行为
    python tools/bump_version.py patch      # 同上
    python tools/bump_version.py minor      # 次版本 +1，补丁归零（1.2.1 -> 1.3.0）
    python tools/bump_version.py major      # 主版本 +1，其余归零（1.2.1 -> 2.0.0）
    python tools/bump_version.py 2.1.0      # 显式指定版本
    python tools/bump_version.py --dry-run  # 只打印将要发生的变化，不落盘

会同步写入以下两处，保证编译产物与运行期展示一致：
    1) AppScope/app.json5
         versionName  -> "1.2.2"
         versionCode  -> 1002002   （major * 1000000 + minor * 1000 + patch）
    2) entry/src/main/ets/common/constants/AppConstants.ets
         VERSION_NAME / VERSION_CODE / BUILD_DATE

versionCode 编码规则与 AppConstants 注释一致：
    major * 1_000_000 + minor * 1_000 + patch
因此 minor 最大 999、patch 最大 999；超出会报错，避免两个版本撞号。
"""

import os
import re
import sys
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_JSON = os.path.join(ROOT, 'AppScope', 'app.json5')
CONST_ETS = os.path.join(
    ROOT, 'entry', 'src', 'main', 'ets', 'common', 'constants', 'AppConstants.ets'
)

SEMVER = re.compile(r'^\d+\.\d+\.\d+$')


def parse(version: str):
    if not SEMVER.match(version):
        raise SystemExit('版本号格式非法：%r（应形如 1.2.1）' % version)
    major, minor, patch = (int(x) for x in version.split('.'))
    return major, minor, patch


def encode(major: int, minor: int, patch: int) -> int:
    if minor > 999 or patch > 999:
        raise SystemExit(
            'minor / patch 不能超过 999（versionCode 编码上限），当前 %d.%d.%d'
            % (major, minor, patch)
        )
    return major * 1000000 + minor * 1000 + patch


def read_current() -> str:
    if not os.path.isfile(APP_JSON):
        raise SystemExit('找不到 %s' % APP_JSON)
    with open(APP_JSON, 'r', encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'"versionName"\s*:\s*"([^"]+)"', text)
    if not m:
        raise SystemExit('app.json5 中未找到 versionName 字段')
    return m.group(1).strip()


def next_version(current: str, mode: str) -> str:
    major, minor, patch = parse(current)
    if mode in ('patch', ''):
        return '%d.%d.%d' % (major, minor, patch + 1)
    if mode == 'minor':
        return '%d.%d.0' % (major, minor + 1)
    if mode == 'major':
        return '%d.0.0' % (major + 1)
    if SEMVER.match(mode):
        target = parse(mode)
        if target <= (major, minor, patch):
            raise SystemExit(
                '指定版本 %s 不高于当前 %s，拒绝降级' % (mode, current)
            )
        return mode
    raise SystemExit('未知参数：%r（可用 patch / minor / major / x.y.z）' % mode)


def rewrite_app_json(version: str, code: int, dry: bool) -> str:
    with open(APP_JSON, 'r', encoding='utf-8') as f:
        text = f.read()
    new = re.sub(r'("versionCode"\s*:\s*)\d+', r'\g<1>%d' % code, text, count=1)
    new = re.sub(r'("versionName"\s*:\s*)"[^"]+"', r'\g<1>"%s"' % version, new, count=1)
    if not dry:
        with open(APP_JSON, 'w', encoding='utf-8', newline='\n') as f:
            f.write(new)
    return new


def rewrite_constants(version: str, code: int, build_date: str, dry: bool) -> str:
    with open(CONST_ETS, 'r', encoding='utf-8') as f:
        text = f.read()

    def sub(pattern: str, repl: str, src: str) -> str:
        out, n = re.subn(pattern, repl, src, count=1)
        if n == 0:
            raise SystemExit('AppConstants.ets 未匹配到模式：%s' % pattern)
        return out

    new = sub(r"(VERSION_NAME:\s*string\s*=\s*)'[^']*'",
              r"\g<1>'%s'" % version, text)
    new = sub(r"(VERSION_CODE:\s*string\s*=\s*)'[^']*'",
              r"\g<1>'%d'" % code, new)
    new = sub(r"(BUILD_DATE:\s*string\s*=\s*)'[^']*'",
              r"\g<1>'%s'" % build_date, new)
    if not dry:
        with open(CONST_ETS, 'w', encoding='utf-8', newline='\n') as f:
            f.write(new)
    return new


def main() -> None:
    args = [a for a in sys.argv[1:] if a != '--dry-run']
    dry = '--dry-run' in sys.argv[1:]
    mode = args[0].strip() if args else 'patch'

    current = read_current()
    target = next_version(current, mode)
    major, minor, patch = parse(target)
    code = encode(major, minor, patch)
    today = datetime.date.today().isoformat()

    rewrite_app_json(target, code, dry)
    rewrite_constants(target, code, today, dry)

    old_code = encode(*parse(current))
    print('版本号：%s (%d)  ->  %s (%d)' % (current, old_code, target, code))
    print('构建日期：%s' % today)
    print('已同步：AppScope/app.json5、AppConstants.ets')
    if dry:
        print('（--dry-run：未写入任何文件）')


if __name__ == '__main__':
    main()
