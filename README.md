# 博客（Hugo 静态站）

从原自研 PHP 博客迁移到 Hugo 静态站，使用 [panr/hugo-theme-terminal](https://github.com/panr/hugo-theme-terminal) v4.2.6 主题（已 vendor 到 `themes/terminal`，无需 submodule）。

- 站点名：我的博客
- 域名：`https://htten.cc.cd/`（GitHub Pages + 自建 nginx 双轨）
- 原 PHP 版本已归档在 `D:\phpblog`（含 `DEPLOY.md`、数据库导出 `blog-export-20261002/blog.sql`）

## 目录

| 路径 | 说明 |
| --- | --- |
| `content/posts/` | 文章（Markdown，front matter 用 `title` / `date` / `slug`） |
| `layouts/` | 覆盖主题的模板（首页、文章列表） |
| `themes/terminal/` | 已 vendor 的终端主题 |
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

## 自部署（WSL，nginx）

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

## DNS 配置（DNSPod / DNSHE）

| 类型 | 主机记录 | 记录值 | 状态 |
| --- | --- | --- | --- |
| A | `@` | `185.199.108.153` | ✅ 已生效 |
| A | `@` | `185.199.109.153` | ✅ 已生效 |
| A | `@` | `185.199.110.153` | ✅ 已生效 |
| A | `@` | `185.199.111.153` | ✅ 已生效 |
| CNAME | `www` | `htten.github.io` | 可选（当前 www 仍指向旧地址 171.107.33.243） |

GitHub Pages 仓库设置中 Pages → Custom domain = `htten.cc.cd`，HTTPS 已由 GitHub 自动签发。

## 网络说明

本机（WSL 与 Windows）直连 `github.com` 会超时，Git 操作需走镜像：

```bash
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
```

`api.github.com` 可直连，`gh` CLI 的 API 操作不受影响。

## 迁移内容

- `content/posts/hello-world.md` — 原 Hugo 站首篇
- `content/posts/welcome-to-my-blog.md` — 从 PHP 博客 `posts` 表导入的首篇文章
- `static/uploads/6ab77dda13c13.png` — 原 PHP 博客首图
