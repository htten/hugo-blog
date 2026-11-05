#!/usr/bin/env bash
# 在 WSL 上构建本仓库的 Hugo 站点并发布到 /var/www/blog/public，然后 reload nginx。
# 用法：bash deploy/deploy-wsl.sh [baseURL]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB_DIR="${PUB_DIR:-/var/www/blog/public}"
BASE_URL="${1:-https://htten.cc.cd/}"

command -v hugo >/dev/null || { echo "hugo 未安装" >&2; exit 1; }

echo "==> 构建 Hugo 站点 (baseURL=$BASE_URL)"
cd "$REPO_DIR"
rm -rf public resources
hugo --minify --gc -b "$BASE_URL"

echo "==> 发布到 $PUB_DIR"
sudo mkdir -p "$PUB_DIR"
sudo rsync -a --delete public/ "$PUB_DIR/"

echo "==> reload nginx"
sudo nginx -t
sudo systemctl reload nginx

echo "==> 完成：http://127.0.0.1/  （站点名 htten.cc.cd）"
