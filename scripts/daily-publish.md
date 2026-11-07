# 每日自动发文流程（Daily Publish Runbook）

目标：每天 09:00 由 DSH 定时提醒触发，自动产出一篇深度技术长文并发布到 https://htten.cc.cd/。
选题范围：AI 应用、开发者工具、生产力哲学。选题库：`scripts/topic-queue.md`。
前置依赖：DSH Desktop 保持运行；WSL 里有 Hugo 0.169.0（`~/.local/bin/hugo-0.169.0`）；Git SSH 推送权限正常。

## 0. 前置检查（任一不满足则停止并报告，不要继续）

- `git -C /d/blog status --porcelain` 输出必须为空。有未提交改动 → 停止，不要提交别人的改动。
- `git -C /d/blog pull --ff-only` 成功。冲突或需要合并 → 停止并报告。
- 确认当前日期（Asia/Shanghai）。
- 检查 `content/posts/` 是否已存在 `date: <今天>` 的文章。已存在 → 跳过发布，只汇报。

## 1. 选题

- 读取 `scripts/topic-queue.md`，选第一条 `status: pending`。
- 检查与 `content/posts/*.md` 已有标题/主题是否重叠（已有两篇：AI Agent 工程化、大模型原理与推理引擎）。
- 明显重叠或已被占用 → 顺延到下一条 pending。
- 若队列全部发布完 → 停下，向用户申请补充选题，不要自行编造超出定位的题目。

## 2. 研究与事实核查

- 对版本号、API 签名、性能数字、论文/产品结论，用 `web_search` / `web_fetch` 核对官方文档或论文。
- 无法确认的事实：删除，或在文中明确标注「待验证」。禁止编造版本号、benchmark 数字、URL。
- 引用了外部资料时，把来源列在文末「参考资料」小节（Markdown 链接）。

## 3. 写作

- 文件：`content/posts/<slug>.md`。front matter：

```yaml
---
title: "中文标题"
description: "80-150 字摘要，说明文章解决什么问题"
date: YYYY-MM-DD
categories: ["AI 应用"]
tags: ["关键词1", "关键词2"]
---
```

- 风格与现有文章一致：引言用问题清单 → `## 一、二、…` 分章 → 每章有代码/对比表/图示 → `## 小结` 压缩成几句话。
- 深度长文：正文 ≥ 300 行（不含 front matter）。
- 代码块必须可运行，或明确标注为伪代码；不贴无法验证的 API。
- 中文摘要依赖主题模板截断；如需精确控制，在摘要处加 `<!--more-->`。

## 4. 本地校验

```bash
bash scripts/verify-post.sh <slug>
```

校验 front matter、日期、行数、标题唯一性、WSL Hugo 0.169.0 构建、内部链接。
失败必须修复后重跑，最多 3 次；仍失败 → 停止，不发布，报告原因。

## 5. 发布

```bash
cd /d/blog
git add content/posts/<slug>.md scripts/topic-queue.md
git commit -m "post: <标题>"
git push origin main
```

- 只提交本次新增文件与 `scripts/topic-queue.md`；禁止 `git add -A`。

## 6. 线上验证

- 等待 GitHub Actions 完成：`curl -s "https://api.github.com/repos/htten/hugo-blog/actions/runs?per_page=5"` 查看最新 run 的 `status` / `conclusion`。
- 成功：`web_fetch https://htten.cc.cd/posts/<slug>/` 确认 200 且标题正确。
- 失败：`git revert HEAD` → `git push origin main`；把 `scripts/topic-queue.md` 中该选题标为 `failed` 并写原因，单独 commit + push；报告。

## 7. 更新选题库

- 把该选题 `status` 改为 `published`，填 `slug` 与 `date`；同步更新文件底部「已发布」表。
- 与发布同 commit，或追加 `docs: 更新选题库 <slug>`。

## 8. 汇报

- 标题、正文行数、核心结论 3 条、线上链接、GitHub Actions 状态、下一条选题。

## 安全边界

- 不 push 与发文无关的改动。
- 不修改 `themes/`、`hugo.toml`、CI 配置，除非用户明确要求。
- 不删除已有文章。
- 失败优先 revert，不要在失败 commit 上继续堆提交。
