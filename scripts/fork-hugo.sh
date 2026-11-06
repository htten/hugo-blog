#!/usr/bin/env bash
# 从 GitHub fork gohugoio/hugo 并在本地编译（extended 版本，支持 SCSS）。
#
# 前提：已配置 GitHub 凭据（gh auth login 或 ~/.git-credentials）。
# 网络：默认直连 github.com；如需镜像加速，请设置 GITHUB_UPSTREAM 或在本地 git 配置 insteadOf
#
# 用法：bash scripts/fork-hugo.sh [目标目录]
set -euo pipefail

SRC_REPO="gohugoio/hugo"
UPSTREAM="${GITHUB_UPSTREAM:-https://github.com/${SRC_REPO}.git}"
WORKDIR="${1:-$HOME/src/hugo}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"

echo "==> 克隆 $SRC_REPO -> $WORKDIR"
mkdir -p "$(dirname "$WORKDIR")"
if [ ! -d "$WORKDIR/.git" ]; then
  git clone --filter=blob:none "$UPSTREAM" "$WORKDIR"
fi

cd "$WORKDIR"
git remote set-url origin "$UPSTREAM"

echo "==> 创建 fork 并推送"
if ! gh auth status >/dev/null 2>&1; then
  echo "gh 未登录：请先执行 gh auth login（或设置 GITHUB_TOKEN）" >&2
  exit 3
fi
FORK_REPO="$(gh repo fork "$SRC_REPO" --clone=false --remote=false 2>/dev/null || true)"
if [ -z "$FORK_REPO" ]; then
  echo "已存在 fork，跳过创建：$(gh repo list --limit 100 --json nameWithOwner -q ".[] | select(.nameWithOwner | startswith(\"$(gh api user -q .login)/\") and contains(\"hugo\")) | .nameWithOwner" | head -1)" >&2
  FORK_REPO="$(gh api user -q .login)/hugo"
fi
echo "fork: $FORK_REPO"
git remote add fork "https://github.com/${FORK_REPO}.git" 2>/dev/null || \
  git remote set-url fork "https://github.com/${FORK_REPO}.git"

echo "==> 编译 extended 版本 (go build)"
git fetch --tags --depth=1 origin
mkdir -p "$BIN_DIR"
go build -tags extended -o "$BIN_DIR/hugo" .
"$BIN_DIR/hugo" version
echo "二进制：$BIN_DIR/hugo （站点可用 HUGO_BIN 指向它）"
