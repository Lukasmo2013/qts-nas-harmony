#!/usr/bin/env python3
"""在构建前还原压缩存放的预编译动态库。

仓库中的 `libtailscale_go.so.xz` 是 Tailscale Go 引擎（约 24MB）的压缩包，
由于体积原因以 xz 形式入库。构建前执行本脚本即可还原为同名 `.so`：

    python tools/unpack_libs.py

脚本是幂等的：目标 `.so` 已存在且大小正确时不会重复解压。
"""
import lzma
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(ROOT, "entry", "libs", "arm64-v8a")


def unpack(archive_path: str) -> None:
    target = archive_path[: -len(".xz")]
    with lzma.open(archive_path, "rb") as src:
        data = src.read()
    if os.path.exists(target) and os.path.getsize(target) == len(data):
        print("skip (already unpacked): %s" % os.path.basename(target))
        return
    with open(target, "wb") as dst:
        dst.write(data)
    print("unpacked: %s (%.1f MB)" % (os.path.basename(target), len(data) / 1048576))


def main() -> int:
    if not os.path.isdir(LIB_DIR):
        print("lib dir not found: %s" % LIB_DIR, file=sys.stderr)
        return 1
    archives = sorted(f for f in os.listdir(LIB_DIR) if f.endswith(".so.xz"))
    if not archives:
        print("no .so.xz archive found in %s" % LIB_DIR)
        return 0
    for name in archives:
        unpack(os.path.join(LIB_DIR, name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
