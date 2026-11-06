# 博客（Hugo 静态站）

从原自研 PHP 博客迁移到 Hugo 静态站。

**主题 = `themes/blog/`**：由 `hugo new theme blog` 生成的 Hugo 官方脚手架主题（含 `layouts/` 模板与 `assets/css/main.css` 极简样式），非第三方主题。导航菜单在 `hugo.toml` 的 `[menus]` 中配置。

- 站点名：HTTEN 的博客
- 域名：`https://htten.cc.cd/`（GitHub Pages + 自建 nginx 双轨）
- 原 PHP 版本已归档（含部署文档与数据库导出）

## 目录

| 路径 | 说明 |
| --- | --- |
| `content/posts/` | 文章（Markdown，front matter 用 `title` / `date` / `description` / `categories` / `tags`） |
| `themes/blog/` | Hugo 官方脚手架主题（`hugo new theme blog` 生成）：`layouts/`、`assets/css/main.css`、`assets/js/main.js`、`static/favicon.ico` |
| `themes/blog/layouts/baseof.html` | 页面骨架：header / main / footer |
| `themes/blog/layouts/home.html` | 首页（站点标题 + 文章列表） |
| `themes/blog/layouts/page.html` | 单页（标题 + 日期 + 正文 + 标签） |
| `themes/blog/layouts/section.html` | 列表页（如 `/posts/`） |
| `themes/blog/layouts/taxonomy.html`、`term.html` | 分类/标签总览与词条页 |
| `themes/blog/layouts/_partials/` | head / header / footer / menu / terms |
| `static/` | CNAME、robots.txt |
| `deploy/nginx.conf` | 自部署用 nginx 站点配置 |
| `deploy/deploy-wsl.sh` | WSL 上构建 + 发布到 `/var/www/blog/public` + reload nginx |
| `scripts/fork-hugo.sh` | fork gohugoio/hugo 并本地编译 extended 版 |
| `.github/workflows/deploy.yml` | 构建并发布到 GitHub Pages |
| `.github/workflows/build-hugo-fork.yml` | 从自己的 hugo fork 编译二进制 |

## 本地构建

```bash
hugo --minify --gc -b https://htten.cc.cd/
hugo server -D        # 本地预览 http://localhost:1313/
```

## 部署方案（已定：A = GitHub Pages）

**生产环境走 GitHub Pages**（A 记录 → GitHub Pages IP，Let's Encrypt 证书自动签发与续期，Pages 已开启 Enforce HTTPS，HTTP 自动 301 到 HTTPS）。

仓库 `htten/hugo-blog` → push `main` → Actions 自动构建并发布，无需任何服务器操作。

自部署（WSL nginx）保留为**备用/本机预览**手段：

## 自部署（WSL，nginx，备用）

```bash
sudo cp deploy/nginx.conf /etc/nginx/sites-available/blog-hugo
sudo ln -sf /etc/nginx/sites-available/blog-hugo /etc/nginx/sites-enabled/blog-hugo
sudo nginx -t && sudo systemctl reload nginx

bash deploy/deploy-wsl.sh
```

当前 WSL 上的 nginx 站点 `blog-hugo` 已在监听 80 端口、根目录 `/var/www/blog/public`。

## GitHub Pages 部署

1. 仓库 Settings → Pages → Source 选 **GitHub Actions**。
2. 在 `.github/workflows/deploy.yml` 里确认 `BASEURL` 与实际域名一致。
3. 推送 `master`/`main` 即自动构建发布。

## DNS 配置

| 类型 | 主机记录 | 记录值 | 状态 |
| --- | --- | --- | --- |
| A | `@` | `185.199.108.153` | ✅ 已生效 |
| A | `@` | `185.199.109.153` | ✅ 已生效 |
| A | `@` | `185.199.110.153` | ✅ 已生效 |
| A | `@` | `185.199.111.153` | ✅ 已生效 |
| CNAME | `www` | `htten.github.io` | 可选 |

GitHub Pages 仓库设置中 Pages → Custom domain = `htten.cc.cd`，HTTPS 已由 GitHub 自动签发。

## 网络说明

部分网络环境下 `github.com` 直连可能不稳定，Git 操作可按需配置代理或镜像；`api.github.com` 通常可直连，`gh` CLI 的 API 操作不受影响。

## 踩坑记录

- **不要在 `content/categories/`、`content/tags/` 下放 term 页面**：Hugo 会把 taxonomy 收集清空（实测 `site.Taxonomies` 变成 0 项）。分类/标签直接从文章 front matter 聚合。
- **首页会列出正文全文**：`home.html` 用 `{{ .Summary }}`，文章没有 `<!--more-->` 摘要分隔符时 `.Summary` 等于全文，首页会很长。需要短摘要就在文章里加 `<!--more-->`。
- **主题样式极简**：`hugo new theme` 生成的 `assets/css/main.css` 只有基础排版（max-width 768px、无配色体系），需要时自行扩展。

## 内容

- `content/posts/ai-agent-engineering-reliability.md`
- `content/posts/llm-internals-and-inference-engine.md`
- `content/about.md`
