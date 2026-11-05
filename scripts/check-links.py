#!/usr/bin/env python3
"""检查构建产物内部链接是否都指向存在的文件（防止 taxonomy/大小写路径 404）。"""
import os, re, sys, urllib.parse

PUB = sys.argv[1] if len(sys.argv) > 1 else "public"
base = os.path.abspath(PUB)

pages = []
for root, _, files in os.walk(base):
    for f in files:
        if f.endswith(".html"):
            pages.append(os.path.join(root, f))

bad = []
checked = 0
for p in pages:
    html = open(p, encoding="utf-8", errors="ignore").read()
    for m in re.finditer(r'(?:href|src)=(?:"([^"]+)"|([^\s>]+))', html):
        link = m.group(1) or m.group(2)
        if link.startswith(("http://", "https://", "//", "mailto:", "#", "data:")):
            continue
        path = urllib.parse.unquote(urllib.parse.urlparse(link).path)
        if not path:
            continue
        checked += 1
        target = os.path.normpath(os.path.join(base, path.lstrip("/")))
        ok = os.path.isfile(target) or os.path.isfile(os.path.join(target, "index.html"))
        if not ok:
            bad.append((os.path.relpath(p, base), link))

print(f"检查 {len(pages)} 个页面，{checked} 条内部链接")
if bad:
    print(f"❌ 失效链接 {len(bad)} 条：")
    for src, link in sorted(set(bad))[:40]:
        print(f"   {src}  ->  {link}")
    sys.exit(1)
print("✅ 全部内部链接有效")
