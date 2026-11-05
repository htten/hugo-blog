#!/usr/bin/env bash
# 一键把本地仓库发布到 GitHub：创建远端仓库（可选）+ fork hugo + 推送本仓库。
#
# 依赖：gh 已登录（gh auth login），或设置 GITHUB_TOKEN
# 网络：pull 走 gh-proxy 镜像，push 走 SSH（git@github.com）
#
# 用法：bash scripts/publish-github.sh <github-user> [repo-name]
set -euo pipefail

USER_="${1:?用法: publish-github.sh <github-user> [repo-name]}"
REPO="${2:-blog}"
SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUGO_DIR="${HUGO_DIR:-/mnt/d/src/hugo}"
MIRROR="https://gh-proxy.com/https://github.com"

command -v gh >/dev/null || { echo "缺少 gh CLI" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh 未登录：请执行 gh auth login" >&2; exit 3; }

echo "==> 1/4 创建远端仓库 $USER_/$REPO"
gh repo view "$USER_/$REPO" >/dev/null 2>&1 || {
  gh repo create "$USER_/$REPO" --public --description "Hugo 博客（terminal 主题）" --source "$SITE_DIR" --remote origin || \
  gh repo create "$USER_/$REPO" --public --description "Hugo 博客（terminal 主题）"
}
cd "$SITE_DIR"
git remote add origin "git@github.com:$USER_/$REPO.git" 2>/dev/null || git remote set-url origin "git@github.com:$USER_/$REPO.git"
git remote -v

echo "==> 2/4 fork gohugoio/hugo 到 $USER_/hugo"
gh repo fork gohugoio/hugo --clone=false --remote=false 2>/dev/null || echo "（fork 可能已存在，跳过）"
gh repo view "$USER_/hugo" >/dev/null 2>&1 && echo "fork 就绪：$USER_/hugo"

echo "==> 3/4 推送站点仓库"
cd "$SITE_DIR"
git push -u origin HEAD:main

echo "==> 4/4 推送 hugo fork 分支"
if [ -d "$HUGO_DIR/.git" ]; then
  cd "$HUGO_DIR"
  git remote add fork "git@github.com:$USER_/hugo.git" 2>/dev/null || git remote set-url fork "git@github.com:$USER_/hugo.git"
  git checkout -B main 2>/dev/null || true
  git push -u fork main
else
  echo "跳过：未找到 hugo 源码目录 $HUGO_DIR"
fi

echo "==> 完成后："
echo "  1) 仓库 Settings → Pages → Source 选 GitHub Actions"
echo "  2) 域名 blog.htten.cc.cd 在 DNS 加 CNAME 指向 <user>.github.io"
echo "  3) 本地自部署：bash deploy/deploy-wsl.sh"
