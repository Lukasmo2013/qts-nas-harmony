#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""精确文本替换工具（开发期辅助）。

用法：
    python tools/_edit.py <相对路径> <<'EOF'
    {"old": "原文", "new": "新文"}
    EOF
可传 JSON 数组做多处替换。全部命中才落盘。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) < 2:
        print("usage: _edit.py <relpath> [json]", file=sys.stderr)
        return 2
    rel = sys.argv[1]
    path = os.path.join(ROOT, rel)
    payload = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()
    data = json.loads(payload)
    edits = data if isinstance(data, list) else [data]
    with io.open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    for item in edits:
        old, new = item["old"], item["new"]
        if old not in text:
            print("MISS in %s:/n---/n%s/n---" % (rel, old[:400]), file=sys.stderr)
            return 1
        if text.count(old) != 1 and not item.get("allow_many"):
            print("AMBIGUOUS (%d) in %s:/n---/n%s/n---" % (text.count(old), rel, old[:200]), file=sys.stderr)
            return 1
        text = text.replace(old, new)
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("OK %s (%d edits)" % (rel, len(edits)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
