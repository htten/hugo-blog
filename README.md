# 博客（Hugo 静态站）

从原自研 PHP 博客迁移到 Hugo 静态站。

**主题 = `themes/blog/`**：以 `hugo new theme blog` 官方脚手架为骨架、自行重写样式与模板的定制主题（全屏铺满、正文列居中、导航置于右侧边栏、支持明暗切换），非第三方主题。导航菜单在 `hugo.toml` 的 `[menus]` 中配置。

- 站点名：HTTEN 的博客
- 域名：`https://htten.cc.cd/`（GitHub Pages + 自建 nginx 双轨）
- 原 PHP 版本已归档（含部署文档与数据库导出）

## 目录

| 路径 | 说明 |
| --- | --- |
| `content/posts/` | 文章（Markdown，front matter 用 `title` / `date` / `description` / `categories` / `tags`） |
| `themes/blog/` | 定制主题（基于 `hugo new theme blog` 脚手架重写）：`layouts/`、`assets/css/main.css`（约 660 行）、`assets/js/main.js`、`static/favicon.ico` |
| `themes/blog/layouts/baseof.html` | 页面骨架：header / 主体（正文 + 右侧边栏）/ footer |
| `themes/blog/layouts/home.html` | 首页（站点标题 + 文章列表） |
| `themes/blog/layouts/page.html` | 单页（标题 + 日期 + 正文 + 标签） |
| `themes/blog/layouts/section.html` | 列表页（如 `/posts/`） |
| `themes/blog/layouts/taxonomy.html`、`term.html` | 分类/标签总览与词条页 |
| `themes/blog/layouts/_partials/` | head / head/css / head/js / header / footer / menu / terms / pagination |
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
- **中文摘要必须手动截断**：Hugo 按空白分词统计 `summaryLength`，中文没空格 → 整篇算 1 个词，`.Summary` 会返回全文（首页会爆炸）。主题模板已用 `replaceRE` + `plainify` + `truncate 220` 兜底；要精确控制可在文章里加 `<!--more-->`。
- **主题样式已定制**：`assets/css/main.css` 含设计变量（`--contentw:1200px`）、明暗双主题（`<html data-theme>` + localStorage）、吸顶磨砂头部、文章卡片、代码块/表格/TOC 排版、响应式与 `prefers-reduced-motion` 适配。
- **锚点偏移**：`assets/js/main.js` 会把吸顶头部的实际高度写入 `--header-h`，供 `scroll-margin-top` 使用；改头部结构后无需手调数值。脚本在 `<head>` 执行时 DOM 尚未就绪，`syncHeaderH()` 必须等 `DOMContentLoaded`。
- **右侧边栏**：导航从页头移到 `baseof.html` 的 `.site-sidebar`（`.site-body` 内的 flex 右侧），sticky 停在 `--header-h`；≤900px 时改为顶部横向导航。
- **全屏铺满**：`.site` 不再限制最大宽度（原 `--maxw` 已删除），正文列由 `.site-main` 的 `flex: 0 1 var(--contentw)`（1200px）约束，正文 + 侧边栏整组在屏内居中；页头/页脚内容同样限制在 `--contentw`。改宽度只需调 `--contentw`。
- **列表页头部靠左**：`.page-header`（`/posts/`、`/tags/` 及各 term 页）不设 `text-align`，与 `.post-header`（`/about/`、文章详情）一致靠左；首页 `.hero` 仍居中。

## 每日自动发文

- **触发**：DSH 桌面端每天 09:00（Asia/Shanghai）定时提醒，自动写稿并发布到 https://htten.cc.cd/。
- **选题库**：`scripts/topic-queue.md`（42 个选题，覆盖 AI 应用 / 开发者工具 / 生产力哲学，按顺序发布）。
- **发布手册**：`scripts/daily-publish.md`（前置检查 → 选题 → 事实核查 → 写作 → 本地校验 → push → 线上验证 → 更新队列）。
- **本地校验**：`scripts/verify-post.sh <slug>`（front matter / 日期 / 正文 ≥300 行 / 标题唯一 / WSL Hugo 0.169.0 构建 / 内部链接）。
- **依赖**：DSH Desktop 保持运行；WSL 里安装 Hugo 0.169.0（`~/.local/bin/hugo-0.169.0`，非 extended 即可，本站无 SCSS/WebP）；Git SSH 推送权限。

### 提醒的会话绑定与失效风险（重要）

DSH 定时提醒**绑定创建它的那个会话**，以宿主任久任务存在
`%APPDATA%\dsh-desktop\harness\storages\schedule.json`（domain `schedule` v1 / 表 `tasks`）。宿主重启不丢，但：

- **归档会话 = 删除提醒**。归档仍有活动提醒的会话会被宿主拒绝；一旦选择「停止活动任务」完成归档，该会话的**全部**活动提醒被删除，取消归档也不会恢复。2026-11-08～11-11 连续 4 天没发文，就是因为承载提醒的会话 `session-c7300dc1-8352-44dd-97ed-51ee83a9adc4` 被归档。
- **宿主必须运行**。09:00 时 DSH Desktop 未启动就不会触发；宿主重启后只补发**最近一次**错过的时点，所以当天稍晚打开仍会补发当天那篇。
- **当前任务**：id `schedule-9c9b761c-fb4d-40fb-aba0-14abc505a37c`，daily 09:00:00 `Asia/Shanghai`，会话 `session-3578832c-21c1-4fff-81ec-af332bc307d7`。
- **恢复办法**：在任意会话里执行 `schedule_create`（daily 09:00 / Asia/Shanghai，prompt指向本节流程），或在 GUI「自动化任务」里重建；重建后核对 `schedule_list` 与 `schedule.json`。
- **避免复发**：不要归档承载提醒的会话（GUI 置顶不能阻止归档，归档会同时清掉置顶）。

### 漏发看门狗（Windows 计划任务）

每日 09:40 由 Windows 计划任务 `BlogDailyWatchdog` 兜底检查（比 09:00 的 DSH 提醒晚 40 分钟，留出写稿 + 构建 + 部署时间）：

- **脚本**：`scripts/watchdog.ps1`（退出码 0 = 当天已发文；1 = 缺失并已告警）。
- **检查项**：① `content/posts/` 是否存在 `date: <今天(Asia/Shanghai)>` 的文章；② `schedule.json` 里的每日提醒是否仍为 `active`。
- **动作**：缺失时尝试拉起 `D:\Program Files\DSH Desktop\DSH Desktop.exe`（宿主启动后会补发最近一次错过的提醒时点），并弹出 Windows 气球告警；全程写日志 `logs/watchdog.log`。
- **注册方式**：`Register-ScheduledTask`，daily 09:40，`-StartWhenAvailable`（机器关机时开机后补跑），`LogonType Interactive`。
- **手动验证**：`powershell -File scripts/watchdog.ps1 -TestDate 2026-11-10`（强制按指定日期走告警路径）。

> 看门狗只能发现并告警，不能自己写稿。如果提醒已被归档删除，需要按上一节的「恢复办法」重建。

## 内容

- `content/posts/ai-agent-engineering-reliability.md`
- `content/posts/llm-internals-and-inference-engine.md`
- `content/posts/rag-engineering-retrieval-rerank-eval.md`
- `content/posts/context-engineering-for-llm-apps.md`
- `content/posts/llm-finetuning-practice-lora-qlora.md`
- `content/posts/multimodal-llm-applications-vlm.md`
- `content/posts/ai-coding-assistant-architecture.md`
- `content/about.md`
