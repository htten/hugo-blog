# 安全策略（Security Policy）

## 项目概述

本站是纯静态博客：Hugo 构建，GitHub Pages 托管。**无后端服务、无数据库、无用户账户、无 Cookie、无登录态、无表单与评论系统**，不采集任何访客数据。

因此不存在服务端注入、越权、会话劫持一类攻击面；可报告的问题主要集中在静态资源引用与构建链。

## 支持版本

| 版本 | 是否接受报告 |
| --- | --- |
| `main` 分支（当前生产版本） | ✅ |
| 历史提交、旧构建产物 | ❌ |

## 如何报告漏洞

优先使用 **GitHub 私有漏洞报告（Private Vulnerability Reporting）**：

仓库页面 → **Security** → **Advisories** → **Report a vulnerability**。

该功能未开启时，请发送邮件至 `htten@users.noreply.github.com`，标题注明 `[security]`。

**请勿**开公开 issue，或在公开渠道讨论漏洞细节，直到维护者确认修复并发布。

报告建议包含：

- 问题描述与影响范围
- 复现步骤（含具体 URL / 文件路径）
- 可选的修复建议

## 范围

**在范围内**

- 构建链与 CI 工作流的供应链风险（依赖版本、Action、构建脚本）
- 站点引用的外部静态资源
- 内容渲染导致的 XSS / 注入（Markdown、短代码、模板）
- HTTPS / 证书配置问题

**不在范围内**

- GitHub Pages 平台自身（边缘节点、证书签发服务）
- 第三方 DNS 与域名注册商
- 无实际影响的理论性猜测
- 社会工程、物理安全

## 已实施的安全措施

| 项 | 状态 |
| --- | --- |
| CI 依赖锁定到 commit SHA | ✅ |
| 分支保护（禁 force push、禁删分支） | ✅ |
| Secret scanning + Push protection | ✅ |
| Dependabot 漏洞告警 | ✅ |
| 仓库历史敏感信息扫描 | ✅ |
| 全站强制 HTTPS | ✅ |

## 处理时效

| 阶段 | 时限 |
| --- | --- |
| 确认收到 | 3 个工作日 |
| 初步评估 | 7 个工作日 |
| 修复或给出结论 | 视严重程度，通常 30 天内 |

## 已知边界

- GitHub Pages 不支持自定义安全响应头（HSTS / CSP / X-Frame-Options 等）。如需更严格的头策略，需改用 Cloudflare 前置或自建反向代理。
- 站点无用户数据，因此不存在数据泄露类风险。
