---
title: "大模型评测体系：Benchmark 陷阱、LLM-as-Judge 与人工评测"
description: "评测才是 LLM 应用的隐形瓶颈：榜单分数为何不可信、Benchmark 污染如何检测、LLM-as-Judge 有哪些系统性偏差、人工评测怎么设计才不白花钱。本文给出一套可落地的分层评测框架与检查清单。"
date: 2026-11-16
categories: ["AI 应用"]
tags: ["评测", "Benchmark", "LLM-as-Judge", "数据污染", "人工标注"]
---

## 引言：榜单分数涨得比线上效果快

过去一年，几乎所有团队都在做同一件事：换模型、换 prompt、换采样参数，然后跑一遍榜单。但你应该早就遇到过这些问题：

- 同一个模型，MMLU 涨了 5 分，用户却反馈「回答变啰嗦了」；
- 离线跑分排第一的模型，灰度上线后留存反而下降；
- 换一版 prompt 模板，模型排名就翻一遍；
- 你拿 benchmark 分数跟业务方对齐，对方一句「这跟我有什么关系」就把天聊死了；
- 评测集更新一次，之前所有的历史结论全部作废。

这些现象的共同根源是：**模型迭代的速度，已经快于评测体系更新的速度**。评测不是「跑个分」，而是一套测量系统——它有自己的量具、校准、误差和漂移。量具不准，所有基于它的决策都是噪声。

本文不重复站内已覆盖的 RAG 评测、微调评估和 Agent 可靠性，只讨论「评测体系本身」：Benchmark 的陷阱、LLM-as-Judge 的偏差与校准、人工评测的设计、评测集构建与泄漏检测，以及离线指标和在线业务指标怎么接上。

## 一、为什么评测是 LLM 应用的最大瓶颈

先看时间尺度：

| 环节 | 典型耗时 | 频率 |
| --- | --- | --- |
| 换模型 / 换 prompt | 小时级 | 每天多次 |
| 跑一个公开 benchmark | 分钟到小时 | 每周 |
| 更新评测集 | 周级 | 每季度 |
| 人工评测排期 | 周级 | 每月一次 |

模型侧改动的反馈周期是小时，评测侧的反馈周期是周甚至月。**当反馈周期长于迭代周期，评测就从「测量工具」退化成「汇报工具」**：它只能告诉你上个月的模型大概怎么样，不能告诉你这次改动是好是坏。

评测缺位会造成四类具体损失：

| 缺失的评测 | 典型失败 | 后果 |
| --- | --- | --- |
| 单次生成质量 | 只跑 100 条公开题，不抽样 | 分布漂移无人知道 |
| 模型选型 | 按榜单总分排序 | 选到「会考试」的模型 |
| prompt / 参数回归 | 没有固定评测集 | 每次改动靠感觉，回滚无依据 |
| 线上效果 | 只看离线分数 | 上线翻车，事后无法归因 |

工程结论：**评测体系的第一目标不是「给出一个分数」，而是「让每次改动都有可复现的对比」**。做不到这一点，后面所有优化都是赌博。

## 二、Benchmark 的四个陷阱

Benchmark 不是坏东西，坏的是把它当成唯一事实来源。四个最常见的陷阱：

### 2.1 污染与泄漏

评测集一旦公开，就会进入预训练语料。模型不是「会做这道题」，而是「背过这道题」。Gema 等人在 [Are We Done with MMLU?](https://arxiv.org/abs/2406.04127) 里人工核查了 MMLU 的部分子集，发现 Virology 子集 57% 的题目有错，并估计整个 MMLU 约 6.49% 的题目包含错误；他们用 57 个学科、5,700 条人工重标注的 MMLU-Redux 复算模型分数，结果与原报告差异显著。题目本身都会错，分数自然不可全信。

### 2.2 过拟合与榜单刷分

榜单是目标函数，就会被优化。针对公开评测集做 SFT、刷题、构造与评测集同分布的训练数据，都能显著抬分。Zhou 等人在 [Don't Make Your LLM an Evaluation Benchmark Cheater](https://arxiv.org/abs/2311.01964) 中专门讨论了 benchmark leakage：评测数据进入训练后，分数会被显著抬高，最终得到不可靠的模型评估。

### 2.3 任务分布与真实分布不匹配

公开 benchmark 追求覆盖面和可比性，往往偏向「有标准答案、短输出、单轮」的任务；真实业务里大量是多轮、开放、长上下文、带工具调用的场景。[Judging LLM-as-a-Judge](https://arxiv.org/abs/2306.05685) 里有一个很典型的观察：对齐后的聊天模型在用户偏好上显著优于基座模型，但在 MMLU、HELM 这类传统榜单上却分不出高下——**传统 benchmark 测的是核心能力，不是用户价值**。

### 2.4 分数不可比

同一个模型换个 prompt 模板、换个采样温度、换个判分脚本，分数就能差几个点。公开榜单的分数通常绑定「数据集版本 + prompt 模板 + 采样参数 + 判分实现」四件套，任何一项漂移，历史分数就不可比。

| Benchmark | 任务形态 | 判分方式 | 抗污染设计 | 已知问题 |
| --- | --- | --- | --- | --- |
| [MMLU](https://arxiv.org/abs/2009.03300) | 57 个任务的选择题 | 精确匹配 | 无（静态） | 约 6.49% 题目含错 |
| [TruthfulQA](https://arxiv.org/abs/2109.07958) | 生成 / 选择，817 题 38 类 | 规则 + 模型 | 无（静态） | 最大模型往往最不 truthful |
| [BIG-bench](https://arxiv.org/abs/2206.04615) | 204 个任务 | 多样 | 部分 | 人类专家基线远高于模型 |
| [HELM](https://arxiv.org/abs/2211.09110) | 42 场景 × 7 指标 | 多指标 | 部分 | 场景覆盖从 17.9% 提升到 96.0% |
| [LiveBench](https://arxiv.org/abs/2406.19314) | 滚动更新 | 客观 ground truth | 按月更新 | 顶尖模型准确率 <70% |

工程结论：**公开榜单适合做「能力下限」的粗筛，不适合做「线上效果」的预测**。把它当唯一依据做选型，等于用模拟考成绩填志愿。

## 三、公开榜单是怎么造出来的，坑在哪

### 3.1 一个榜单的构造流程

```text
选题（从哪来？）→ 出题（人工 / 众包 / 现成数据集）→ 标注（标准答案 / 偏好标签）
→ 判分（规则 / 模型 / 人工）→ 聚合（平均分 / Elo / 胜率）→ 发布（排行榜 + 论文）
```

每一步都有坑：

- 选题来自现成数据集 → 立刻继承它的污染；
- 出题靠众包 → 题目分布偏向众包用户的兴趣；
- 标注没有双人交叉 → 一致性无从验证；
- 判分用模型 → 引入 judge 偏差（见第五章）；
- 聚合只报平均分 → 方差、分位数、失败模式全被抹掉；
- 发布后不再更新 → 半年后分数失去意义。

### 3.2 四类榜单，四种信任度

| 榜单类型 | 代表 | 更新方式 | 信任度 | 主要风险 |
| --- | --- | --- | --- | --- |
| 静态公开 | MMLU、HumanEval | 几乎不更新 | 低（已被污染） | 泄漏、过拟合 |
| 动态滚动 | LiveBench、LiveCodeBench | 按月 | 中 | 历史不可比、样本量小 |
| 私有未公开 | 各家内部集 | 持续 | 高（内部） | 不可外部复核 |
| 众包对战 | Chatbot Arena | 持续 | 中 | 用户分布偏差、刷票 |

[Chatbot Arena](https://arxiv.org/abs/2403.04132) 是众包对战的代表：匿名双模型对战、用户投票，累计超过 24 万票，用 Bradley-Terry 类方法做排名，并验证了众包投票与专家评分的一致性。它的价值在于「真实分布」，风险在于「谁来投票」。

工程结论：**榜单的可信度不取决于它多有名，而取决于它是否可复现、是否滚动更新、是否公开判分口径**。三者缺一，就只能当参考，不能当依据。

## 四、污染与泄漏：怎么发现、怎么缓解

### 4.1 污染是怎么发生的

```text
公开评测集发布 → 进入预训练语料（爬取）→ 进入 SFT / 合成数据（刷题）→ 分数虚高
```

### 4.2 检测：先重叠，再成员推断

最直接的检测是文本重叠。下面这个脚本是纯标准库实现，可运行，用来快速筛查评测集与语料的字符 n-gram 重叠：

```python
#!/usr/bin/env python3
"""评测集泄漏检测：字符 n-gram 重叠率。
用法: python leak_check.py --corpus corpus.txt --eval eval.jsonl --field text --n 8
corpus.txt 每行一段语料；eval.jsonl 每行一个 JSON，取 field 字段作为文本。
"""
import argparse, json, re

def ngrams(text, n):
    text = re.sub(r"\s+", "", text.lower())
    return {text[i:i + n] for i in range(len(text) - n + 1)}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--eval", required=True)
    ap.add_argument("--field", default="text")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--threshold", type=float, default=0.8)
    a = ap.parse_args()

    grams = set()
    for line in open(a.corpus, encoding="utf-8"):
        grams |= ngrams(line, a.n)
    print(f"corpus n-grams: {len(grams)}")

    flagged = total = 0
    for idx, line in enumerate(open(a.eval, encoding="utf-8"), 1):
        line = line.strip()
        if not line:
            continue
        total += 1
        g = ngrams(json.loads(line).get(a.field, ""), a.n)
        ratio = len(g & grams) / len(g) if g else 0.0
        if ratio >= a.threshold:
            flagged += 1
            print(f"[HIT] line {idx} overlap={ratio:.3f}")
    print(f"scanned={total} flagged={flagged} rate={flagged / max(total, 1):.3%}")

if __name__ == "__main__":
    main()
```

重叠率高只能说明「像」，不能说明「泄漏」。更严格的做法是成员推断：用模型在候选样本上的 token 概率异常（例如 min-k% 概率）判断它是否来自训练集。[Benchmark Data Contamination 综述](https://arxiv.org/abs/2406.04244) 把检测方法归为「基于重叠」和「基于模型」两大类，可作为选型起点。

| 检测手段 | 原理 | 优点 | 局限 |
| --- | --- | --- | --- |
| n-gram 重叠 | 文本片段重合 | 快、可解释、可本地跑 | 只能查逐字复制 |
| 规范化哈希 | 去空格/大小写后比对 | 能查轻微改写 | 仍怕语义改写 |
| 成员推断（min-k%） | 训练样本概率异常 | 能查改写后的泄漏 | 需要模型内部概率、算力大 |
| 模型规模突变 | 同题在不同规模模型上表现跳变 | 无需外部语料 | 归因弱、易误报 |

### 4.3 缓解：滚动更新优先，重构次之

缓解污染有两条路：**换题**（滚动更新）和**改题**（重构）。

- 滚动更新：[LiveBench](https://arxiv.org/abs/2406.19314) 按月更新题目，覆盖数学竞赛、arXiv 论文、新闻、数据集，并给出 Big-Bench Hard、AMPS、IFEval 的抗污染更难版本，顶尖模型准确率仍低于 70%。[LiveCodeBench](https://arxiv.org/abs/2403.07974) 从 LeetCode、AtCoder、CodeForces 持续收集题目，当前 400 题（2023-05 至 2024-05）。
- 重构：[CODECLEANER](https://arxiv.org/abs/2411.10842) 用 11 个 Python 重构算子（方法级、类级、跨类级），全部应用后重叠率下降 65%。但[代码污染对策的实证研究](https://arxiv.org/abs/2403.16898)发现，重构并不总是降低模型性能，甚至可能提升——改题本身会引入新的分布偏移。

更重要的是：**改题不是万能药**。[The Emperor's New Clothes in Benchmarking?](https://arxiv.org/abs/2503.16402) 用 10 个 LLM、5 个 benchmark、20 种缓解策略做了系统评估，结论是：没有任何策略能在所有 benchmark 上显著优于「不更新」的 baseline，也没有策略能同时兼顾 fidelity 与抗污染。

工程结论：**优先滚动更新，其次重构，最后才考虑「不更新但标注风险」**。不要指望一次重构解决污染，它只是把问题往后推。

## 五、LLM-as-Judge：能用什么，不能用什么

### 5.1 它解决什么问题

开放性问题没有标准答案，规则判分失效，人工评测又贵又慢。用强模型当裁判，是唯一能规模化的近似方案。MT-Bench 用 80 道题覆盖写作、角色扮演、信息抽取、推理、数学、编码、STEM、人文 8 个类别（每类 10 道多轮题），论文里 GPT-4 作裁判与人类偏好的一致率超过 80%，和人类彼此之间的一致率（81%）相当；在 MT-Bench 上 GPT-4 成对比较与人类的一致率是 85%，单点打分也是 85%。

### 5.2 四类系统性偏差

| 偏差 | 表现 | 证据 |
| --- | --- | --- |
| 位置偏差 | 偏向特定位置，交换后翻转 | MT-Bench：GPT-4 位置翻转一致性 65%，Claude-v1 仅 23.8% |
| 长度偏差 | 偏好更长的回答 | AlpacaEval：长度控制后与 Chatbot Arena 的 Spearman 从 0.94 升到 0.98 |
| 自我偏好 | 偏好自己生成的回答 | MT-Bench：GPT-4 对自己的胜率高 10%，Claude-v1 高 25% |
| 格式偏好 | 偏好列表、标题、Markdown | 重复列表攻击：Claude-v1、GPT-3.5 失败率 91.3%，GPT-4 仅 8.7% |

[Judging the Judges](https://arxiv.org/abs/2406.07791) 用 15 个 judge、22 个任务、约 40 个解题模型、超过 15 万个评测实例做了系统研究，提出 repetition stability、position consistency、preference fairness 三个指标。核心结论：位置偏差不是随机噪声，随 judge 和任务显著变化；它受 prompt 长度影响弱，**受两个解的质量差距影响强**——也就是说，两个答案越接近，位置偏差越致命。

[JudgeBench](https://arxiv.org/abs/2410.12784) 更进一步：把已有难题转成带客观正确性偏好的响应对，覆盖知识、推理、数学、编码，结果 GPT-4o 只比随机猜测略好。**judge 的「人类偏好对齐度」和「事实正确性判断力」是两回事**，前者好不代表后者好。

### 5.3 成对比较 vs 单点打分

| 维度 | 成对比较 | 单点打分 |
| --- | --- | --- |
| 判分对象 | 两个回答 | 一个回答 |
| 稳定性 | 高（相对比较） | 低（绝对分数易漂移） |
| 成本 | 高（两两组合是平方级） | 低（每回答一次） |
| 偏差 | 位置偏差 | 长度/格式/自我偏好 |
| 适用 | 选型、对战、回归对比 | 大规模在线抽检 |
| 处理位置偏差 | 交换位置跑两次，不一致记 tie | 随机化顺序 |

工程建议：**关键决策用成对 + 位置交换，日常抽检用单点 + 随机顺序**。

### 5.4 judge 的 prompt 与模型选择

- 给 judge 明确的评测标准（rubric），不要只写「哪个更好」；数学/推理题先让 judge 独立作答再给参考答案，能显著降低误判（MT-Bench 的失败率从 14/20 降到 3/20）；
- 优先选专门的评估模型：[Prometheus 2](https://arxiv.org/abs/2405.01535) 同时支持单点评估与成对排序，支持自定义评测标准，在 4 个 direct + 4 个 pairwise 基准上与人类和 GPT-4 的相关性/一致率最高；生成任务可用 [G-Eval](https://arxiv.org/abs/2303.16634) 这类 CoT + 表单式判分，摘要任务上 Spearman 0.514，但作者也指出 LLM 评估器会偏向 LLM 生成的文本。

### 5.5 校准与一致性度量

上线 judge 前，先做一次校准：抽 200～500 条人工标注，计算 judge 与人工的一致率；上线后持续监控。位置一致性检测的伪代码：

```python
# 伪代码：位置一致性检测（judge_pair 需接入你的模型 API）
def judge_pair(question, answer_a, answer_b):
    """返回 'A' / 'B' / 'tie'。真实实现调用模型 API。"""
    raise NotImplementedError


def position_consistency(question, a, b):
    r1 = judge_pair(question, a, b)
    r2 = judge_pair(question, b, a)      # 交换位置再判一次
    return "consistent" if r1 == r2 else "inconsistent"
```

工程结论：**把 judge 当成一个需要校准的传感器，而不是一个权威**。校准指标至少包括：与人工的一致率、位置翻转一致率、重复判分稳定率。

## 六、人工评测：怎么设计才不白花钱

### 6.1 量表设计

| 量表类型 | 例子 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- | --- |
| 二值 | 通过 / 不通过 | 一致性高、便宜 | 丢失程度信息 | 合规、事实正确性 |
| 分级 | 1-5 分 | 表达程度 | 中间档含义模糊 | 综合质量 |
| 成对 | A 好 / B 好 / 平 | 最接近真实选择 | 只能比较、不能排序 | 选型、偏好 |
| 多维 | 正确性/清晰度各打分 | 可归因 | 标注成本高 | 诊断与改进 |

经验：**先二值，再分级**。一开始就上 5 分量表，标注员对 3 分和 4 分的理解不一致，一致性会很低。

### 6.2 标注指南与黄金集

- 写清每个分值的**边界样例**，不要只写形容词；
- 建 100～200 条黄金集（golden set），双人交叉标注，作为标注员考试题和质检基线；
- 黄金集混入日常批次（例如 10%），用来监控标注员漂移；
- 定期开标注对齐会，把分歧样本拿出来讨论。

### 6.3 一致性度量

两人标注用 Cohen's kappa，多人或有缺失用 Krippendorff's alpha。下面代码是纯标准库实现，可运行：

```python
#!/usr/bin/env python3
"""标注一致性：Cohen's kappa（两人）与 Krippendorff's alpha（多人/缺失）。
输入: annotations.csv，三列 item_id, annotator, label
"""
import csv
from collections import Counter, defaultdict

def cohen_kappa(a, b):
    n = len(a)
    po = sum(x == y for x, y in zip(a, b)) / n
    ca, cb = Counter(a), Counter(b)
    pe = sum((ca[k] / n) * (cb[k] / n) for k in set(ca) | set(cb))
    return (po - pe) / (1 - pe) if pe < 1 else 1.0

def krippendorff_alpha_nominal(rows):
    """rows: list[(item_id, annotator, label)]，支持多人与缺失。"""
    units = defaultdict(dict)
    for item, ann, lab in rows:
        units[item][ann] = lab
    coinc = Counter()
    for anns in units.values():
        labs = list(anns.values())
        m = len(labs)
        if m < 2:
            continue
        for i in range(m):
            for j in range(m):
                if i != j:
                    coinc[(labs[i], labs[j])] += 1.0 / (m - 1)
    n_c = Counter()
    for (c, _k), v in coinc.items():
        n_c[c] += v
    n = sum(n_c.values())
    if n < 2:
        return float("nan")
    labels = sorted(n_c)
    d_o = sum(v * (0.0 if c == k else 1.0) for (c, k), v in coinc.items()) / n
    d_e = sum(n_c[c] * n_c[k] * (0.0 if c == k else 1.0)
              for c in labels for k in labels) / (n * (n - 1))
    return 1 - d_o / d_e if d_e else 1.0

if __name__ == "__main__":
    rows = []
    for row in csv.DictReader(open("annotations.csv", encoding="utf-8")):
        rows.append((row["item_id"], row["annotator"], row["label"]))
    by_item = defaultdict(dict)
    for item, ann, lab in rows:
        by_item[item][ann] = lab
    items = [i for i, anns in by_item.items() if "a" in anns and "b" in anns]
    ka = cohen_kappa([by_item[i]["a"] for i in items], [by_item[i]["b"] for i in items])
    print(f"cohen_kappa={ka:.3f}")
    print(f"krippendorff_alpha={krippendorff_alpha_nominal(rows):.3f}")
```

解读参考（经验阈值，非绝对标准）：

- Cohen's kappa：0.61–0.80 通常算「较好」，0.81 以上算「很好」；
- Krippendorff's alpha：0.80 以上可接受，0.667 只能算「暂定」。

低于阈值时，**先改标注指南，再换标注员**，不要直接平均。

### 6.4 抽样策略

- 分层抽样：按业务场景、难度、用户类型分层，别随机抽；难度用历史通过率或 judge 分位数打档，保证每层都有量；
- 主动抽样：优先抽 judge 与人工不一致、模型间分歧大的样本，人工预算花在刀刃上；
- 固定比例：黄金集 10%、日常抽检 5%～10%、全量只在发布前跑。

工程结论：**人工评测的产出不是「一个分数」，而是「标注指南 + 黄金集 + 一致性数据」**。这三样才是能复用的资产。

## 七、评测集构建：从语料到可发布的数据集

### 7.1 构建流程

```text
需求（测什么能力？）→ 分层抽样（场景 × 难度）→ 去重（哈希 + 语义近重复）
→ 标注（双人交叉 + 黄金集）→ 泄漏检测（n-gram + 成员推断）
→ 冻结版本（v1.0，写清口径）→ 发布（可复现的判分脚本）
```

### 7.2 关键检查项

| 检查项 | 为什么 | 做法 |
| --- | --- | --- |
| 分层抽样 | 避免某类场景占比过高 | 先定场景配额，再抽 |
| 去重 | 重复样本会抬高分数 | 规范化哈希 + 近重复检测 |
| 难度分层 | 简单题区分不出模型 | 用历史通过率分档 |
| 泄漏检测 | 公开即污染 | 发布前跑重叠与成员推断 |
| 版本冻结 | 分数不可比 | 数据集 + 判分脚本一起打 tag |
| 判分口径文档化 | 别人复现不了 | 写清 prompt 模板、采样、解析规则 |

### 7.3 滚动评测集

静态集适合「能力基线」，滚动集适合「跟踪进展」。LiveBench 按月更新、LiveCodeBench 持续收集竞赛题，都是这个思路。代价是**历史分数不可直接比较**，所以实践中通常两条腿走路：保留一个静态锚点集用于跨年对比，同时维护一个滚动集用于当下判断。工程结论：**评测集不是「一次性交付物」，而是一个需要版本管理的产品**。没有版本号的数据集，等于没有口径的分数。

## 八、离线指标与在线指标的衔接

### 8.1 为什么对不上

离线集是「干净分布」，线上是「脏分布」：用户会问评测集里根本没有的问题，会多轮纠缠，会带情绪。离线分数高不代表线上好，离线分数低也不代表该砍。

### 8.2 三个衔接手段

1. **A/B 实验**：线上唯一能证明因果的手段。离线分数决定「哪些候选进入灰度」，线上指标决定「哪个上线」。
2. **人工分流**：把线上流量按分层抽样送给人工评测，用人工结果校准离线集——如果离线集上 A 比 B 好，线上人工也是 A 好，离线集才可信。
3. **护栏指标**：除了业务主指标，必须监控延迟、成本、拒答率、安全违规率；模型可能「更聪明」但「更贵更慢」，主指标会掩盖这一点。

线上指标的置信区间不要只看均值，用 bootstrap 算区间：

```python
#!/usr/bin/env python3
"""A/B 指标 bootstrap 置信区间（纯标准库）。"""
import random

def bootstrap_ci(treat, ctrl, n_boot=10000, seed=42):
    rng = random.Random(seed)
    diffs = []
    for _ in range(n_boot):
        t = [treat[rng.randrange(len(treat))] for _ in treat]
        c = [ctrl[rng.randrange(len(ctrl))] for _ in ctrl]
        diffs.append(sum(t) / len(t) - sum(c) / len(c))
    diffs.sort()
    return diffs[int(0.025 * n_boot)], diffs[int(0.975 * n_boot)]

if __name__ == "__main__":
    lo, hi = bootstrap_ci([1, 0, 1, 1, 0, 1, 1, 1, 0, 1],
                          [0, 1, 0, 0, 0, 1, 0, 0, 0, 0])
    print(f"diff 95% CI = [{lo:.3f}, {hi:.3f}]")
```

| 维度 | 离线指标 | 在线指标 |
| --- | --- | --- |
| 样本 | 固定评测集 | 真实流量 |
| 分布 | 干净、可控 | 脏、漂移 |
| 成本 | 低 | 高（机会成本） |
| 因果性 | 弱（相关） | 强（A/B） |
| 时效 | 滞后 | 实时 |
| 用途 | 回归、选型 | 决策、护栏 |

工程结论：**离线指标负责「别退化」，在线指标负责「有没有用」**。两者不是替代关系，是串联关系。

## 九、分层评测框架与检查清单

### 9.1 五层框架

| 层级 | 手段 | 样本量 | 频率 | 回答的问题 |
| --- | --- | --- | --- | --- |
| L0 规则回归 | 精确匹配、可验证指令 | 全量 | 每次提交 | 有没有把简单事做坏 |
| L1 离线基准 | 代表性评测集 | 1k～10k | 每次发版 | 能力有没有退化 |
| L2 Judge 抽检 | 成对 + 位置交换 | 200～1k | 每周 | 主观质量有没有变化 |
| L3 人工评测 | 分层抽样 + 黄金集 | 100～500 | 每月 | 用户到底怎么想 |
| L4 线上指标 | A/B + 护栏 | 全量流量 | 持续 | 业务有没有变好 |

[IFEval](https://arxiv.org/abs/2311.07911) 是 L0 的好例子：25 类可验证指令（字数 >400、关键词至少出现 3 次等），约 500 条 prompt，程序化判分，零成本零偏差。**能用规则判的，永远不要用模型判。**

### 9.2 上线前检查清单

- [ ] 评测集有版本号，且与判分脚本一起冻结；
- [ ] 评测集做过泄漏检测，结果归档；
- [ ] 关键评测项有黄金集和标注一致性数据；
- [ ] judge 做过位置翻转校准，一致率有记录；
- [ ] 离线分数与线上指标的历史相关性被量化过；
- [ ] 护栏指标（延迟、成本、安全）已纳入发布门槛；
- [ ] 评测集更新后，历史结论的失效范围已评估。

### 9.3 成本与节奏

| 团队阶段 | 建议投入 | 最低配置 |
| --- | --- | --- |
| 早期（<10 人） | 每周 1 次离线 + 每月 1 次人工 | 固定 500 条评测集 + 100 条人工 |
| 成长期 | 每次发版离线 + 双周 judge | 分层评测集 + 位置校准的 judge |
| 成熟期 | 全层级 + 滚动集 | L0-L4 全打通 + 线上护栏 |

预算分配的参考比例：**L0/L1 自动化占大头（算力），L3 人工占小头但不可省**。人工评测省下来的钱，通常会在一次错误选型上加倍还回去。

## 小结

评测体系的本质是「给迭代装仪表盘」，而不是「给模型贴分数」。第一，公开 benchmark 有污染、过拟合、分布错配、口径漂移四个陷阱，只能当能力下限的粗筛。第二，LLM-as-Judge 有位置、长度、自我偏好、格式四类系统性偏差，必须做位置翻转校准，并区分「人类偏好对齐」和「事实正确性判断」两种能力。第三，人工评测的资产是标注指南、黄金集和一致性数据，不是一次性的分数。第四，评测集要像产品一样做版本管理和泄漏检测，滚动更新优先于一次性重构。第五，离线指标和在线指标是串联关系：离线负责别退化，线上负责有没有用。把 L0 规则、L1 离线、L2 Judge、L3 人工、L4 线上五层打通，评测才从汇报工具变回测量工具。

## 参考资料

1. Zheng et al., [Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena](https://arxiv.org/abs/2306.05685), NeurIPS 2023.
2. Chiang et al., [Chatbot Arena: An Open Platform for Evaluating LLMs by Human Preference](https://arxiv.org/abs/2403.04132).
3. Dubois et al., [Length-Controlled AlpacaEval: A Simple Way to Debias Automatic Evaluators](https://arxiv.org/abs/2404.04475), COLM 2024.
4. Liu et al., [G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment](https://arxiv.org/abs/2303.16634).
5. Shi et al., [Judging the Judges: A Systematic Study of Position Bias in LLM-as-a-Judge](https://arxiv.org/abs/2406.07791), AACL-IJCNLP 2025.
6. Tan et al., [JudgeBench: A Benchmark for Evaluating LLM-based Judges](https://arxiv.org/abs/2410.12784), ICLR 2025.
7. Kim et al., [Prometheus 2: An Open Source Language Model Specialized in Evaluating Other Language Models](https://arxiv.org/abs/2405.01535), EMNLP 2024.
8. Gema et al., [Are We Done with MMLU?](https://arxiv.org/abs/2406.04127).
9. White et al., [LiveBench: A Challenging, Contamination-Limited LLM Benchmark](https://arxiv.org/abs/2406.19314), ICLR 2025.
10. Jain et al., [LiveCodeBench: Holistic and Contamination Free Evaluation of Large Language Models for Code](https://arxiv.org/abs/2403.07974).
11. Zhou et al., [Don't Make Your LLM an Evaluation Benchmark Cheater](https://arxiv.org/abs/2311.01964).
12. Xu et al., [Benchmark Data Contamination of Large Language Models: A Survey](https://arxiv.org/abs/2406.04244).
13. Sun et al., [The Emperor's New Clothes in Benchmarking? A Rigorous Examination of Mitigation Strategies for LLM Benchmark Data Contamination](https://arxiv.org/abs/2503.16402).
14. Cao et al., [CODECLEANER: Elevating Standards with A Robust Data Contamination Mitigation Toolkit](https://arxiv.org/abs/2411.10842).
15. Cao et al., [Concerned with Data Contamination? Assessing Countermeasures in Code Language Model](https://arxiv.org/abs/2403.16898).
16. Zhou et al., [Instruction-Following Evaluation for Large Language Models](https://arxiv.org/abs/2311.07911).
17. Hendrycks et al., [Measuring Massive Multitask Language Understanding](https://arxiv.org/abs/2009.03300), ICLR 2021.
18. Lin et al., [TruthfulQA: Measuring How Models Mimic Human Falsehoods](https://arxiv.org/abs/2109.07958), ACL 2022.
19. Srivastava et al., [Beyond the Imitation Game: Quantifying and extrapolating the capabilities of language models](https://arxiv.org/abs/2206.04615), TMLR 2022.
20. Liang et al., [Holistic Evaluation of Language Models](https://arxiv.org/abs/2211.09110), TMLR 2023.
21. Chen et al., [Evaluating Large Language Models Trained on Code](https://arxiv.org/abs/2107.03374).
22. Cohen, J. (1960). A coefficient of agreement for nominal scales. *Educational and Psychological Measurement*, 20(1), 37–46. https://doi.org/10.1177/001316446002000104
23. Landis, J. R., & Koch, G. G. (1977). The measurement of observer agreement for categorical data. *Biometrics*, 33(1), 159–174. https://doi.org/10.2307/2529310
24. Krippendorff, K. (2004). *Content Analysis: An Introduction to Its Methodology*. Sage.
