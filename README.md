# 博客（Hugo 静态站）

从原自研 PHP 博客迁移到 Hugo 静态站。

**样式 = 原 PHP 博客的 Hallmark·Editorial 设计**：暖纸色底（oklch 97%）、琥珀强调色（oklch 55% .18 35）、衬线大标题、单栏正文 + 右侧 280px 侧栏、发丝级分隔线、卡片淡入动画。CSS 沿用原 PHP 博客的样式表（已并入 `static/css/style.css` 并追加 Hugo 扩展），模板为本站自写（`layouts/`），**不依赖任何第三方主题**。

- 站点名：我的博客
- 域名：`https://htten.cc.cd/`（GitHub Pages + 自建 nginx 双轨）
- 原 PHP 版本已归档（含部署文档与数据库导出）

## 目录

| 路径 | 说明 |
| --- | --- |
| `content/posts/` | 文章（Markdown，front matter 用 `title` / `date` / `description` / `categories` / `tags`） |
| `layouts/` | 覆盖主题的模板（首页、文章列表） |
| `static/css/style.css` | 全站样式（复刻 PHP 博客，追加表格/目录/归档列表等 Hugo 扩展） |
| `layouts/_default/baseof.html` | 页面骨架：header / main / footer |
| `layouts/_default/list.html` | 首页与列表页（Hero + 文章卡片 + 分页） |
| `layouts/_default/single.html` | 文章页（标题 + 正文 + 标签 + 上一篇/下一篇） |
| `layouts/_default/terms.html` | 分类/标签总览页 |
| `layouts/partials/` | header / footer / sidebar / post-card / pagination |
| `static/uploads/` | 从 PHP 博客迁移的图片 |
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

- **不要在 `content/categories/`、`content/tags/` 下放 term 页面**：Hugo 会把 taxonomy 收集清空（实测 `site.Taxonomies` 变成 0 项，侧栏全空）。当前做法是**从文章 front matter 直接聚合分类/标签**，保留原始大小写（`AI 工程`、`LLM`、`ReAct`），链接用 `lower (urlize)` 与 Hugo 的小写 term 路径对齐。
- **CSS 动画会影响截图**：`.post-card` 有 `fadeUp` 动画，headless 截图需加 `--virtual-time-budget=4000`，否则拍到 opacity 0 的空白。

## 迁移内容

- `content/posts/hello-world.md` — 原 Hugo 站首篇
- `content/posts/welcome-to-my-blog.md` — 从 PHP 博客 `posts` 表导入的首篇文章
- `static/uploads/6ab77dda13c13.png` — 原 PHP 博客首图


