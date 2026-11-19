---
title: "向量数据库选型与工程：HNSW、混合检索与重排"
description: "从索引结构到召回质量：拆解 HNSW 图索引的参数与代价，IVF/PQ 的压缩与取舍，说明混合检索与交叉编码器重排的 pipeline，给出按数据规模与过滤需求落地的选型清单与可观测性指标。"
date: 2026-11-19
categories: ["AI 应用"]
tags: ["向量数据库", "HNSW", "混合检索", "重排"]
---

## 引言：向量数据库选型的分歧点不在"能不能存"，而在"以什么代价存"

2023 年之后，"要不要引入向量数据库"这个问题基本已经不需要争论了。只要业务里出现了"用自然语言找东西"的需求，就一定会落到一块能存 embedding、能做近邻检索的存储上。于是选型讨论迅速退化成另一种无聊的形态：比谁的功能列表长、谁支持更多距离度量、谁的写入吞吐数字更大。

这种比较几乎没有工程价值。因为决定向量检索系统成败的，从来不是功能列表的长度，而是三个非常具体的问题：

- **你的召回率要求和延迟预算各是多少？** 同一份数据，HNSW 的 `M=16` 和 `M=64` 之间有一倍的内存差距和明显的召回率差距；这直接决定了索引参数怎么调，而不是决定用哪个数据库。
- **你的查询带不带过滤条件？** 带过滤的向量检索和纯向量检索是**两套算法**，不是同一套算法的加一个 WHERE 条件。
- **你的语料里有没有"精确词"？** 如果用户搜的是产品型号、错误码、人名、专有名词，那么纯 dense 检索大概率会漏召回，混合检索几乎是必选项。

本文要做的，是把这三个问题背后的**机制**讲清楚，让你能在拿到具体选型需求时，自己判断某个候选方案是否合适，而不是照着别人的 benchmark 数字抄。

全文区分三类陈述：

- **已确认**：有论文、官方文档或源码可以直接支撑的机制与数字。
- **工程经验**：业界常见做法，数字随场景变化，需要在自己的流量上验证。
- **待验证**：需要你用自己的数据做实验才能确定的结论。

---

## 一、HNSW 到底在做什么：先理解图结构，再理解参数

### 1.1 多层邻近图的基本构造

HNSW（全称 Hierarchical Navigable Small World）的原始论文是 Malkov 与 Yashunin 2016 年的《Efficient and robust approximate nearest neighbor search using Hierarchical Navigable Small World graphs》（arXiv:1603.09320，v4 于 2018-08-14 更新）。论文的核心贡献是：**用一个纯粹的图结构实现近邻索引，不需要额外维护一个粗量化结构**（这一点是相对 IVF 的关键区别，后面会讲）。

其构造方式可以理解为跳表（skip list）的图化版本：

1. **分层**：每个元素被分配一个最高层数 `L`。层的分布服从指数衰减——第 `l` 层存在的概率正比于 `1/ln(M)` 量级的衰减因子。绝大多数元素只在第 0 层（也叫 base layer），少数元素会出现在第 1、2……层。
2. **层内连接**：同一层内的元素互相连接，每个元素最多保留 `M` 个邻居。
3. **跨层关系**：第 `l` 层的元素必然存在于第 `l-1` 层（层级嵌套）。
4. **搜索过程**：从最高层的入口点（entry point）出发，做贪心下降——在当前层不断走向离查询更近的邻居，直到当前层无法继续改善；然后下沉一层重复这个过程。到达第 0 层后，用一个候选集做更宽的探索。

论文把这种"上层稀疏粗定位、下层密集细搜"的结构利用描述为**尺度分离（scale separation）**带来的收益：搜索复杂度近似为 `O(log(N))`（这是论文在特定假设下的结论，实际表现与数据分布强相关）。

### 1.2 层级分配与 `M` 的定量含义

论文及 hnswlib 实现中，层级按指数衰减随机分配。hnswlib（nmslib/hnswlib 的 `hnswlib/hnswalg.h`）的具体实现是：

```cpp
int getRandomLevel(double reverse_size) {
    std::uniform_real_distribution<double> distribution(0.0, 1.0);
    double r = -log(distribution(level_generator_)) * reverse_size;
    return (int) r;
}
```

其中 `reverse_size = 1 / mult_`，而 `mult_ = 1 / log(1.0 * M_)`。也就是说：

- 分配到第 1 层及以上的概率是 `exp(-1/M)`。`M=16` 时约 `6.1%`，`M=64` 时约 `1.5%`。
- 分配到第 2 层及以上的概率是 `exp(-2/M)`。`M=16` 时约 `0.38%`。

这个公式直接解释了 HNSW 的一个重要工程特性：**`M` 越大，图越"稠密"，高层节点越少，搜索的下降阶段越短，但每个节点的内存占用和建图成本线性上升。**

### 1.3 邻居选择启发式：HNSW 真正的算法贡献

HNSW 不是"随便连 M 个最近邻"。论文明确指出，朴素的连边方式在高召回率需求和**高度聚簇的数据**上会显著劣化性能，原因是：在密集区域里，一个点的 M 个最近邻往往全部来自同一个簇，导致图上出现大量"小世界捷径缺失"，搜索容易被困在局部。

hnswlib 中的对应实现是 `getNeighborsByHeuristic2`：

```cpp
for (std::pair<dist_t, tableint> second_pair : return_list) {
    std::pair<dist_t, tableint> curdist = ...
    if (curdist < dist_to_query) {
        good = false;   // 候选点离已选中的近邻太近 → 丢弃
        break;
    }
}
if (good) {
    return_list.push_back(curent_pair);
}
```

语义是：**如果一个候选邻居与已经选中的某个邻居之间的距离，小于它到查询（或插入点）的距离，就把它丢弃。** 直观解释是——如果 B 和 C 都很靠近 A（B 和 C 之间也近），那么 A 保留 B 就够了，再连 C 是冗余；保留 B、C 中更远的那个反而能覆盖更广的方向，使得图在各个方向上都有边可走。

论文的实验结论是：这一启发式在高召回率与高度聚簇数据上带来显著性能提升。**工程经验**：如果你的 embedding 分布存在明显的簇结构（比如按业务线、文档类型聚类），这个启发式的收益会更明显；反之，如果数据是在近似均匀球面上分布的，收益会小一些。

### 1.4 出度不对称：`M` 与 `2M`

hnswlib 的实现里有两套出度上限：

```cpp
maxM_  = M_;       // level > 0 的链接上限
maxM0_ = M_ * 2;   // level 0 的链接上限
```

第 0 层的出度是 `M` 的两倍。这是一个经过时间检验的设计：**基座层承担了绝大部分的实际距离计算**（搜索最终都在第 0 层展开），而高层只负责"引路"，不需要那么多出度。

同时注意 `ef_construction_ = std::max(ef_construction, M_)`——`ef_construction` 有一个硬下限是 `M`，因为建图时候选集至少要能容纳 `M` 个候选，否则邻居选择启发式无法正常工作。

### 1.5 三个参数的工程含义

综合论文与 hnswlib 默认值（`M = 16`、`ef_construction = 200`、`ef = 10`）：

| 参数 | 作用 | 增大后的效果 | 主要代价 |
| --- | --- | --- | --- |
| `M` | 图的稠密度 / 每节点出度 | 召回率↑，搜索步数↓，图内存和建图时间线性↑ | 索引内存、建图耗时 |
| `ef_construction` | 建图时的候选集宽度 | 图质量↑（连接更接近最优） | 建图时间近似线性↑ |
| `ef` | 查询时的候选集宽度 | 召回率↑，延迟↑ | 查询延迟、QPS |

搜索时，hnswlib 实际使用的候选集大小是 `std::max(ef_, k)`——所以当你要返回的条数 `k` 大于 `ef` 时，会自动抬到 `k`。

**已确认**：`ef` 是**查询时**的旋钮，不影响索引结构。同一个索引可以用不同的 `ef` 服务不同延迟档位的请求——高优先请求用大 `ef` 换召回率，低优先请求用小 `ef` 换吞吐。这点在多租户或多 SLA 场景下非常有用。

**工程经验**：一个常见的错误是把 `ef` 当成"越大越好"的全局参数固定。正确的做法是把它当作**可动态调节的延迟-召回率旋钮**，配合监控在高峰时自动降级。

---

## 二、IVF 与 PQ：另一种思路的代价结构

### 2.1 IVF 的思路：先粗分桶，再桶内搜索

IVF（Inverted File）系列是另一条主线。它的思路是：

1. 用 k-means 把整个向量空间划分成 `nlist` 个簇（一个"粗量化器"）。
2. 每个向量存到它所属簇的倒排列表（posting list）里。
3. 查询时，用同一个粗量化器把查询向量分配到 `nprobe` 个簇，然后只在这 `nprobe` 个簇的倒排列表内做精确（暴力）距离计算。

FAISS 的 C++ API 提供了一整套 IVF 变体：`IndexIVFFlat`、`IndexIVFPQ`、`IndexIVFPQR`、`IndexIVFScalarQuantizer`、`IndexIVFFastScan` 等。

与 HNSW 的关键差别：

- **HNSW 是纯图结构**，没有粗量化层；**IVF 有一层粗量化**，查询时需要额外做一次粗量化器分配（通常是 k-means 的向量与查询的内积计算）。
- **IVF 查询成本主要由 `nprobe/nlist` 决定**：如果 `nprobe = 1` 且 `nlist = 10000`，你只扫描了 0.01% 的数据。
- **IVF 对数据分布变化更敏感**：k-means 训练出的簇边界是静态的，数据分布漂移后需要重新训练。

### 2.2 PQ：把向量压缩成短码

PQ（Product Quantization）把一个 `d` 维向量切成 `M` 个子空间，每个子空间用 `M` 维码本表示（码本由 k-means 训练得到），每个子向量用它在码本中的索引编号代替。

FAISS 的 `IndexIVFPQ` 构造签名是：

```cpp
IndexIVFPQ(Index *quantizer, size_t d, size_t nlist, size_t M,
           size_t nbits_per_idx, MetricType metric = METRIC_L2);
```

官方语义是"倒排文件 + 乘积量化编码，每个残差向量编码为一个 PQ code"。其中 `nbits_per_idx` 是每个子空间码的位数，因此**每个向量的压缩后长度为 `M × nbits_per_idx / 8` 字节**。

举例：`d = 768`（典型的 768 维 embedding）、`M = 96`、`nbits_per_idx = 8` → 每向量 96 字节，相比 float32 的 3072 字节是 **32 倍压缩**。代价是距离计算变成查表累加（ADC），精度有损。

FAISS 还提供了几个配套组件：

- `faiss::OPQMatrix`：优化 PQ 的子空间划分（旋转矩阵 + 训练），减少量化误差。
- `faiss::ScalarQuantizer`：`SQ8` 等标量量化，`SQ8` 即每维一个 int8。
- `faiss::IndexRefine` / `IndexRefineFlat`：**粗排 + 精排**结构——用粗索引选出候选，再用精确原始向量重算距离。`IndexIVFPQ::search_preassigned` 支持 `store_pairs`，可以存下倒排列表的 index+offset，**专门用于 reranking 场景**：粗排时用压缩码算粗略距离，精排时用原始向量精排。

这个 `search_preassigned` + `store_pairs` 的组合非常值得注意：**它是很多生产系统"粗排用压缩索引 + 精排用原始向量"的标准实现路径**，让存储成本和召回质量可以部分解耦。

### 2.3 其他索引变体

FAISS 索引目录中还包含：

- `IndexNSG` 系列（`IndexNSGFlat` / `IndexNSGPQ` / `IndexNSGSQ`）：NSG（Navigating Spreading-out Graph）是另一条图索引路线，设计目标是比 HNSW **更快的构建速度**，并支持免训练直接插入。
- `IndexHNSWCagra`：FAISS 提供的 CAGRA（GPU 加速的图检索）实现。
- `IndexHNSW2Level`：两层结构的 HNSW，把 HNSW 的层级与 IVF 的粗量化结合，兼顾两者优点。
- `IndexNNDescent`：基于反向近邻的构图方法，无训练集要求。

**工程经验**：选型时不需要逐个试完这些变体。实用路径是——先用 `IndexFlat`（暴力精确检索）建立一个**真值基线**，然后用你的真实数据测量各候选索引在同等召回率下的延迟和内存，倒退选择。

### 2.4 HNSW 与 IVF 的对照

| 维度 | HNSW | IVF + PQ |
| --- | --- | --- |
| 索引结构 | 多层邻近图，无粗量化层 | k-means 粗量化 + 倒排列表 |
| 构建成本 | 高（需 `ef_construction` 候选集） | 中（需 k-means 训练 + 批量编码） |
| 增量写入 | 友好（逐点插入） | 需定期重排/重建，倒排列表会碎片化 |
| 内存 | 向量原样存储 + 图结构开销 | 可大幅压缩（PQ/SQ） |
| 调参维度 | `M`、`ef_construction`、`ef` | `nlist`、`nprobe`、PQ 的 `M`/`nbits` |
| 对分布漂移敏感度 | 中（插入时局部修复连接） | 高（簇边界静态） |
| 典型适用 | 在线写入、内存充裕、召回敏感 | 语料静态、内存受限、超大规模 |

**工程经验**：不要用"哪个更快"来选，而要用"**哪个在我的写入模式和资源约束下更省心**"来选。频繁增删改 + 数据量中等 → HNSW；语料相对静态 + 数据量大到内存放不下原始向量 → IVF + 量化压缩。

---

## 三、带过滤的检索：这是最容易被低估的复杂度

### 3.1 问题本质

"只在我这个租户/这个文档类型/这个时间范围里搜最相似的"——这是企业场景里几乎最常见的向量检索需求。它有两种实现思路：

- **后过滤（post-filtering）**：先在全库取 top-k，再把不符合过滤条件的丢掉。
- **预过滤（pre-filtering）**：在搜索过程中就只考虑满足条件的元素。

后过滤在过滤条件选择性高时（例如只保留 1% 的数据）几乎必然失效：为了填满 top-k，搜索引擎需要从全库取回远多于 k 的候选，然后丢掉 99%。

### 3.2 Qdrant 的做法：payload index + 布尔过滤

Qdrant 官方文档对过滤机制给出了明确的工程建议（见 https://qdrant.tech/documentation/search/filtering/ ）：

- **对计划用于过滤的字段建立 payload index，并且最好在写入数据之前就建好索引。**
- 过滤子句支持 `must`（AND）、`should`（OR）、`NOT`，并且可以递归嵌套成任意布尔表达式。
- 过滤可以作用在 payload（附加属性）和 id 上。

一个典型的过滤写法（Python SDK）：

```python
from qdrant_client import models

results = client.search(
    collection_name="articles",
    query_vector=embedding,
    query_filter=models.Filter(
        must=[
            models.FieldCondition(
                key="tenant_id",
                match=models.MatchValue(value="acme"),
            ),
            models.FieldCondition(
                key="year",
                range=models.Range(gte=2024),
            ),
        ],
        should=[
            models.FieldCondition(
                key="tags",
                match=models.MatchAny(any=["llm", "rag"]),
            ),
        ],
    ),
    limit=10,
)
```

### 3.3 为什么"先建索引"这条建议如此重要

这一条是实践中最常见的性能坑，原因可以从原理推出来：

**payload index 的作用是让系统能在候选生成阶段快速回答"哪些元素满足条件"。** 没有索引时，这个查询只能扫描全部元素的 payload（post-filter）或退化为全量扫描（pre-filter）；有了索引时，可以先按索引定位到满足条件的子集，再在该子集内做近邻搜索。

如果索引是**先写入后建立**的，新写入的数据在索引建立之后如果没有被正确纳入（或建立了索引但写入路径没维护它），就会出现**"明明数据存在但搜不到"**的诡异 bug——过滤条件越具体越容易触发。这类问题排查起来极其痛苦，因为数据确实在库里。

**工程经验**：把"过滤字段的索引创建"纳入数据模型的**初始化脚本**（migration），和建表一起，不要留到出问题后再补。

### 3.4 选型时要问的问题

评估一个向量数据库的过滤能力，问这几个具体问题：

1. 过滤是在 ANN 搜索**内部**完成的，还是先查过滤结果再交给 ANN？
2. 过滤字段是否需要显式建索引？索引是**延迟维护**还是**同步维护**？
3. 过滤条件的**选择性**（命中比例）有多大时的行为是文档化的？
4. 组合过滤（多字段 AND/OR/NOT）是否支持，是否会退化成全表扫描？
5. 过滤和 ANN 参数（`ef` / `nprobe`）如何交互？

---

## 四、混合检索与重排：纯 dense 检索的固有缺陷

### 4.1 dense 检索在"精确词"上的弱点

dense 检索（基于 embedding 的相似度）把语义信息压缩进固定维度的向量。它的优点是能匹配同义表达，缺点是**对罕见的、精确的、有区分度的 token 区分度不足**。

典型失败场景：

- 用户搜错误码 `ECONNRESET` 或产品型号 `HT-2000`，语义相近的文档可能很多，但真正包含该错误码的文档很少。
- 实体名、人名、法律条款编号、代码标识符 —— 这些恰恰是用户最希望"精确命中"的查询。
- 长尾查询：embedding 模型在训练分布内很流畅，在分布外（用户的私有术语、缩写、黑话）容易"语义漂移"。

### 4.2 官方推荐的两阶段 pipeline

HuggingFace sentence-transformers 的官方文档给出了标准的 retrieve & re-rank 流程（见 https://raw.githubusercontent.com/UKPLab/sentence-transformers/master/examples/sentence_transformer/applications/retrieve_rerank/README.md ）：

**第一阶段（retrieve）**：用检索系统取回约 100 个候选。可以是：
- **词法检索（lexical）**：如 Elasticsearch / BM25 这类基于词项匹配的引擎；
- **稠密检索（dense）**：用 bi-encoder（如 SentenceTransformer）编码查询和文档。

**第二阶段（re-rank）**：用 **cross-encoder** 对这约 100 个候选重新打分，取 top-5。

### 4.3 bi-encoder 与 cross-encoder 的本质差异

| 维度 | bi-encoder（稠密检索） | cross-encoder（重排） |
| --- | --- | --- |
| 输入 | query 和 document **分别**编码 | query 和 document **拼接后一起**编码 |
| 输出 | 向量 / 余弦相似度 | 0~1 的相关性分数 |
| 能否预计算 | 文档向量可离线预计算 | 不能，必须在线逐对推理 |
| 精度 | 较低 | 较高 |
| 成本 | 可支撑百万级甚至更大规模 | 官方明确指出"对成千上万个 (query, document) 对打分相当慢" |

精度差异的根源在于 attention 的可见性：bi-encoder 在编码 document 时**看不到 query**，cross-encoder 则让 query 和 document 的 token 在每一层 attention 中直接交互。官方示例 `retrieve_rerank_simple_wikipedia.ipynb` 使用的正是这个组合：bi-encoder 用 `sentence-transformers/multi-qa-mpnet-base-dot-v1`（基于 MS MARCO 的 50 万条真实 Bing 查询训练），cross-encoder 取 top-5。

**这直接解释了为什么必须有第一阶段**：cross-encoder 精确但昂贵，必须先用便宜的 bi-encoder 把候选压缩到约 100 条规模，再交给它精算。

### 4.4 融合两种排序：RRF

当 BM25 和 dense 检索各自返回一个排序列表时，如何合并？**Reciprocal Rank Fusion（RRF）** 是最简单稳健的选择。

RRF 出自 Cormack、Göbel 与 Clarke 在 SIGIR 2009 的论文《Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods》（PDF: http://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf ）。其思路是：**不要直接比较不同检索系统的原始分数（BM25 分数和余弦相似度不可比），只比较名次。**

对每个排序列表中的第 `rank` 名文档，赋予权重 `1 / (k + rank)`，然后把多个列表的权重相加：

```
RRF_score(d) = Σ_i  1 / (k + rank_i(d))
```

其中 `k` 是一个常数，业界实现普遍取 `k = 60`。

RRF 的工程优势：

- **无需分数归一化**——彻底绕开了 BM25 分数与向量相似度的量纲问题；
- **无需调参训练**——只有一个 `k`；
- **鲁棒**——单一检索系统的排序质量抖动不会主导融合结果；
- **可增量扩展**——加一个新检索源（比如新增 BM25 字段、换成新的 embedding 模型）只需要把它也丢进融合。

```python
def rrf(rank_lists, k=60):
    """rank_lists: list of list[doc_id]，每个列表按相关性从高到低"""
    scores = {}
    for ranked in rank_lists:
        for rank, doc_id in enumerate(ranked, start=1):
            scores[doc_id] = scores.get(doc_id, 0.0) + 1.0 / (k + rank)
    return sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
```

**工程经验**：RRF 是很好的默认值，但它的隐含假设是**各路检索的排序质量大致相当**。如果某一路明显更差（例如你的 embedding 模型还没适配领域），它仍然会贡献噪声。可以在融合时给每一路加权（`1/(k+rank) * weight_i`），权重用线上点击/标注数据来定。

### 4.5 端到端 pipeline 与延迟预算

完整的检索链路通常是：

```
用户查询
  ↓
[可选] 查询改写 / 意图识别 / 拼写纠错
  ↓
并行：
  ├─ BM25 / 关键词检索  → top-100
  └─ dense 检索 (HNSW) → top-100
  ↓
RRF 融合 → top-100
  ↓
cross-encoder 重排 → top-10
  ↓
（可选）答案生成 / 引用
```

延迟预算要按阶段分配。**工程经验**：cross-encoder 重排在整个链路中经常是耗时占比最高的一段（尽管只处理 100 条），所以优化重点通常放在：减少候选数、缩短 cross-encoder 输入长度、批处理、把重排降级为异步或可选。

---

## 五、端到端落地：从选型到可观测

### 5.1 选型决策清单

把上面的机制整理成一个可执行的选型流程：

**第一步：测量你的数据规模。**
包括：向量总量、向量维度、预计日增量、是否需要保留原始向量（重排要用）、是否需要多租户隔离。

**第二步：确定召回率与延迟预算。**
- 延迟预算：P99 多少毫秒？整个 pipeline 还是只有检索阶段？
- 召回率目标：0.90 / 0.95 / 0.99？更高的目标直接推高 `ef` 和候选数。

**第三步：建立暴力精确检索的基线。**
用 `IndexFlat`（或数据库的 exact scan）算出真值。这不是可选项——没有真值，任何"召回率 95%"的说法都无法验证。

**第四步：按固定召回率比较，而不是按固定延迟比较。**
错误做法：两个索引都用默认参数，比谁的 QPS 高。
正确做法：**把两个索引都调到相同召回率**（比如都达到相对真值 0.95），再比此时的延迟和内存。默认参数下的速度对比几乎没有信息量。

**第五步：确定过滤与混合检索是否必需。**
- 有过滤需求 → 检查向量库是否支持 ANN 内建过滤，过滤字段是否有索引机制。
- 有精确词需求 → 至少接入 BM25 之类的词法检索，并准备 RRF 融合。
- 召回质量要求高 → 预算内预留 cross-encoder 重排。

**第六步：选运维复杂度匹配的形态。**

| 形态 | 适合 | 不适合 |
| --- | --- | --- |
| 嵌入式库（hnswlib / FAISS / sqlite-vec 等） | 数据量可控、已在用关系库、需要与业务事务同库 | 需要独立扩缩容、多租户隔离 |
| 数据库内置扩展（pgvector 等） | 已有 Postgres 体系、需要与关系数据 JOIN、需要 ACID | 向量检索是核心瓶颈、需要专门的检索调优 |
| 专用向量数据库（Qdrant / Milvus / Weaviate 等） | 大规模、专门的检索负载、多租户、过滤是核心需求 | 团队运维能力有限、规模不大 |

### 5.2 必做的可观测性指标

一个检索系统的生产事故，往往不是"挂了"，而是"悄悄变差了"。以下指标建议全部覆盖：

**索引层**
- `recall@K vs ground_truth`：用抽样人工标注或暴力检索真值定期抽检
- 各分片 / 各索引段的数据量分布（不均衡会让某些分片的召回率显著低于其他）
- 索引构建耗时、写入延迟、compaction / merge 队列长度

**查询层**
- P50 / P95 / P99 延迟（分阶段：ANN 检索 / 融合 / 重排 各自耗时）
- `ef` / `nprobe` 的实际生效值，以及被自动降级过多少次
- 候选集大小与最终返回条数的比值（异常偏大意味着过滤后过滤掉了大量结果）

**业务层**
- 零结果率（过滤条件过严或 embedding 分布漂移的早期信号）
- 重排前后的分数分布变化（cross-encoder 大量压低分数，通常意味着 bi-encoder 召回了不相关内容）
- 用户重查率 / 人工反馈负例率

**工程经验**：`recall@K` 是最容易被忽略也最重要的指标。索引参数被调过、模型被换过、数据被删过之后，召回率可能已经掉到 0.7 而线上毫无感知，直到用户投诉。

### 5.3 变更与回滚纪律

向量检索栈的变更风险，排序如下：

1. **换 embedding 模型**（最危险）——新旧向量空间不兼容。要么双写双索引、灰度切流；要么保留旧索引一段时间，支持按需重建。
2. **改索引参数**（`M`/`ef_construction`/`nlist`）——通常需要重建索引，要有重建窗口和资源预留。
3. **加/改过滤字段索引**——相对安全，但要验证存量数据是否被正确纳入（见 3.3）。
4. **调整 `ef` / `nprobe`**——安全，可动态生效，是最常用的日常调节手段。

任何涉及重建索引的变更，都应该先在**影子索引**上跑一遍同样的查询集，对比召回率与延迟，再切流。

---

## 六、常见误区

**误区一：以为 HNSW 是"不需要调参"的算法。**
恰恰相反，HNSW 的效果高度依赖 `M`、`ef_construction`、`ef` 三个参数，而且它们和你的数据分布强相关。默认值 16/200/10 是在通用数据集上取的起点，不是最优值。

**误区二：以为用了向量库就不需要 BM25。**
只要用户会输入产品型号、错误码、专有名词，BM25（或其他词法通道）就应该保留。

**误区三：以为召回率是引擎"自带"的属性。**
召回率是 **(索引参数, 数据分布, 查询分布)** 三者的联合函数。同一个引擎在同一份数据上，`ef=10` 和 `ef=100` 的召回率可能差好几个百分点。

**误区四：以为重排"总是划算的"。**
重排会增加首字延迟和算力成本。如果你的业务场景是"搜索结果列表展示，人自己看"，可能根本不需要 cross-encoder；如果是 RAG 里喂给模型，直接用召回质量更好的 bi-encoder + 更宽的 `ef` 往往更划算。

**误区五：以为量化压缩是"免费的"。**
PQ/SQ 换来的内存节省，代价是距离计算误差和召回率下降。必须用真值基线量化这个损失，而不是拍脑袋。

---

## 小结

回到开头三个问题：

**问题一：召回率与延迟预算怎么定？** 先用暴力精确检索建真值基线，然后在**同等召回率下**比较各方案的延迟和内存，而不是比默认参数下的速度。HNSW 的旋钮是 `M`（图稠密度）、`ef_construction`（建图质量）、`ef`（查询召回-延迟权衡）；IVF 的旋钮是 `nlist`/`nprobe` 和 PQ 的压缩率。

**问题二：过滤怎么做？** 带过滤的检索是独立的算法问题。优先选支持 ANN 内建过滤、且过滤字段索引可在初始化阶段建立的方案；后过滤在低选择性下必然失效。索引一定要**先建后写**，否则会出现"数据在但搜不到"的坑。

**问题三：要不要混合检索？** 只要查询里存在精确词或专有名词，答案是要。用 BM25 + dense 双路召回，再用 RRF 按名次融合（不需要分数归一化），最后按预算决定是否加 cross-encoder 重排。

**最后一条纪律**：向量检索系统最危险的故障不是崩溃，而是**召回率静默下降**。请把 `recall@K vs ground truth` 当成和可用性同等级的核心 SLI，持续监控、定期抽检。

---

## 参考资料

- HNSW 原始论文：Malkov, A., Yashunin, D. *Efficient and robust approximate nearest neighbor search using Hierarchical Navigable Small World graphs*. arXiv:1603.09320. https://arxiv.org/abs/1603.09320
- hnswlib 源码（默认参数与启发式实现）：https://github.com/nmslib/hnswlib/blob/master/hnswlib/hnswalg.h
- FAISS C++ API（`IndexIVFPQ` 等索引族）：https://faiss.ai/cpp_api/struct/structfaiss_1_1IndexIVFPQ.html
- FAISS 索引类型总览：https://faiss.ai/cpp_api/
- sentence-transformers 官方 retrieve & re-rank 指南：https://www.sbert.net/examples/sentence_transformer/applications/retrieve_rerank/README.html
- RRF 论文：Cormack, G., Göbel, S., Clarke, C. L. A. *Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods*. SIGIR 2009. http://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf
- Qdrant 过滤与 payload index 官方文档：https://qdrant.tech/documentation/search/filtering/
