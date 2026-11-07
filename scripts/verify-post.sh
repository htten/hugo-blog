#!/usr/bin/env bash
# 发布前本地校验：front matter / 日期 / 行数 / 标题唯一 / Hugo 构建 / 内部链接
# 用法: bash scripts/verify-post.sh <slug>
set -euo pipefail

SLUG="${1:?用法: verify-post.sh <slug>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILE="content/posts/${SLUG}.md"
[ -f "$FILE" ] || { echo "❌ 文件不存在: $FILE"; exit 1; }

# front matter 起始
head -1 "$FILE" | grep -qx -- '---' || { echo "❌ front matter 起始 --- 缺失"; exit 1; }
for key in title description date categories tags; do
  grep -q "^$key:" "$FILE" || { echo "❌ front matter 缺 $key"; exit 1; }
done

DATE="$(grep '^date:' "$FILE" | head -1 | sed 's/^date: *//; s/"//g')"
TODAY="$(TZ=Asia/Shanghai date +%F)"
[ "$DATE" = "$TODAY" ] || { echo "❌ date=$DATE 不是今天 $TODAY"; exit 1; }

# 正文行数（不含 front matter）
LINES="$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{n++} END{print n+0}' "$FILE")"
[ "$LINES" -ge 300 ] || { echo "❌ 正文仅 $LINES 行（要求 ≥300）"; exit 1; }

# 标题唯一
TITLE_VAL="$(grep '^title:' "$FILE" | head -1 | sed 's/^title: *//')"
for f in content/posts/*.md; do
  [ "$f" = "$FILE" ] && continue
  if grep -qF "title: $TITLE_VAL" "$f"; then
    echo "❌ 标题重复: $TITLE_VAL（与 $f 冲突）"; exit 1
  fi
done

# WSL Hugo 构建（0.169.0，与 CI 同版本；CI 用 extended，本站无 SCSS/WebP 需求）
if [ -n "${HUGO_BIN:-}" ]; then
  HUGO_CMD="$HUGO_BIN"
elif wsl -e bash -lc '[ -x $HOME/.local/bin/hugo-0.169.0 ]'; then
  HUGO_CMD='$HOME/.local/bin/hugo-0.169.0'
elif wsl -e bash -lc 'command -v hugo' >/dev/null 2>&1; then
  echo "⚠️ WSL 里没有 hugo-0.169.0，回退到 wsl 默认 hugo"
  HUGO_CMD="hugo"
else
  echo "❌ WSL 里没有可用的 hugo"; exit 1
fi
OUT="$(wsl -e bash -lc 'mktemp -d')"
trap 'wsl -e bash -lc "rm -rf $OUT"' EXIT

if ! wsl -e bash -lc "cd /mnt/d/blog && $HUGO_CMD --minify --gc -b https://htten.cc.cd/ --destination $OUT" 2>&1; then
  echo "❌ Hugo 构建失败"; exit 1
fi
if ! wsl -e bash -lc "cd /mnt/d/blog && python3 scripts/check-links.py $OUT" 2>&1; then
  echo "❌ 内部链接检查失败"; exit 1
fi

echo "✅ $SLUG 校验通过：$LINES 行，date=$DATE"
