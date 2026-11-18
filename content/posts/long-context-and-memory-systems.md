---
title: "长上下文与记忆系统：RAG、长上下文与分层记忆"
description: "长上下文不是免费扩容：成本、延迟与注意力衰减会同步恶化。本文拆解 lost in the middle 与上下文腐烂的机制，给出上下文工程、压缩与分层记忆（工作、短期、长期）的落地框架，并对比 RAG 与长上下文的取舍、记忆写入检索策略与一致性治理。"
date: 2026-11-08
categories: ["AI 应用"]
tags: ["长上下文", "记忆系统", "RAG", "上下文压缩"]
---

## 引言：上下文窗口变大了，模型却没用得更好

过去一年，几乎所有主流模型的上下文窗口都在往上翻：从 4K、8K，到 128K、1M 甚至更高。但如果你真的把长上下文用在生产里，大概早就遇到过这些问题：

- 上下文从 4K 涨到 128K，任务成功率并没有同步上涨，甚至某些任务反而变差；
- 一次 Agent 调用烧掉几十万输入 token，其中大部分是上一轮已经发过的内容；
- 会话一长，模型开始「忘事」、重复已经说过的话、答非所问；
- 把整个代码库或知识库塞进上下文，指望模型「什么都看到」，结果它连最简单的问题都答错；
- 团队在「全量长上下文」和「RAG 检索」之间二选一，吵不出结论；
- 记忆写进去容易，但过期、冲突、冗余没有任何机制去管。

这些现象的共同根源是：**上下文窗口是「容量」，记忆是「治理」。容量可以靠买，治理只能靠工程。**

窗口从 4K 到 1M，解决的是「放不放得下」；它没有解决「模型能不能用好」「成本能不能承受」「信息会不会过期」这三个问题。前者是硬件参数，后两者是系统设计。把三者混为一谈，是长上下文落地失败的第一原因。

本文只讨论「记忆系统 + 长上下文」这条线，不重复站内已覆盖的内容：RAG 的切分、Embedding、混合检索与重排序细节见《RAG 工程化：从向量检索到重排序与评估》；上下文的结构化输入与前缀缓存见《从提示词工程到上下文工程》；评测体系见《大模型评测体系》。如果你需要选型和评估口径，请直接看那三篇。

## 一、长上下文的三个真实约束

先把「长上下文」拆开。它不是单一变量，而是三个同时变化的约束：成本、延迟、质量衰减。三者都会随输入长度增长而恶化，只是斜率不同。

### 1.1 成本：按量计费的线性增长

API 的计费模型很简单：

```text
单次成本 = 输入 token × 输入单价 + 输出 token × 输出单价
```

长上下文的麻烦在于，**每一轮都要重付一次输入费用**。一个 20 轮的会话，如果每轮都带全量历史，输入 token 总量是轮次的平方级增长，而不是线性。

假设每轮新增 500 token，历史全量携带：

| 轮次 | 第 N 轮输入 token | 累计输入 token |
| --- | --- | --- |
| 1 | 500 | 500 |
| 5 | 2,500 | 7,500 |
| 10 | 5,000 | 27,500 |
| 20 | 10,000 | 105,000 |

20 轮之后，累计输入是单轮的 210 倍。**会话越长，成本增长越快**，这就是为什么「全量历史」方案在 demo 阶段看起来很美，上线后账单打脸。

### 1.2 延迟：prefill 是长上下文的第一道墙

模型生成分为 prefill（处理输入）和 decode（逐 token 输出）两个阶段。输入越长，prefill 越慢，首 token 延迟（TTFT）越高。

标准注意力下，注意力计算量随序列长度接近平方增长；即使换成线性或稀疏注意力，prefill 的常数项和 KV 读写带宽仍然随长度上升。工程上的经验量级是：**128K 上下文的 prefill 通常在秒级**，而 8K 上下文是百毫秒级。具体数值取决于模型、硬件和推理框架，需要实测，不要照抄任何博客数字。

延迟还有第二个来源：**输出长度**。长上下文任务往往要求更长的输出（总结、对比、多跳推理），输出 token 按时间步生成，延迟随输出长度线性增长。

### 1.3 质量：注意力衰减

这是最反直觉的一条：**上下文变长，模型对中间信息的利用率下降**。这不是模型「看不懂」，而是注意力机制在长序列上的分配问题。第二章展开。

### 1.4 三个约束的对照

| 约束 | 随长度变化 | 可观测指标 | 主要缓解手段 | 缓解代价 |
| --- | --- | --- | --- | --- |
| 成本 | 线性（每轮重付） | 单次输入 token、累计 token | 缓存、压缩、分层记忆 | 命中率、信息损失 |
| 延迟 | prefill 超线性 | TTFT、端到端 P95 | 减少输入、稀疏注意力、批处理 | 质量、架构改动 |
| 质量 | 非单调，中间塌陷 | 任务准确率、召回率 | 重排、检索、记忆分层 | 系统复杂度 |

**工程结论：长上下文的第一性问题不是「窗口够不够大」，而是「这一轮真正需要的信息有多少」。** 如果你答不上这个问题，买再大的窗口也是浪费。

## 二、注意力衰减：从 lost in the middle 到上下文腐烂

### 2.1 Lost in the Middle：中间位置的系统性塌陷

Liu 等人在 [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172) 中做了两个任务：多文档问答和键值检索。结论很明确：

- 当相关信息出现在上下文的**开头或结尾**时，性能最好；
- 当相关信息出现在**中间**时，性能显著下降；
- 即使模型明确宣称支持长上下文，这个 U 形曲线依然存在。

这个发现的重要性在于：它不是「模型不够聪明」，而是**位置本身会影响注意力分配**。多文档检索场景中，文档的排列顺序因此变成了一个工程变量——把最可能相关的文档放在两端，比放在中间更好。

### 2.2 RULER：宣称 32K，一半模型撑不住

[RULER](https://arxiv.org/abs/2404.06654) 用合成任务把「上下文长度」和「任务复杂度」解耦，覆盖 13 个任务、17 个长上下文模型。它扩展了经典的 NIAH（大海捞针），加入多跳追踪和聚合类任务。核心结论：

- 在 vanilla NIAH 上，几乎所有模型接近满分；
- 但**所有模型都宣称支持 32K 以上，只有一半能在 32K 长度保持令人满意的性能**；
- 长度增加、任务复杂度增加时，性能大幅下降。

这直接说明：**NIAH 满分不等于长上下文可用**。NIAH 测的是词汇级检索，真实任务要求的是多跳推理、聚合和时间推理。

### 2.3 Context Rot：连简单任务都会退化

Chroma 在 2025 年 7 月发布的 [Context Rot](https://www.trychroma.com/research/context-rot) 报告把这个问题推得更远。他们评估了 18 个模型（含 GPT-4.1、Claude 4、Gemini 2.5、Qwen3），刻意保持任务复杂度不变，只改变输入长度，观察到：

- **即使是非词汇匹配、文本复制这类简单任务，性能也随输入长度持续退化**；
- 干扰项（distractor）的影响是非均匀的，且随长度增加被放大；
-  haystack 的**结构**会影响结果：打乱句子顺序、去掉局部连贯性，反而让模型表现更好；
- 在 LongMemEval 上，「只给相关信息」（约 300 token）比「给全量 113K token」显著更好。

最后一条对工程最有指导意义：**「检索 + 推理」两个任务被塞进一次调用时，模型要同时做两件难事**，而把检索结果先抽出来，模型只需要做推理。

### 2.4 机制解释：哪些是事实，哪些是推测

| 现象 | 证据强度 | 解释 |
| --- | --- | --- |
| 中间位置性能塌陷 | 已确认（多论文复现） | 注意力在长序列上的分配不均 |
| NIAH 满分但真实任务差 | 已确认 | NIAH 只测词汇检索 |
| 简单任务也随长度退化 | 已确认（受控实验） | 上下文结构影响注意力 |
| 训练数据长度分布不足 | 推测 | 预训练语料里长文档占比低 |
| 位置编码外推失效 | 推测 | RoPE 类编码在训练长度外精度下降 |

机制部分请按「推测」对待。工程上不需要等机制解释清楚，只要现象稳定，就可以据此设计系统。

### 2.5 长上下文评测基准对照

| 基准 | 任务形态 | 样本规模 | 测什么 | 主要结论 |
| --- | --- | --- | --- | --- |
| [NIAH](https://github.com/gkamradt/LLMTest_NeedleInAHaystack) | 单针检索 | 可扩展 | 词汇级检索 | 模型普遍接近满分 |
| [RULER](https://arxiv.org/abs/2404.06654) | 13 类合成任务 | 17 模型 | 长度 × 复杂度 | 宣称 32K，一半撑不住 |
| [LongBench](https://arxiv.org/abs/2308.14508) | 21 数据集 6 类 | 8 模型 | 中英双语长文理解 | 平均 6,711 词（英）/ 13,386 字（中） |
| [Context Rot](https://www.trychroma.com/research/context-rot) | 受控简单任务 | 18 模型 | 纯输入长度影响 | 简单任务也退化 |
| [LongMemEval](https://arxiv.org/abs/2410.10813) | 会话记忆问答 | 500 题 | 长期记忆五项能力 | 跨会话记忆准确率下降约 30% |

**工程结论：不要用 NIAH 分数做长上下文选型。** 至少要跑 RULER 这类带复杂度维度的基准，再加一个你自己业务分布的受控测试（固定任务、只变长度）。

## 三、上下文工程与压缩：把上下文当预算管理

### 3.1 先分层，再压缩

上下文工程的核心动作是**分层**：把「稳定不变」的内容和「每轮变化」的内容分开。

```text
┌─────────────────────────────────────────────┐
│ 稳定层：系统提示、工具定义、few-shot 示例      │  ← 每轮完全相同
├─────────────────────────────────────────────┤
│ 半稳定层：用户画像、长期记忆、知识库配置       │  ← 变化慢
├─────────────────────────────────────────────┤
│ 变化层：检索结果、会话历史、工具返回、用户输入  │  ← 每轮不同
└─────────────────────────────────────────────┘
```

这个分层不是美学问题，它直接决定两件事：

1. **缓存命中率**：稳定层越长、越靠前，前缀缓存越容易命中；
2. **注意力效率**：把最相关的内容放在开头和结尾，避开 lost in the middle。

### 3.2 前缀缓存：最便宜的优化

主流平台都提供前缀缓存，机制略有不同：

| 平台 | 机制 | 关键约束 | 备注 |
| --- | --- | --- | --- |
| [OpenAI Prompt Caching](https://platform.openai.com/docs/guides/prompt-caching) | 自动缓存前缀 | 有最小 token 门槛，缓存部分按折扣计费 | 具体门槛与折扣比例以官方文档为准（待验证） |
| [Anthropic Prompt Caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) | 显式 `cache_control` 断点 | 需手动标记缓存边界，有 TTL | 具体倍率以官方文档为准（待验证） |

无论哪家，工程结论都一样：**把稳定内容放前面，把用户消息放最后**。常见的反模式是把时间戳、请求 ID、用户名放进系统提示——这会让每个请求的前缀都不同，缓存直接失效。

一个可落地的自检：随机抽 100 个请求，计算 `cached_tokens / prompt_tokens`。如果低于 50%，先查系统提示里有没有每轮变化的内容。

### 3.3 压缩：有损，但可控

压缩分两类：

| 手段 | 原理 | 压缩比 | 信息损失 | 适用 |
| --- | --- | --- | --- | --- |
| 历史摘要 | 用模型把旧对话总结成一段 | 高 | 有损，细节丢失 | 长会话、多轮 Agent |
| [LLMLingua](https://arxiv.org/abs/2310.05736) | 用小模型做 token 级剪枝 | 报告最高 20× | 有损 | prompt 级压缩 |
| [AutoCompressors](https://arxiv.org/abs/2305.14788) | 把长上下文压成 summary vector（软提示） | 高 | 有损，需微调 | 固定领域、可离线预计算 |
| 检索替代 | 只保留相关片段 | 取决于召回 | 取决于召回质量 | 知识库场景 |

注意：**压缩比越高的方法，越需要评估**。压缩不是无损的，压缩后的任务准确率必须和压缩前对比，否则你只是在用质量换成本。

### 3.4 上下文预算分配：一个可运行的实现

下面是一个纯标准库的预算分配器：给定预算，按优先级保留各块，超出部分从低优先级开始裁剪。真实系统里 token 数应该用 tokenizer 计算，这里用字符数近似。

```python
#!/usr/bin/env python3
"""上下文预算分配：按优先级把有限预算切给各部分。纯标准库实现，可运行。
预算单位是 token 的近似值（按字符数 / 4 估算），生产环境应换成真实 tokenizer。
"""
from dataclasses import dataclass


@dataclass
class Block:
    name: str
    tokens: int
    priority: int          # 数字越小越优先保留
    droppable: bool = True  # 是否允许被裁剪


def allocate(blocks, budget):
    """按 priority 保留，超出预算时从低优先级开始裁 droppable 块。"""
    kept = [b for b in blocks if not b.droppable]
    used = sum(b.tokens for b in kept)
    droppable = sorted([b for b in blocks if b.droppable], key=lambda b: b.priority)
    dropped = []
    for b in droppable:
        if used + b.tokens <= budget:
            kept.append(b)
            used += b.tokens
        else:
            dropped.append(b)
    kept.sort(key=lambda b: blocks.index(b))
    return kept, dropped, used


if __name__ == "__main__":
    blocks = [
        Block("system", 800, 1, droppable=False),
        Block("tools", 3000, 2, droppable=False),
        Block("memory", 1500, 3),
        Block("history", 9000, 4),
        Block("rag", 2500, 5),
        Block("user", 200, 6, droppable=False),
    ]
    kept, dropped, used = allocate(blocks, budget=12000)
    for b in kept:
        print(f"keep   {b.name:8s} {b.tokens:6d}")
    for b in dropped:
        print(f"drop   {b.name:8s} {b.tokens:6d}")
    print(f"used={used} budget=12000")
```

**工程结论：上下文工程的第一产出不是「更聪明的提示词」，而是「一个可测量的预算表」**。预算表要落到具体数字：系统提示多少、工具多少、记忆多少、历史多少、用户多少，每一块的上限是多少。

## 四、分层记忆：工作记忆、短期记忆、长期记忆

### 4.1 为什么要分层

认知科学和 CoALA 框架（[Cognitive Architectures for Language Agents](https://arxiv.org/abs/2309.02427)）都把 agent 的记忆拆成不同时间尺度：

```text
参数记忆（模型权重，训练期固化，改不了）
        ↕  微调 / 训练
外部记忆（检索库、知识图谱，可增量写入）
        ↕  检索
情节记忆（历史交互，按时间组织）
        ↕  摘要 / 反思
工作记忆（当前上下文窗口，容量最小、速度最快）
```

越往下，容量越小、速度越快、越贵；越往上，容量越大、越便宜、越慢。分层的本质是**在容量、成本、时效之间做调度**，和操作系统的内存层级是同构问题。MemGPT 的论文标题就是「Towards LLMs as Operating Systems」，核心思路正是把上下文窗口当内存、把外部存储当磁盘，用分页的方式在两者之间倒换数据。

### 4.2 三种典型实现

| 系统 | 分层方式 | 关键机制 | 论文结论 |
| --- | --- | --- | --- |
| [MemGPT](https://arxiv.org/abs/2310.08560) | 主存 / 外部存 | 虚拟上下文管理，LLM 自己决定换页 | 可分析远超窗口的文档；多会话聊天可长期演化 |
| [MemOS](https://arxiv.org/abs/2507.03724) | 明文 / 激活 / 参数 | MemCube 统一封装内容与元数据，可组合、迁移、融合 | 把记忆当可调度资源，支持记忆类型转换 |
| [Generative Agents](https://arxiv.org/abs/2304.03442) | 记忆流 + 反思 | 自然语言记录全部经历，定期合成高层反思 | 25 个 agent 的沙盒里出现自发的社交行为 |

Generative Agents 的检索评分值得单独说：它用**新近度、重要性、相关性**三个分数加权，从记忆流里检索。这个三因子结构后来被大量记忆系统沿用，是记忆检索的事实标准。

### 4.3 三层记忆的对照

| 层级 | 对应物 | 载体 | 典型容量 | 写入时机 | 失效模式 |
| --- | --- | --- | --- | --- | --- |
| 工作记忆 | 当前上下文 | 模型上下文窗口 | 几百到几十万 token | 每轮构建 | 被挤出、被压缩 |
| 短期记忆 | 情节记忆 | 会话历史、摘要 | 最近若干轮 | 每轮追加 | 摘要有损、窗口滑动 |
| 长期记忆 | 语义/程序记忆 | 向量库、图谱、KV 存储 | 无限（受成本约束） | 异步抽取 | 过期、冲突、冗余 |

### 4.4 读写流程（伪代码）

```text
# 伪代码：分层记忆的读写（不是可运行代码）
function on_user_message(user_msg):
    working = build_context(user_msg, budget=W)   # 见上下文预算分配
    if working.overflow:
        working = compress(working)               # 有损压缩，见 3.3
    answer = llm(working)
    write_memory(extract_salient(working))        # 见第六章
    return answer

function build_context(user_msg, budget):
    blocks = [system, tools, long_term_recall(user_msg), short_term_window, user_msg]
    return allocate(blocks, budget)
```

**工程结论：分层记忆不是「多存几份」，而是「明确每一层的写入条件、检索条件和淘汰条件」**。没有淘汰条件的记忆库，最终会退化成一个越来越慢、越来越贵的垃圾场。

## 五、RAG 与长上下文的取舍

### 5.1 三者各自解决什么

| 方案 | 解决的问题 | 不解决的问题 | 成本结构 | 可追溯 | 适合 |
| --- | --- | --- | --- | --- | --- |
| 全量长上下文 | 任务深度、多跳推理 | 成本、延迟、长期个性化 | 每轮重付，平方级 | 好（原文在上下文里） | 单次长文档任务 |
| RAG | 知识广度、时效更新 | 时间跨度、用户偏好 | 检索 + 短上下文 | 好（有出处） | 知识库问答 |
| 分层记忆 | 时间跨度、个性化 | 单任务深度 | 写入 + 检索 | 中（需设计） | 长期陪伴、Agent |

三者不是替代关系，是串联关系：**RAG 负责「知道什么」，长上下文负责「这一次要看多深」，分层记忆负责「以前发生过什么」。**

### 5.2 证据：检索 + 推理比分开做更好

- [Context Rot](https://www.trychroma.com/research/context-rot) 的 LongMemEval 实验：只给相关信息（约 300 token）显著优于给全量 113K token；
- [LongMemEval](https://arxiv.org/abs/2410.10813)：把长期记忆拆成索引、检索、阅读三阶段，并给出三种优化——会话分解（value 粒度更细）、事实增强的键扩展（索引）、时间感知的查询扩展（限定搜索范围）；
- [Mem0](https://arxiv.org/abs/2504.19413)：在 LOCOMO 上对比 6 类基线，报告相对 OpenAI 的 LLM-as-a-Judge 指标提升 26%，同时 p95 延迟降低 91%、token 成本下降超过 90%；
- [HippoRAG](https://arxiv.org/abs/2405.14831)：受海马体索引理论启发，用知识图谱 + 个性化 PageRank 做检索，多跳问答上比既有方法提升最高 20%，单步检索比迭代检索 IRCoT 便宜 10–30 倍、快 6–13 倍；
- [Zep](https://arxiv.org/abs/2501.13956)：用时序知识图谱（Graphiti）同时融合对话与非结构化业务数据，在 DMR 上 94.8% 对 MemGPT 的 93.4%，在 LongMemEval 上准确率最高提升 18.5%、延迟降低 90%。

这些数字都来自论文自报，横向比较要谨慎（评测集、基线、判分方式都不同）。但它们指向同一个方向：**把「找信息」和「用信息」拆开，通常比一次性塞进长上下文更划算。**

### 5.3 决策树

```text
任务是否需要跨会话记住用户？
├─ 否 → 单次任务
│       ├─ 文档长度 < 窗口 1/3 且无需更新 → 全量长上下文
│       └─ 文档长度大或需更新 → RAG
└─ 是 → 长期记忆
        ├─ 需要复杂时间推理 → 时序图谱（Zep/Graphiti 类）
        ├─ 需要关系推理 → 知识图谱 + PageRank（HippoRAG 类）
        └─ 只需事实与偏好 → 向量库 + 结构化 KV（Mem0 类）
```

**工程结论：不要问「RAG 还是长上下文」，要问「这个任务的哪一部分信息需要每次都带，哪一部分可以按需取」。** 前者进工作记忆，后者进外部记忆。

## 六、记忆写入与检索策略

### 6.1 写入：什么值得记

不是所有对话都值得写进长期记忆。一个可落地的写入策略需要三个判断：

| 判断 | 问题 | 不写的情况 |
| --- | --- | --- |
| 显著性 | 这条信息会影响未来决策吗？ | 闲聊、一次性指令、可重新获取的事实 |
| 类型 | 是事实、偏好、事件还是流程？ | 类型不明、无法结构化 |
| 去重 | 是否已存在语义等价的记忆？ | 高度重复、可被已有记忆覆盖 |

[LongMemEval](https://arxiv.org/abs/2410.10813) 把长期记忆拆成五项能力：信息抽取、多会话推理、时间推理、知识更新、拒答。其中「知识更新」和「拒答」最容易被忽略——**记忆系统不只要记住，还要知道什么时候该说「我不知道」**。

下面是一个纯标准库的写入判断示例：

```python
#!/usr/bin/env python3
"""记忆写入：显著性打分 + 去重判断。纯标准库实现，可运行。"""
from dataclasses import dataclass, field
from typing import List


@dataclass
class Memory:
    mid: str
    text: str
    kind: str           # fact / preference / event / procedure
    importance: float   # 0..1
    created_at: int
    ttl: int = 0        # 0 表示不过期
    tags: List[str] = field(default_factory=list)


STOPWORDS = {"的", "了", "我", "你", "他", "是", "在", "就", "都", "和"}


def salience(text: str, kind: str) -> float:
    """粗粒度显著性：信息密度 + 类型权重。真实系统应换成模型判断。"""
    tokens = [w for w in text.split() if w not in STOPWORDS]
    density = len(tokens) / max(len(text), 1)
    weight = {"fact": 0.9, "preference": 0.85, "event": 0.6, "procedure": 0.7}
    return round(min(1.0, density * 2 + weight.get(kind, 0.5)), 4)


def jaccard(a: str, b: str) -> float:
    sa, sb = set(a), set(b)
    return len(sa & sb) / len(sa | sb) if sa | sb else 0.0


def should_write(memories: List[Memory], text: str, kind: str,
                 threshold: float = 0.8) -> bool:
    for m in memories:
        if m.kind == kind and jaccard(m.text, text) >= threshold:
            return False
    return True


if __name__ == "__main__":
    mems = [Memory("m1", "用户偏好深色主题", "preference", 0.9, 1)]
    print(salience("用户偏好深色主题", "preference"))
    print(should_write(mems, "用户喜欢深色主题", "preference"))
```

注意：这个示例的显著性打分是占位实现。生产系统应该用模型判断「这条信息是否值得长期保留」，并给出理由，便于审计。

### 6.2 检索：多信号融合

单一向量相似度不够。一个稳健的检索至少融合三类信号：

| 信号 | 作用 | 失效场景 |
| --- | --- | --- |
| 语义相似度 | 找「意思相近」 | 同义词、跨语言、隐式关联 |
| 关键词/BM25 | 找「字面命中」 | 专有名词、编号、代码符号 |
| 时间新近度 | 偏好近期信息 | 长期偏好被近期噪声淹没 |
| 图结构 | 找「关联实体」 | 多跳关系、组织/人物关系 |

下面是一个三因子融合的检索示例（新近度 + 重要性 + 相关性）：

```python
#!/usr/bin/env python3
"""记忆检索：新近度 + 重要性 + 相关性三因子融合。纯标准库实现，可运行。"""
import math
from dataclasses import dataclass
from typing import List


@dataclass
class Memory:
    mid: str
    text: str
    importance: float
    created_at: float
    access_count: int = 0


def recency_score(m: Memory, now: float, half_life: float = 7 * 86400) -> float:
    age = max(0.0, now - m.created_at)
    return math.exp(-math.log(2) * age / half_life)


def overlap(query: str, text: str) -> float:
    q, t = set(query), set(text)
    return len(q & t) / len(q) if q else 0.0


def rank(memories: List[Memory], query: str, now: float,
         w_recency=0.25, w_importance=0.25, w_relevance=0.5) -> List[Memory]:
    scored = []
    for m in memories:
        s = (w_recency * recency_score(m, now)
             + w_importance * m.importance
             + w_relevance * overlap(query, m.text))
        scored.append((s, m))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [m for _, m in scored]


if __name__ == "__main__":
    mems = [
        Memory("a", "用户在北京工作", 0.8, 100.0),
        Memory("b", "用户喜欢深色主题", 0.9, 900.0),
        Memory("c", "用户养了一只猫", 0.6, 500.0),
    ]
    for m in rank(mems, "用户的宠物", now=1000.0)[:2]:
        print(m.mid, m.text)
```

权重是经验值，应按业务调参。**新近度半衰期**是其中最敏感的参数：太短会让长期偏好失效，太长会让过时信息污染回答。

### 6.3 检索与长上下文的配合

一个常见错误是「检索完直接全塞进上下文」。更稳的做法是给检索结果也设预算，并按「相关性 × 位置」重排——把最相关的片段放在开头和结尾，避开中间塌陷区。

**工程结论：写入决定上限，检索决定下限。** 写得再好，检索不到等于没记；检索再好，写进去的是垃圾也是垃圾。

## 七、记忆一致性、过期与冲突消解

### 7.1 三类记忆腐化

记忆库不会自动保持正确，它会随时间腐化：

| 腐化类型 | 表现 | 典型场景 | 后果 |
| --- | --- | --- | --- |
| 过期 | 信息不再成立 | 用户换了城市、产品下架 | 回答基于旧事实 |
| 冲突 | 同一 key 多个值 | 「用户偏好 A」与「用户偏好 B」并存 | 随机选一个，行为不稳定 |
| 冗余 | 同一事实多条记录 | 每次会话重复抽取 | 检索噪声、成本上升 |

### 7.2 过期策略

| 策略 | 机制 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 固定 TTL | 超过时间即失效 | 简单可预测 | 不区分信息类型 |
| 衰减权重 | 时间越久分数越低 | 平滑，不突然消失 | 参数敏感 |
| 类型化 TTL | 偏好长、事实中、事件短 | 贴合业务 | 需要维护类型表 |
| 事件触发失效 | 检测到更新即作废旧值 | 准确 | 需要监听机制 |

一个实用的默认值：**偏好类记忆衰减慢（半衰期以月计），事件类衰减快（以天计），事实类不自动过期但需要能被新版本覆盖。** 这些是经验起点，不是标准答案。

### 7.3 冲突消解

冲突消解的核心是**版本化**：每条记忆带 `key`、`value`、`updated_at`。同一 key 只保留 `updated_at` 最大的记录；值不同的记录进入待确认队列。

```python
#!/usr/bin/env python3
"""记忆过期与冲突消解：TTL 过期 + 同键新值覆盖旧值。纯标准库实现，可运行。"""
from dataclasses import dataclass
from typing import Dict, List


@dataclass
class Record:
    key: str
    value: str
    updated_at: int
    ttl: int = 0


def expire(records: List[Record], now: int) -> List[Record]:
    return [r for r in records if r.ttl == 0 or now - r.updated_at <= r.ttl]


def resolve(records: List[Record], now: int) -> Dict[str, Record]:
    """同一 key 保留 updated_at 最大者；TTL 已过期的丢弃。"""
    live = expire(records, now)
    out: Dict[str, Record] = {}
    for r in live:
        cur = out.get(r.key)
        if cur is None or r.updated_at > cur.updated_at:
            out[r.key] = r
    return out


def conflicts(records: List[Record], now: int) -> List[List[Record]]:
    """找出同 key 但值不同的记录（潜在需要人工确认的冲突）。"""
    by_key: Dict[str, List[Record]] = {}
    for r in expire(records, now):
        by_key.setdefault(r.key, []).append(r)
    return [v for v in by_key.values() if len({r.value for r in v}) > 1]


if __name__ == "__main__":
    recs = [
        Record("city", "北京", 100, ttl=1000),
        Record("city", "上海", 500, ttl=1000),
        Record("city", "北京", 50, ttl=10),
    ]
    print(resolve(recs, now=600))
    print(conflicts(recs, now=600))
```

**工程结论：记忆系统必须能「忘记」。** 只增不减的记忆库，检索质量会随时间单调下降；而忘记的机制（TTL、覆盖、归档）需要和写入机制一起设计。

### 7.4 一致性检查

上线后需要持续监控三类指标：

- **过期率**：随机抽样，人工判断有多少记忆已不成立；
- **冲突率**：同 key 多值的比例；
- **检索准确率**：给一批问题，人工标注期望命中的记忆，看召回率。

这三项没有自动判分方法，只能靠抽样人工评测。这也是记忆系统最容易被跳过、也最容易埋雷的部分。

## 八、工程落地清单

### 8.1 五层落地框架

| 层级 | 手段 | 解决 | 最小可用配置 |
| --- | --- | --- | --- |
| L0 预算 | 上下文预算分配 | 成本失控 | 每块 token 上限 + 超限裁剪 |
| L1 缓存 | 稳定前缀 + 缓存 | 重复计费 | 稳定层前置，命中率监控 |
| L2 压缩 | 摘要 / 剪枝 / 检索 | 超长历史 | 历史摘要 + 检索片段 |
| L3 记忆 | 分层记忆 + 检索 | 跨会话 | 向量库 + 三因子排序 |
| L4 治理 | TTL / 版本 / 冲突 | 记忆腐化 | 过期策略 + 冲突队列 |

### 8.2 度量指标与门槛

| 指标 | 定义 | 经验门槛 | 不达标怎么办 |
| --- | --- | --- | --- |
| 单次输入 token | 每轮平均输入 | 按业务定，趋势不涨 | 查历史是否全量携带 |
| 缓存命中率 | cached / prompt | 会话类 >50% | 查系统提示是否稳定 |
| 检索召回 | 命中期望记忆的比例 | >80% | 加关键词/时间信号 |
| 记忆过期率 | 抽样中已失效比例 | <10% | 缩短 TTL 或加更新触发 |
| 端到端 P95 | 请求完成时间 | 按 SLO | 减输入、换模型、加缓存 |

门槛是经验值，必须用你自己的分布校准。**没有基线的阈值等于没有阈值。**

### 8.3 成本估算代码

```python
#!/usr/bin/env python3
"""调用成本估算：输入/输出 token × 单价，并估算缓存命中带来的节省。
价格与缓存折扣以你所用平台的官方文档为准，这里只提供计算结构。
"""


def cost(input_tokens, output_tokens, price_in, price_out,
         cached_ratio=0.0, cache_discount=0.5):
    cached = input_tokens * cached_ratio
    billable = input_tokens - cached
    return billable * price_in + cached * price_in * cache_discount + output_tokens * price_out


def cache_saving(input_tokens, price_in, cached_ratio, cache_discount=0.5):
    return input_tokens * cached_ratio * price_in * cache_discount


if __name__ == "__main__":
    print(cost(50000, 1000, 0.001, 0.003, cached_ratio=0.7))
    print(cache_saving(50000, 0.001, 0.7))
```

### 8.4 上线前检查清单

- [ ] 上下文各块有明确预算上限，超限有裁剪策略；
- [ ] 稳定层前置、用户消息后置，缓存命中率已测量；
- [ ] 历史不是全量携带，有摘要或检索；
- [ ] 记忆写入有显著性判断和去重；
- [ ] 记忆检索至少融合两类信号（语义 + 关键词/时间）；
- [ ] 每条记忆有类型、时间戳、TTL；
- [ ] 同 key 冲突有版本化消解，冲突队列可审计；
- [ ] 记忆过期率、检索召回率有抽样人工评测；
- [ ] 成本、延迟、缓存命中率纳入发布门槛；
- [ ] 长上下文任务用过带复杂度维度的基准，而不是只看 NIAH。

### 8.5 团队阶段与投入

| 阶段 | 建议投入 | 最低配置 |
| --- | --- | --- |
| 早期 | 先把预算和缓存做对 | 固定预算表 + 稳定前缀 |
| 成长期 | 上摘要和检索，建记忆库 | 历史摘要 + 向量库 + 三因子排序 |
| 成熟期 | 分层记忆 + 治理 + 时序图谱 | TTL/版本化 + 冲突队列 + 抽样评测 |

**工程结论：记忆系统不是一次性建设项目，而是一个需要持续治理的子系统。** 它的运维成本（写入、去重、过期、冲突）通常比建设成本更高，预算时要一起算。

## 小结

长上下文与记忆系统的本质，是把「容量问题」转化成「治理问题」。第一，长上下文有三个同时恶化的约束——成本、延迟、注意力衰减，窗口变大不会自动解决任何一个。第二，注意力衰减有稳定的实证支持：Lost in the Middle 的 U 形曲线、RULER 的「宣称 32K 一半撑不住」、Context Rot 的「简单任务也退化」，都说明 NIAH 满分不能作为选型依据。第三，上下文工程的核心是分层和预算：稳定层前置、变化层后置、每块有 token 上限。第四，压缩是有损的，压缩比越高越需要评估；前缀缓存是最便宜的优化，但前提是提示词结构稳定。第五，分层记忆（工作、短期、长期）对应操作系统式的调度问题，写入条件、检索条件、淘汰条件必须同时设计。第六，RAG、长上下文、分层记忆是串联关系：RAG 管知识广度，长上下文管任务深度，记忆管时间跨度。第七，记忆的一致性治理（过期、冲突、冗余）决定系统半年后的可用性，只增不减的记忆库必然腐化。把 L0 预算、L1 缓存、L2 压缩、L3 记忆、L4 治理五层打通，长上下文才从参数表变成可用的工程能力。

## 参考资料

1. Liu, N. et al., [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172), TACL 2023.
2. Hsieh, C.-P. et al., [RULER: What's the Real Context Size of Your Long-Context Language Models?](https://arxiv.org/abs/2404.06654), COLM 2024.
3. Bai, Y. et al., [LongBench: A Bilingual, Multitask Benchmark for Long Context Understanding](https://arxiv.org/abs/2308.14508), ACL 2024.
4. Hong, K., Troynikov, A., Huber, J., [Context Rot: How Increasing Input Tokens Impacts LLM Performance](https://www.trychroma.com/research/context-rot), Chroma Technical Report, 2025.
5. Kamradt, G., [Needle In A Haystack - Pressure Testing LLMs](https://github.com/gkamradt/LLMTest_NeedleInAHaystack).
6. Wu, D. et al., [LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory](https://arxiv.org/abs/2410.10813), ICLR 2025.
7. Packer, C. et al., [MemGPT: Towards LLMs as Operating Systems](https://arxiv.org/abs/2310.08560).
8. Li, Z. et al., [MemOS: A Memory OS for AI System](https://arxiv.org/abs/2507.03724).
9. Park, J. S. et al., [Generative Agents: Interactive Simulacra of Human Behavior](https://arxiv.org/abs/2304.03442).
10. Xu, W. et al., [A-MEM: Agentic Memory for LLM Agents](https://arxiv.org/abs/2502.12110), NeurIPS 2025.
11. Chhikara, P. et al., [Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory](https://arxiv.org/abs/2504.19413).
12. Rasmussen, P. et al., [Zep: A Temporal Knowledge Graph Architecture for Agent Memory](https://arxiv.org/abs/2501.13956).
13. Maharana, A. et al., [Evaluating Very Long-Term Conversational Memory of LLM Agents](https://arxiv.org/abs/2402.17753) (LoCoMo).
14. Sumers, T. R. et al., [Cognitive Architectures for Language Agents](https://arxiv.org/abs/2309.02427), TMLR.
15. Jiang, H. et al., [LLMLingua: Compressing Prompts for Accelerated Inference of Large Language Models](https://arxiv.org/abs/2310.05736), EMNLP 2023.
16. Chevalier, A. et al., [Adapting Language Models to Compress Contexts](https://arxiv.org/abs/2305.14788), EMNLP 2023.
17. Xiao, G. et al., [Efficient Streaming Language Models with Attention Sinks](https://arxiv.org/abs/2309.17453), ICLR 2024.
18. Gutiérrez, B. J. et al., [HippoRAG: Neurobiologically Inspired Long-Term Memory for Large Language Models](https://arxiv.org/abs/2405.14831), NeurIPS 2024.
19. Modarressi, A. et al., [NoLiMa: Long-Context Evaluation Beyond Literal Matching](https://arxiv.org/abs/2502.05167).
20. Vodrahalli, K. et al., [Michelangelo: Long Context Evaluations Beyond Haystacks via Latent Structure Queries](https://arxiv.org/abs/2409.12640).
21. Fu, H. Y. et al., [AbsenceBench: Language Models Can't Tell What's Missing](https://arxiv.org/abs/2506.11440).
22. Gemini Team, [Gemini 1.5: Unlocking multimodal understanding across millions of tokens of context](https://arxiv.org/abs/2403.05530).
23. OpenAI, [Prompt Caching](https://platform.openai.com/docs/guides/prompt-caching)（官方文档；具体门槛与折扣比例本次未能直接核验，落地前请以官方页面为准）.
24. Anthropic, [Prompt Caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)（官方文档；具体倍率本次未能直接核验，落地前请以官方页面为准）.
