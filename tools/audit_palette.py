#!/usr/bin/env python
"""像素级配色审计：检查界面截图是否残留「暖黄」色调。

背景：HarmonyOS 的玻璃拟态（backgroundBlurStyle）会采样窗口背景，若窗口底色沿用
系统默认（受设备壁纸 / 主题色影响），暖黄色调会透过模糊层给整页染色。本脚本用
Pillow 统计每张截图的暖黄像素占比与中位饱和度，作为「去黄」改版的回归基线。

用法：
    python tools/audit_palette.py                # 审计 preview/_shots 下全部截图
    python tools/audit_palette.py --dir <目录>   # 指定目录
    python tools/audit_palette.py --max-warm 0.0 # 自定义暖黄占比阈值（默认 0.005 = 0.5%）
"""
import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    print('需要 Pillow：pip install Pillow', file=sys.stderr)
    sys.exit(2)

# 暖黄判定：色相落在 黄(40~70°) / 橙(15~40°) 区间，且饱和度不低于 0.30
HUE_LO, HUE_HI = 15.0, 70.0
SAT_MIN = 0.30
DEFAULT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'preview', '_shots')


def is_warm(r: int, g: int, b: int) -> bool:
    mx, mn = max(r, g, b), min(r, g, b)
    if mx == mn:
        return False
    delta = mx - mn
    if mx == r:
        h = 60 * (((g - b) / delta) % 6)
    elif mx == g:
        h = 60 * ((b - r) / delta + 2)
    else:
        h = 60 * ((r - g) / delta + 4)
    s = delta / mx
    return HUE_LO <= h <= HUE_HI and s >= SAT_MIN


def audit(path: str) -> tuple:
    """用颜色直方图统计，避免逐像素物化大图（2880x1800 时内存占用显著降低）。"""
    with Image.open(path) as im:
        rgb = im.convert('RGB')
        w, h = rgb.size
        total = w * h
        colors = rgb.getcolors(maxcolors=1 << 24) or []

    warm = 0
    sat_hist = []          # (饱和度, 像素数) 累积，用于求中位数
    for count, (r, g, b) in colors:
        mx = max(r, g, b)
        sat = 0.0 if mx == 0 else (mx - min(r, g, b)) / mx
        sat_hist.append((sat, count))
        if is_warm(r, g, b):
            warm += count

    sat_hist.sort()
    half = total // 2
    acc = 0
    median_sat = 0.0
    for sat, count in sat_hist:
        acc += count
        if acc >= half:
            median_sat = sat
            break

    return total, warm, warm / total * 100.0, median_sat


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', default=DEFAULT_DIR)
    ap.add_argument('--max-warm', type=float, default=0.005, help='暖黄占比上限（百分比）')
    args = ap.parse_args()

    d = os.path.abspath(args.dir)
    if not os.path.isdir(d):
        print('目录不存在：%s' % d, file=sys.stderr)
        return 2

    shots = sorted(f for f in os.listdir(d) if f.lower().endswith('.png'))
    if not shots:
        print('目录内无 PNG：%s' % d)
        return 0

    failed = []
    print('%-28s %14s %14s' % ('shot', '暖黄占比', '中位饱和度'))
    print('-' * 60)
    for name in shots:
        total, warm, ratio, sat = audit(os.path.join(d, name))
        flag = ' <== 超阈值' if ratio > args.max_warm else ''
        print('%-28s %13.4f%% %14.4f%s' % (name, ratio, sat, flag))
        if ratio > args.max_warm:
            failed.append(name)

    print('-' * 60)
    if failed:
        print('RESULT: FAIL - %d 张截图暖黄占比超阈值' % len(failed))
        return 1
    print('RESULT: PASS - 全部 %d 张截图暖黄占比均低于 %.4f%%' % (len(shots), args.max_warm))
    return 0


if __name__ == '__main__':
    sys.exit(main())
