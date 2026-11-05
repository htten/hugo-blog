# 安全说明（htten.cc.cd）

## 架构与攻击面

- 纯静态站（Hugo → GitHub Pages），**无后端、无数据库、无登录态、无 Cookie**；
- TLS 由 GitHub Pages 自动签发并续期（Let's Encrypt），Pages 已开启 **Enforce HTTPS**（HTTP → 301）；
- CDN 为 GitHub 的 Fastly 边缘节点；
- 主题 `panr/hugo-theme-terminal` v4.2.6 已 **vendor** 进仓库（不引用外部 CDN/字体/统计脚本），因此无第三方追踪、无外部 JS 供应链风险。

## 已实施的安全措施

| 项 | 状态 |
| --- | --- |
| GitHub Actions 依赖锁定 commit SHA | ✅ `deploy.yml` / `build-hugo-fork.yml` |
| main 分支保护（禁 force push / 禁删分支 / 强制线性历史 / 对管理员生效） | ✅ |
| Secret scanning + Push protection | ✅（GitHub 已启用） |
| Dependabot 漏洞告警 + 自动安全修复 | ✅ |
| 仓库历史敏感信息扫描（无凭据/私钥/密钥文件） | ✅ 已扫描 |
| `gh` token 文件权限收紧为 600 | ✅ |
| `.gitattributes` 统一换行符（消除 Windows/WSL 混用的文件模式风险） | ✅ |

> 分支保护**未**强制 PR 与 required status checks：写文章需要直接 push 到 main。
> 如需更严格，可用 PR 流程并把 `build` job 加为 required check（届时直接 push 会被拒绝）。

## 残余风险与待办

1. **www 证书**：CNAME 已生效，但 GitHub 尚未为 `www.htten.cc.cd` 签发证书（当前返回默认 `*.github.io` 证书，浏览器会告警）。等待自动签发（通常 30~60 分钟，最长 24h）；若长期不签，删除 www 的 CNAME 记录，只保留 apex。
2. **缺少自定义安全响应头**：GitHub Pages 不支持配置 HSTS / CSP / X-Frame-Options / X-Content-Type-Options。需要时用 Cloudflare 免费代理前置，或改为自建 nginx（参考 `deploy/nginx.conf`）。
3. **域名续费风险**：`htten.cc.cd` 为 DNSHE 免费域名。若过期被他人重注册，现有 A 记录仍指向 GitHub Pages，将形成「悬空 DNS → 子域接管」。务必开启自动续费并设置到期提醒。
4. **账号 2FA**：未检测到已启用。建议立即在 GitHub 开启 2FA 并保存恢复码——账号失陷等于域名与全部仓库失陷。
5. **凭据卫生**：本地 `D:\phpblog\.db_credentials`、`D:\dsh\.env`（微云 Key）含明文口令/密钥，**不要复制进任何仓库**；`gh` 的 OAuth token 权限为 repo+workflow，泄露即可推全部仓库，建议定期 `gh auth refresh` 轮换。
6. **构建链**：`deploy.yml` 从 GitHub Releases 下载固定版本 `hugo_extended_0.154.5_linux-amd64.deb`，可进一步增加 sha256 校验。

## 应急操作

```bash
# 查看站点与证书
openssl s_client -connect htten.cc.cd:443 -servername htten.cc.cd </dev/null | openssl x509 -noout -subject -dates

# 本地发布（WSL）
bash deploy/deploy-wsl.sh

# 轮换 gh 凭据
gh auth refresh -h github.com -s repo,workflow
```
