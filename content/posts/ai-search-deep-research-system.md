---
title: "AI 搜索与 Deep Research 系统设计"
description: "AI 搜索与 Deep Research 的系统设计与评估拆解：查询理解、检索与重排、生成式回答与引用溯源、多步规划与工具循环、忠实度与引用正确性评估、延迟与成本工程，以及与 RAG 的边界和落地清单。"
date: 2026-11-09
categories: ["AI 应用"]
tags: ["AI 搜索", "Deep Research", "检索", "多步推理"]
---

## 引言：AI 搜索的成败取决于「可验证」，而不是「像不像人写的」

过去一年，几乎所有大模型产品都在加同一个功能：联网搜索，或者再进一步，做一份像样的调研报告（Deep Research）。但你应该已经遇到过这些问题：

- 同一个问题，模型答得很流畅，引用的却是另一篇文章里的句子，甚至根本不支持这个结论；
- 换个问法，搜索结果和答案就完全变了，你没法判断哪次更可信；
- 一个简单事实问题跑了 40 秒，成本比直接问一次模型高一个量级；
- 多步研究跑飞了：反复搜同一个关键词，最后交出一份看起来完整、实则漏掉关键数字的报告；
- 线上用户反馈「回答不对」，但你只有一段最终文本，无法归因到底是检索没找到，还是模型读错了。

这些现象指向同一件事：**AI 搜索系统的核心难点不在生成，而在「检索—证据—结论」这条链路的可验证性**。生成模型只要足够强就能写通顺的话；而搜索系统必须能回答三个问题——证据从哪来、结论是否被证据支持、如果错了是哪一环错了。

本文聚焦「搜索 / Deep Research 系统的设计与评估」，不重复站内《RAG 工程化：从向量检索到重排序与评估》已覆盖的切分、Embedding、ANN/HNSW、混合检索、RRF 等通用检索细节，也不重复《大模型评测体系》里的 Benchmark 污染、LLM-as-Judge 偏差、人工评测量表设计。读完你会拿到一套可落地的分解框架：五个环节怎么拆、多步循环怎么控、质量怎么评、延迟和成本怎么算、什么时候该退回普通 RAG。

---

## 一、AI 搜索系统的解剖：五个环节

一次典型的联网问答，数据流可以拆成五个环节。每个环节都有自己的输入契约、失败模式和可观测指标，混在一起谈「搜索效果不好」没有意义。

```text
用户提问
   │
   ▼
① 查询理解    意图识别 / 时效性 / 歧义消解 / 查询改写 / HyDE / 子问题分解
   │
   ▼
② 检索        稀疏(BM25) + 稠密(DPR 类双塔) 并行召回，合并候选
   │
   ▼
③ 重排        交叉编码器或 LLM 排序，截断到上下文预算
   │
   ▼
④ 生成式回答  带引用的答案，而非「一段摘要」
   │
   ▼
⑤ 引用与溯源  每个陈述句 ↔ 来源 URL ↔ 原文片段，可回查
```

### 1.1 查询理解：把一句自然语言变成一条可执行的检索指令

原始 query 往往同时包含多个约束：时间范围（「现在的价格」）、实体指代（「它的最新版本」）、隐含的比较对象、以及用户自己没说清的歧义。查询理解的目标不是「理解」，而是**让下游检索有明确的判别信号**。

| 动作 | 解决的问题 | 典型代价 | 例子 |
| --- | --- | --- | --- |
| 查询改写 | 口语化、错别字、指代不明 | 低（规则或小模型即可） | 「苹果最新手机多少钱」→「Apple iPhone 最新款 售价」 |
| 同义扩展 | 召回不足 | 低到中 | 加入缩写、全称、英文对照 |
| HyDE | 零样本场景下稠密检索对齐差 | 中（先生成假设文档再编码） | 先让模型写一段「可能的答案」，再用它的 embedding 检索 |
| 子问题分解 | 多跳问题无法一次命中 | 中（需要规划能力） | 「A 公司的 CEO 毕业于哪所大学」拆成两步 |
| 澄清反问 | 意图存在多种合理解释 | 高（多一轮交互） | 「你要的是售价还是起售价？」 |

HyDE（Hypothetical Document Embeddings）是这一环的代表性工作：它不直接用原始 query 做 dense retrieval，而是先让模型生成一段假设性答案，用这段答案的向量去检索，在零样本设定下显著优于直接编码 query 的做法 [HyDE](https://arxiv.org/abs/2212.10496)。工程上要注意：**HyDE 把一次检索变成了两次模型调用**，延迟预算要提前算进去。

### 1.2 检索层：稀疏与稠密不是二选一

BM25 这类稀疏检索至今仍是强基线，其概率相关性框架可追溯到 Robertson 与 Zaragoza 对 BM25 的系统性总结 [BM25 and Beyond](https://doi.org/10.1561/1500000019)。稠密检索的价值在于跨措辞的语义匹配：DPR 用双编码器在开放域 QA 上做评测，top-20 段落检索准确率比强 Lucene-BM25 基线绝对高 9%–19% [DPR](https://arxiv.org/abs/2004.04906)。

但这两个数字放在一起容易被误读：**它们测的是不同层面的东西**。BM25 强在精确词面匹配和稀有实体，稠密强在同义改写和概念泛化。生产系统通常两者并行召回再融合，这正是站内 RAG 文章已详细展开的部分，本文不再重复。

真正值得在这里强调的是**检索的粒度契约**：AI 搜索的下游是一个「会引用来源」的生成器，它需要的不是 top-k 文档，而是**能独立支撑一个陈述句的最小证据单元**。检索层输出的单元切得太粗，重排和引用都会失真；切得太碎，又会丢失上下文。这是搜索系统与普通 RAG 的第一个结构差异。

### 1.3 重排：排序质量决定生成上限

召回解决「别漏」，重排解决「别把噪声喂给模型」。两条主流技术路线：

- **交叉编码器重排**：query 和候选拼在一起过模型，打分精准但慢，适合候选量小的场景；
- **LLM 作为排序器**：Sun 等人系统研究了生成式 LLM 直接做相关性排序，发现经过恰当指令的 LLM 在主流 IR 基准上能达到甚至超过有监督 SOTA 方法；为了排除数据污染，他们专门构建了基于最新知识的 NovelEval 测试集 [Is ChatGPT Good at Search?](https://arxiv.org/abs/2304.09542)。

这条路线最大的工程风险是**成本和延迟**：LLM 重排每个 query-doc 对都要一次前向，候选一多就爆炸。所以常见做法是「交叉编码器先砍到 20～50 条，再用 LLM 精排」，而不是全量 LLM 排序。

### 1.4 生成式回答：答案必须是「带证据的论证」

传统搜索返回链接列表，用户自己判断；AI 搜索返回一段话，于是**引用责任转移到了系统身上**。这里有一个必须想清楚的设计选择：引用是「事后贴上去的标签」，还是「生成的约束条件」？

ALCE 是首个系统化研究「让 LLM 生成带引用文本」的基准，覆盖 ASQA、QAMPARI、ELI5 三个数据集，提出三个自动评测维度：流畅性、正确性、引用质量 [ALCE](https://arxiv.org/abs/2305.14627)。它的实验给出了几个反直觉的结论：

- 只在 ELI5 上，最好的模型仍有约 50% 的情况下得不到完整的引用支持；
- ClosedBook（闭卷直接生成）加事后补引用（PostCite）的正确性更好，但引用质量差——在 ASQA 上，ClosedBook+PostCite 的 citation recall 比 Vanilla 低 47%；
- 对检索到的段落做摘要能提升正确性，却不会提升引用质量；
- 交互式检索（边生成边决定要不要再查）在该基准上并没有带来提升；
- 对多个候选生成做重排，能提升人工评估下的引用质量。

**引用质量的本质是「陈述句与证据的局部一致性」，而不是「有没有挂上 URL」**。这直接引出下一节的评估方法。

### 1.5 单次检索 vs 多步检索：什么时候必须多走一步

单轮「一次检索 + 一次生成」在多跳问题上会系统性失败。FRAMES 构建了一个统一评测集，包含 824 道需要整合多个来源的多跳问题，并做了两个基线：无检索时准确率 0.40，而其多步检索流水线准确率 0.66，相对提升超过 50% [FRAMES](https://arxiv.org/abs/2409.12941)。

| 维度 | 单次检索 + 生成 | 多步检索 / 工具循环 |
| --- | --- | --- |
| 适用问题 | 单跳、事实型、词面可命中 | 多跳、比较、时序、需要组合证据 |
| 检索次数 | 1 | 1～N，由模型或策略决定 |
| 延迟 | 低 | 高（每多一轮都叠加） |
| 主要失败 | 漏检、证据不足 | 循环失控、重复检索、证据冲突 |
| 代表证据 | FRAMES 无检索基线 0.40 | FRAMES 多步流水线 0.66 |

工程结论：**多步不是「更高级」，而是「更贵且更危险」**。它只在单跳检索的证据不足以支撑结论时才启用，并且必须有独立的终止与校验机制。第三、四章展开。

---

## 二、上下文工程：位置效应与证据编排

模型拿到一堆证据后，怎么摆进上下文，对最终质量影响极大。

### 2.1 Lost in the Middle：中间位置的证据会被浪费

Liu 等人分析了多文档问答与键值检索两类任务，发现一个稳定现象：当相关信息出现在输入上下文的开头或结尾时性能最好，出现在中间时会显著下降，即使是对长上下文做过专门优化的模型也不例外 [Lost in the Middle](https://arxiv.org/abs/2307.03172)。

这条结论的工程含义很直接：**不要假设「塞得越多越好」**。上下文是稀缺资源，编排本身就是一种排序。

| 策略 | 做法 | 优点 | 代价 |
| --- | --- | --- | --- |
| 全量拼接 | top-k 顺序拼接 | 实现简单 | 中间证据被淹没，成本高 |
| 首尾优先 | 最相关的放两端，次相关放中间 | 符合位置效应，成本不变 | 需要可靠的初排序 |
| 摘要压缩 | 先把长文摘要再拼接 | 省 token | 摘要会丢掉支撑细节，伤引用 |
| 分段引用 | 每个陈述句单独取最小证据片段 | 引用精度高 | 实现复杂，需句级对齐 |

### 2.2 一个可运行的编排函数

下面这段代码实现了「去重 + 位置折扣 + token 预算」的组合，是首尾优先策略的最小版本。注意它只依赖标准库，可直接运行：

```python
#!/usr/bin/env python3
"""上下文编排：去重 + 位置折扣 + token 预算（标准库实现，可直接运行）。"""


def position_weight(rank, n, alpha=0.5):
    """rank 从 0 开始；alpha 越大，越靠后的片段权重越低。"""
    return (1.0 - alpha) + alpha * (1.0 - rank / max(n - 1, 1))


def select_context(chunks, token_limit=6000):
    """chunks: [{'doc_id','start','tokens','score',...}]，按 score 降序贪心选取。"""
    seen, picked, used = set(), [], 0
    ordered = sorted(chunks, key=lambda c: -c["score"])
    for i, ch in enumerate(ordered):
        key = (ch["doc_id"], ch["start"])
        if key in seen:
            continue
        seen.add(key)
        if used + ch["tokens"] > token_limit:
            break
        picked.append({**ch, "weight": round(position_weight(i, len(ordered)), 3)})
        used += ch["tokens"]
    return picked
```

这里的 `alpha` 只是一个可调设计参数，不是论文里的经验值——**位置效应的存在有论文支撑，具体衰减系数必须在自己的评测集上标定**。

### 2.3 长上下文的真实成本

Deep Research 类产品动辄要把几十篇网页塞进上下文。除了 token 费用，还要考虑 KV cache 的显存压力：vLLM 提出的 PagedAttention 通过分页管理 KV cache，把碎片和重复复制降到接近零，在同等延迟下把吞吐提升 2–4 倍，相比当时的 FasterTransformer 和 Orca [PagedAttention](https://arxiv.org/abs/2309.06180)。这说明「长上下文」不只是模型能力问题，也是 serving 层的系统工程问题。

---

## 三、Deep Research：从「搜一次」到「规划—执行—校验」循环

Deep Research 的定义性特征是：自主进行多步网络探索、定向检索和高阶综合，最终交付一份带引用的、达到分析级的报告 [DeepResearch Bench](https://arxiv.org/abs/2506.11763)。它和「联网问答」的差别不在模型，而在**控制流**。

### 3.1 推理与行动如何耦合

三条基础线索奠定了这类系统的基本形态：

- **Chain-of-Thought**：先让模型写出推理过程再给答案，唤醒了大模型的推理能力 [CoT](https://arxiv.org/abs/2201.11903)；
- **ReAct**：把推理轨迹与行动交替进行，模型在每一步既思考又调用外部工具 [ReAct](https://arxiv.org/abs/2210.03629)；
- **ToolLLM**：把上千个真实 API 组织成可调用的工具集，验证了大规模工具调用的可行性 [ToolLLM](https://arxiv.org/abs/2307.16789)。

这些工作的共同点是：**行动的结果会回流成下一步的推理输入**。这就是「循环」的来源，也是所有工程风险的来源。

### 3.2 四种按需检索架构

「什么时候检索、检索到什么程度算够」是这一领域的核心研究问题。四个代表性方案：

| 方案 | 触发机制 | 检索决策者 | 核心创新 | 代表结果 |
| --- | --- | --- | --- | --- |
| Vanilla RAG | 固定次数 | 规则 | 简单稳定 | 多跳问题系统性失败 |
| Self-RAG | reflection tokens | 模型自评 | 自适应按需检索，自我批判 | 长文本事实性与引用准确率提升 |
| CRAG | 轻量检索评估器置信度 | 置信度阈值 | correct / incorrect / ambiguous 三种动作，低置信时用 web search 扩展 | 对检索失败的鲁棒性更好 |
| Search-R1 | RL 训练的策略 | 训练后的策略 | 多轮检索交互 + retrieved token masking 稳定训练 | 7 个 QA 数据集上比 RAG 基线高 41%（Qwen2.5-7B）/ 20%（Qwen2.5-3B） |

- Self-RAG 训练单个模型自适应地按需检索，并用特殊的反思 token 对检索结果和自身生成做批判 [Self-RAG](https://arxiv.org/abs/2310.11511)；
- CRAG 设计了一个轻量的检索评估器，输出置信度并据此触发不同动作，还配了「先分解再重组」的知识处理 [CRAG](https://arxiv.org/abs/2401.15884)；
- Search-R1 用强化学习训练模型在多步推理中自主发起多次检索，并用 retrieved token masking 解决训练不稳定问题 [Search-R1](https://arxiv.org/abs/2503.09516)。

**架构选择的经验法则**：检索质量可控、语料稳定时用 Vanilla；需要抗检索噪声时引入评估器（CRAG 思路）；追求自适应但不想训练时用 prompt + 反思；有训练资源且任务分布稳定时再考虑 RL。

### 3.3 报告类产物的评估维度

Deep Research 的产物是长篇报告，评估维度和短答案完全不同。DeepResearch Bench II 用 132 个 grounded research tasks、22 个领域、共 9,430 条细粒度二元 rubric 来评估，rubric 源自专家撰写的调查报道，覆盖三个维度 [DeepResearch Bench II](https://arxiv.org/abs/2601.08536)：

| 维度 | 关心的问题 | 典型 rubric 例子 |
| --- | --- | --- |
| information recall | 关键事实有没有被找回来 | 「报告是否提到了 X 事件的确切日期」 |
| analysis | 有没有真正的分析增值 | 「是否解释了 X 与 Y 之间的因果关系」 |
| presentation | 结构、可读性、引用规范 | 「是否存在无来源的关键论断」 |

它给出的结论相当冷静：**即使是表现最强的模型，满足的 rubric 也不到一半**。这意味着「让 agent 跑起来」和「让 agent 达标」之间还有很大距离，评估必须先于优化。

---

## 四、工具循环的工程实现：状态、预算与终止条件

把第三章的架构落到代码，核心是一个带状态和预算的循环。下面这个骨架可直接运行，用 mock 工具演示：

```python
#!/usr/bin/env python3
"""Deep Research 工具循环的最小骨架（标准库实现，可直接运行）。"""
from dataclasses import dataclass, field


@dataclass
class Step:
    thought: str
    action: dict
    observation: str = ""


class ResearchLoop:
    def __init__(self, tools, max_steps=8, token_budget=60000):
        self.tools = tools            # {"search": fn(q)->str, "fetch": fn(url)->str}
        self.max_steps = max_steps
        self.token_budget = token_budget
        self.steps = []
        self.spent = 0

    def _safe_call(self, name, arg):
        fn = self.tools.get(name)
        if fn is None:
            return "[error] unknown tool: %s" % name
        try:
            return str(fn(arg))[:4000]        # 硬截断，防止单步吃掉预算
        except Exception as exc:              # 演示容错：记录并继续
            return "[error] %s: %s" % (type(exc).__name__, exc)

    def run(self, question, policy):
        """policy(state) -> ('finish', answer) | ('act', tool_name, arg)。"""
        state = {"question": question, "context": "", "answer": None}
        for _ in range(self.max_steps):
            if self.spent >= self.token_budget:
                break
            decision = policy(state)
            if decision[0] == "finish":
                state["answer"] = decision[1]
                break
            _, tool_name, arg = decision
            obs = self._safe_call(tool_name, arg)
            self.steps.append(Step("", {"tool": tool_name, "arg": arg}, obs))
            state["context"] += "\n" + obs
            self.spent += len(obs)            # 简化：按字符数近似 token
        return state
```

这段代码刻意保持简陋，因为真正需要工程化的是下面这些控制参数：

| 参数 | 作用 | 建议起点 | 调错的后果 |
| --- | --- | --- | --- |
| `max_steps` | 限制循环轮数 | 按任务复杂度设上限，不要用尽 | 死循环、成本失控 |
| `token_budget` | 限制累积上下文 | 先按最长输入 × 轮数估算 | 中途截断导致结论缺证据 |
| 单步输出上限 | 防止单个网页吃光预算 | 硬截断 + 摘要 | 长尾网页挤掉其他证据 |
| 检索去重 | 避免重复抓取同一来源 | URL + 内容哈希双去重 | 证据冗余、视角单一 |
| 证据冲突标记 | 保留矛盾来源而非覆盖 | 记录 source 集合 | 模型只能看到单方说法 |

循环最常见的失败模式及处置：

| 失败模式 | 表现 | 处置 |
| --- | --- | --- |
| 无限循环 | 反复调用同一工具 | 轮数上限 + 相同动作检测 |
| 证据不足仍强行作答 | 结论无引用 | 强制「未满足条件则拒答」分支 |
| 工具不可用 | 超时/限流 | 指数退避 + 降级到缓存或备用源 |
| 证据冲突被抹平 | 只写支持结论的一方 | 显式保留冲突列表，要求报告说明 |
| 事实过时 | 引用了失效数据 | 记录抓取时间，标注时效性 |

**工程结论：循环的上限由预算和终止条件决定，不由模型的自律决定。**

---

## 五、搜索质量评估：忠实度、引用正确性与端到端基准

评估搜索系统最难的地方在于：最终文本的正确性，和「文本是否被证据支持」是两回事。前者可以用标准答案判，后者必须检查证据链。

### 5.1 引用质量的两个指标

ALCE 定义的 citation recall 是逐陈述句的 0/1 判定：一个陈述句当且仅当它至少有一个引用，且这些引用文本蕴含该陈述句时记 1 [ALCE](https://arxiv.org/abs/2305.14627)。 citation precision 则检测无关引用，且不要求引用集最小化——因为人类写作本来就常引用冗余来源。

下面是最小可运行的实现，NLI 部分留了接口：

```python
#!/usr/bin/env python3
"""引用质量的最小实现：citation recall / precision（标准库，可直接运行）。"""
from dataclasses import dataclass, field


@dataclass
class Statement:
    text: str
    citations: list = field(default_factory=list)   # [(url, passage), ...]


def nli_entails(passages, claim):
    """占位：真实项目接 NLI 模型，判断 passages 是否蕴含 claim。"""
    raise NotImplementedError("replace with a real NLI model call")


def citation_recall(statements):
    scored = []
    for st in statements:
        if not st.citations:
            scored.append(0.0)
            continue
        support = [p for _, p in st.citations]
        scored.append(1.0 if nli_entails(support, st.text) else 0.0)
    return sum(scored) / len(scored) if scored else 0.0


def citation_precision(statements):
    total, irrelevant = 0, 0
    for st in statements:
        for _, passage in st.citations:
            total += 1
            if not nli_entails([passage], st.text):
                irrelevant += 1
    return 1.0 - irrelevant / total if total else 1.0
```

**这两个指标的陷阱**：它们依赖 NLI 模型的质量。ALCE 自己在附录里承认，受限于 NLI 无法识别「部分支持」，无关引用的检测会有较高假阳性。所以引用指标必须和人工抽检一起看，不能当成绝对真值。

### 5.2 事实性评估：FELM 的启示

FELM 把事实性评估从「世界知识」扩展到数学、推理、科技、写作推荐等多个领域，采用 segment 级标注，并给出预定义错误类型和支持/反驳的参考链接 [FELM](https://arxiv.org/abs/2310.00741)。它的一个关键设计是：每条回答由两名专家标注，平均一致率 90.7%，全库共 817 个样本、3,948 个片段，整体回答级错误率 31.8%。

这组数字的用处是双向的：一方面说明 segment 级标注是可行的（一致率足够高），另一方面说明「用 LLM 检测 LLM 的事实错误」远未成熟——即使检索增强和 CoT 都用上，检测器仍然不够可靠。

### 5.3 端到端基准横向对比

| 基准 | 规模 | 考察能力 | 判分方式 | 已知局限 |
| --- | --- | --- | --- | --- |
| [FRAMES](https://arxiv.org/abs/2409.12941) | 824 道多跳题 | 事实性、检索、推理 | 参考答案 | 只覆盖 Wikipedia 场景 |
| [GAIA](https://arxiv.org/abs/2311.12983) | 466 题 | 推理、多模态、浏览、工具使用 | 简短答案精确匹配 | 答案保密部分占多数，难以复现 leaderboard |
| [BrowseComp](https://arxiv.org/abs/2504.12516) | 1,266 题 | 持久浏览、寻找难找信息 | 短答案验证 | 不反映真实用户查询分布 |
| [DeepResearch Bench](https://arxiv.org/abs/2506.11763) | 100 个 PhD 级任务，22 领域 | 报告质量、检索与引用 | 参考报告自适应标准 + 引用计数/准确性 | 人工验证规模有限 |
| [DeepResearch Bench II](https://arxiv.org/abs/2601.08536) | 132 任务，9,430 条 rubric | 信息召回、分析、呈现 | 二元 rubric | 依赖专家报告派生标准 |

几个可以直接用的数字：

- GAIA：人类得分 92%，而带插件的 GPT-4 只有 15% [GAIA](https://arxiv.org/abs/2311.12983)；
- BrowseComp：1,266 道题，答案短、易验证，专测持久浏览能力 [BrowseComp](https://arxiv.org/abs/2504.12516)；
- FRAMES 在数据收集三个月后重新核对答案，过滤掉了 5.5% 答案已不再成立的样本——**时效性本身就是一个需要标注的维度**；
- DeepResearch Bench 的任务分布来自对超过 96,000 条真实用户查询的统计分析，而不是拍脑袋分配领域比例；它的人工验证规模是 3 名专家 × 50 个任务 × 4 个 agent = 600 篇报告，单份报告的人工评审需要 30–60 分钟 [DeepResearch Bench](https://arxiv.org/abs/2506.11763)。

最后一点尤其重要：**如果评估一份报告要半小时人工，那么高频回归就是不可能的**。这决定了工程上必须把「LLM-as-Judge + 小规模人工校准」作为主干，而不是反过来。

### 5.4 自动指标与人工评测的分工

| 层级 | 手段 | 样本量 | 频率 | 回答的问题 |
| --- | --- | --- | --- | --- |
| L0 规则 | 引用格式、URL 可达性、时效标记 | 全量 | 每次请求 | 有没有明显违规 |
| L1 离线集 | 固定 query 集 + 标准答案 | 500～2k | 每次发版 | 能力有没有退化 |
| L2 引用检查 | NLI/支持度模型 | 200～1k | 每周 | 结论是否被证据支持 |
| L3 人工抽检 | 分层抽样 + 黄金集 | 100～300 | 每月 | 用户到底怎么判断 |
| L4 在线指标 | 追问率、点踩、引用点击 | 全量流量 | 持续 | 业务有没有变好 |

### 5.5 引用环节的典型失败模式

| 失败模式 | 具体表现 | 检测手段 |
| --- | --- | --- |
| 引用漂移 | 挂了 URL 但段落不支持结论 | citation precision + NLI |
| 过度引用 | 每个句子挂一堆无关来源 | 引用密度异常 + 支持度 |
| 来源单点化 | 整篇只用一两个来源 | 来源多样性统计 |
| 事实过时 | 引用了失效数据 | 抓取时间戳 + 时效性复核 |
| 检索到但没用 | 证据在上下文里被模型忽略 | 引用覆盖 vs 生成陈述句比对 |

---

## 六、延迟与成本工程

搜索系统的成本和延迟都不是「一次模型调用」那么简单，而是五段链路之和。

```text
L_total = T_query_understanding + T_retrieve + T_rerank + T_generate + T_render
C_total = Σ_i (in_tok_i · p_in + out_tok_i · p_out) / 1e6
```

其中生成段通常是大头，而且**多步循环会把它乘上轮数**。这就是为什么 Deep Research 的单次成本可能比普通问答高一个量级。

### 6.1 降低生成侧成本的三条成熟路径

| 手段 | 原理 | 论文依据 | 代价 |
| --- | --- | --- | --- |
| PagedAttention / 连续批处理 | KV cache 分页，消除碎片与重复复制 | 同等延迟下吞吐提升 2–4× [vLLM](https://arxiv.org/abs/2309.06180) | 需要 serving 层改造 |
| 投机解码 | 小模型先并行起草，大模型并行校验，输出分布不变 | T5-XXL 上 2X–3X 加速 [投机解码](https://arxiv.org/abs/2211.17192) | 需要配对的小模型与实现 |
| IO 感知注意力 | tiling 减少 HBM 与 SRAM 之间的读写 | FlashAttention 是精确算法而非近似 [FlashAttention](https://arxiv.org/abs/2205.14135) | 已有成熟库，主要是选型问题 |

除模型侧之外，架构侧的杠杆更大也更便宜：

- **流式输出**：让用户在首字节后就开始阅读，体感延迟远低于完整生成时间；
- **分级路由**：简单问题走小模型或缓存，复杂问题才启动多步循环；
- **缓存复用**：同 query 的检索结果、embedding、页面解析结果都可缓存；
- **预算前置**：在循环开始前分配好每轮的 token 配额，而不是事后统计。

### 6.2 成本记账的最小实现

```python
#!/usr/bin/env python3
"""多步研究任务的成本记账（标准库，可直接运行；价格为占位符）。"""
from dataclasses import dataclass


@dataclass
class Usage:
    input_tokens: int = 0
    output_tokens: int = 0
    calls: int = 0


class Budget:
    def __init__(self, price_in_per_mtok, price_out_per_mtok, max_usd=5.0):
        self.price_in = price_in_per_mtok
        self.price_out = price_out_per_mtok
        self.max_usd = max_usd

    def cost_usd(self, usage):
        return (usage.input_tokens * self.price_in
                + usage.output_tokens * self.price_out) / 1_000_000

    def is_over(self, usage):
        return self.cost_usd(usage) > self.max_usd
```

这里的 `price_*` 必须填你自己所用的真实单价，**本文不提供任何具体价格数字**——模型定价变化频繁，任何写死的数字都会很快过期。工程上要盯的是结构比例：检索本身通常很便宜，模型调用才是主项；而模型调用里，长上下文输入的占比会随循环轮数上升。

---

## 七、与 RAG 的关系和边界

三者经常被混为一谈，但它们的契约不同：

| 维度 | 普通 RAG | AI 搜索 | Deep Research |
| --- | --- | --- | --- |
| 知识源 | 静态私有语料 | 实时公开网络 | 实时公开网络 |
| 检索轮次 | 通常 1 次 | 1～N 次 | N 次，带规划 |
| 输出形态 | 短答案 / 片段 | 带引用的答案 | 长篇带引用的报告 |
| 时效性 | 取决于索引更新 | 取决于抓取时刻 | 取决于抓取时刻 |
| 主要风险 | 召回失败、上下文噪声 | 引用不可信、来源冲突 | 循环失控、成本失控、覆盖不全 |
| 合适场景 | 企业知识库、客服 | 事实问答、资讯汇总 | 行业调研、竞品分析、学术综述 |

判断该用哪一个，可以看三个问题：

1. **知识在哪？** 在私有文档里 → RAG；在公开网络 → 搜索 / Deep Research。
2. **答案要多长？** 一两句话 → 单次检索；一篇报告 → Deep Research。
3. **允许多慢、花多少？** 有严格延迟预算 → 不要多步循环。

一个常见的错误是把 Deep Research 当成「加强版 RAG」：给知识库接一个联网工具，然后让模型自由发挥。这会导致检索策略和知识源契约不匹配——私有语料要的是精确召回和可审计的引用，公开网络要的是抗噪、去重和时效判断。**架构选型的第一步是确认知识源契约，不是选模型。**

与站内已有文章的分工：检索管道的实现细节（切分、Embedding、ANN、混合检索、重排模型对比）见《RAG 工程化：从向量检索到重排序与评估》；Benchmark 污染、LLM-as-Judge 偏差、人工评测量表见《大模型评测体系》。本文只覆盖搜索与 Deep Research 特有的部分：查询理解、引用溯源、多步控制流、搜索/研究报告评估、延迟成本工程。

---

## 八、落地清单

### 8.1 分阶段路线

| 阶段 | 目标 | 必做项 | 可选项 |
| --- | --- | --- | --- |
| MVP | 能答对单跳事实题 | 查询改写 + 单次检索 + 带引用生成 + 引用格式校验 | HyDE、轻量重排 |
| 进阶 | 能处理多跳与资讯汇总 | 按需检索策略、检索去重、时效标记、引用支持度检查 | CRAG 式评估器、LLM 重排 |
| 生产 | 能交付报告并可控成本 | 多步循环预算、终止条件、冲突标注、离线评测集、在线护栏 | RL 训练检索策略 |

### 8.2 上线前检查清单

- [ ] 每个生成陈述句都有来源，且来源可被独立打开核验；
- [ ] 引用支持度检查（NLI 或等价方法）已接入离线集，并有假阳性抽检记录；
- [ ] 检索去重覆盖 URL 与内容两个层面；
- [ ] 循环有明确的最大轮数、token 预算、单步输出上限；
- [ ] 工具超时与限流有退避与降级路径；
- [ ] 事实类结论标注了抓取时间，过时来源有提示；
- [ ] 离线评测集有版本号，检索语料快照与评测结果一并归档；
- [ ] 延迟与成本的 P95 已测量，并与业务预算对齐；
- [ ] 护栏指标（引用覆盖率、无来源陈述比例、单任务成本）已配置告警。

### 8.3 护栏指标示例

下面列出需要监控的量，但**阈值必须在自己的流量上标定**，表中数值只是形式示例：

| 指标 | 含义 | 示例阈值 | 触发动作 |
| --- | --- | --- | --- |
| 无来源陈述占比 | 生成中没有任何引用的句子比例 | > 10% 告警 | 检查检索是否失效 |
| 引用支持度均值 | NLI 支持比例 | 低于基线 10% 告警 | 检查排序与切片 |
| 单任务平均轮数 | 循环长度 | 超过 P95 预算告警 | 检查是否陷入循环 |
| 单任务成本 | 累计模型花费 | 超预算即熔断 | 降级到单次检索 |
| 用户追问率 | 同一会话内重复提问 | 环比上升告警 | 排查答案可用性 |

---

## 小结

第一，AI 搜索系统的核心是可验证性：查询理解、检索、重排、生成、引用溯源五个环节各自有独立契约，任何一个环节断裂都会表现为「答案不可信」，但解法完全不同。第二，引用质量是局部一致性问题，citation recall 要求陈述句被引用文本蕴含，citation precision 检测无关引用，二者都必须与人工抽检结合，因为 NLI 本身会出错。第三，多步检索不是更高级而是更贵更危险：FRAMES 显示多跳问题无检索准确率 0.40、多步流水线 0.66，但循环必须由预算、终止条件和去重机制约束，而不是靠模型自律。第四，Deep Research 的评估必须落在细粒度 rubric 上——DeepResearch Bench II 表明最强模型也满足不到一半的 rubric，评估先行于优化。第五，延迟和成本的主项在生成侧且随轮数放大，投机解码、PagedAttention、流式输出和分级路由是四条已被论文验证的路径，但具体收益必须在自己链路上实测。最后，架构选择先看知识源契约：静态语料用 RAG，实时网络用搜索，长报告用 Deep Research，不要用同一个管道硬扛三种需求。

## 参考资料

1. Lewis et al., [Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks](https://arxiv.org/abs/2005.11401), NeurIPS 2020.
2. Karpukhin et al., [Dense Passage Retrieval for Open-Domain Question Answering](https://arxiv.org/abs/2004.04906), EMNLP 2020.
3. Gao et al., [Precise Zero-Shot Dense Retrieval without Relevance Labels](https://arxiv.org/abs/2212.10496), ACL 2023.
4. Robertson, S., & Zaragoza, H., [The Probabilistic Relevance Framework: BM25 and Beyond](https://doi.org/10.1561/1500000019), Foundations and Trends in Information Retrieval, 2009.
5. Sun et al., [Is ChatGPT Good at Search? Investigating Large Language Models as Re-Ranking Agents](https://arxiv.org/abs/2304.09542), EMNLP 2023.
6. Liu et al., [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172), TACL 2024.
7. Gao et al., [Enabling Large Language Models to Generate Text with Citations](https://arxiv.org/abs/2305.14627), EMNLP 2023.
8. Asai et al., [Self-RAG: Learning to Retrieve, Generate, and Critique through Self-Reflection](https://arxiv.org/abs/2310.11511), ICLR 2024.
9. Yan et al., [Corrective Retrieval Augmented Generation](https://arxiv.org/abs/2401.15884), 2024.
10. Jin et al., [Search-R1: Training LLMs to Reason and Leverage Search Engines with Reinforcement Learning](https://arxiv.org/abs/2503.09516), 2025.
11. Yao et al., [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629), ICLR 2023.
12. Wei et al., [Chain-of-Thought Prompting Elicits Reasoning in Large Language Models](https://arxiv.org/abs/2201.11903), NeurIPS 2022.
13. Qin et al., [ToolLLM: Facilitating Large Language Models to Master Over 16,000 Real-world APIs](https://arxiv.org/abs/2307.16789), ICLR 2024.
14. Chen et al., [FELM: Benchmarking Factuality Evaluation of Large Language Models](https://arxiv.org/abs/2310.00741), NeurIPS 2023 D&B.
15. Krishna et al., [Fact, Fetch, and Reason: A Unified Evaluation of Retrieval-Augmented Generation](https://arxiv.org/abs/2409.12941), NAACL 2025.
16. Du et al., [DeepResearch Bench: A Comprehensive Benchmark for Deep Research Agents](https://arxiv.org/abs/2506.11763), 2025.
17. Li et al., [DeepResearch Bench II: Diagnosing Deep Research Agents via Rubrics from Expert Reports](https://arxiv.org/abs/2601.08536), 2026.
18. Mialon et al., [GAIA: a benchmark for General AI Assistants](https://arxiv.org/abs/2311.12983), ICLR 2024.
19. Wei et al., [BrowseComp: A Simple Yet Challenging Benchmark for Browsing Agents](https://arxiv.org/abs/2504.12516), 2025.
20. Kwon et al., [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180), SOSP 2023.
21. Leviathan et al., [Fast Inference from Transformers via Speculative Decoding](https://arxiv.org/abs/2211.17192), ICML 2023.
22. Dao et al., [FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness](https://arxiv.org/abs/2205.14135), NeurIPS 2022.
