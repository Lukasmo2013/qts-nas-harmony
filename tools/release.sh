#!/usr/bin/env bash
# 一键发布：版本递增 -> 项目校验 -> release 编译
#
# 用法：
#   ./tools/release.sh            # 补丁位 +1 后编译（1.2.1 -> 1.2.2）
#   ./tools/release.sh minor      # 次版本 +1 后编译（1.2.1 -> 1.3.0）
#   ./tools/release.sh major      # 主版本 +1 后编译（1.2.1 -> 2.0.0）
#   ./tools/release.sh 1.5.0      # 显式版本后编译
#   ./tools/release.sh --no-bump  # 不改版本，直接校验 + 编译
#
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-patch}"
PY="${PYTHON:-python}"

if [ "$MODE" != "--no-bump" ]; then
  echo "==> 版本递增（$MODE）"
  "$PY" tools/bump_version.py "$MODE"
else
  echo "==> 跳过版本递增"
fi

echo "==> 静态校验"
"$PY" tools/validate_project.py

echo "==> release 编译"
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
export PATH="C:/Program Files/Huawei/DevEco Studio/tools/node:$PATH"
node "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode=release assembleHap --no-daemon

echo "==> 产物"
ls -l entry/build/default/outputs/default/entry-*.hap
