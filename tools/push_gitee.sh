#!/usr/bin/env bash
# 推送本仓库到 Gitee（公开仓库）。
#
# 用法：
#   bash tools/push_gitee.sh                 # 默认仓库名 qts-nas-harmony
#   bash tools/push_gitee.sh my-repo-name    # 指定仓库名
#
# 安全说明：
#   - 脚本不读取、不保存、不回显任何密码或令牌；
#   - 推送时由 git 自己提示输入 Gitee 账号与密码 / 私人令牌；
#   - 请先在 Gitee 网页创建同名**公开**仓库（不要勾选初始化 README）。
set -euo pipefail

REPO_NAME="${1:-qts-nas-harmony}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

printf 'Gitee 用户名: '
read -r GITEE_USER
if [ -z "${GITEE_USER}" ]; then
  echo "用户名不能为空" >&2
  exit 1
fi

URL="https://gitee.com/${GITEE_USER}/${REPO_NAME}.git"
git remote remove origin 2>/dev/null || true
git remote add origin "${URL}"

echo "远端   : ${URL}"
echo "分支   : ${BRANCH}"
echo "接下来 git 会提示输入账号与密码/私人令牌，输入内容不会写入仓库。"
git push -u origin "${BRANCH}"
