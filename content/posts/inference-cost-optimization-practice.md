---
title: "推理成本优化实战：批处理、投机解码与模型路由"
description: "从推理成本构成出发，逐一拆解连续批处理、投机解码、量化蒸馏、KV Cache 与前缀缓存、模型路由与级联五类工程手段的收益边界与落地代价，并给出 SLO 指标体系和分阶段实施清单。"
date: 2026-11-15
categories: ["AI 应用"]
tags: ["推理优化", "批处理", "投机解码", "成本"]
---

## 引言：推理成本不是「把模型换小」这一件事

同一张卡、同一个模型，换个服务框架就能差出 2-4 倍的吞吐；同一条业务链路，把「贵模型直接答」换成「便宜模型先答、答不了再升级」，可能省下一大半调用费，也可能悄悄拉低用户满意度。推理成本优化的难点从来不是「知道要省」，而是**在延迟、质量、稳定性三条约束同时收紧的情况下，选对杠杆并量化它**。

围绕这个主题，本文回答下面这些问题：

- 同样的模型、同样的 GPU，为什么单位请求成本能差 2-4 倍？差异主要来自调度还是模型本身？
- prefill 和 decode 在 GPU 上分别卡在算力还是带宽？批处理到底应该批谁？
- 投机解码的理论上界是 1/(1-α)，为什么生产环境常常只能拿到 1.3-2x？
- INT8/INT4 量化省下的显存和带宽，会被哪些环节吃回去？
- KV Cache 的显存膨胀和重复前缀浪费，分别该用什么手段治理？
- 模型路由与级联省下的是成本还是质量？怎么度量、怎么兜底？
- 要把成本优化做成体系，需要哪些可观测指标、告警阈值和灰度步骤？

本文默认读者已经了解推理引擎的基本原理（本站《大模型原理与推理引擎》已覆盖），因此不复述引擎内部机制，只聚焦**工程手段的选择依据、量化收益口径和落地顺序**。所有引用的性能数字都标注了来源与测试条件；凡未能核对到官方原文的，一律显式标为「待验证」。

## 一、先把成本拆开：一次请求到底花在哪

成本优化失败的最常见原因，是拿一个笼统的「每千次请求多少钱」去对标别人，却不清楚自己的时间花在哪个阶段。先把成本拆到阶段，才有可比性。

### 1.1 两个阶段的物理特征完全不同

自回归生成的两个阶段在 GPU 上呈现相反的瓶颈特征（SARATHI 论文摘要对此有明确表述：prefill 在小 batch 下即饱和 GPU 算力，而 decode 因逐 token 生成导致算力利用率偏低）。

| 维度 | prefill（预填充） | decode（解码） |
| --- | --- | --- |
| 一次处理多少 token | 整个 prompt，一次性并行 | 每个请求每次只前进 1 个 token |
| 主导运算形态 | 大矩阵乘 GEMM，计算密集 | 矩阵向量乘 GEMV 为主，访存密集 |
| 主要瓶颈 | 算力（FLOPS） | 显存带宽（把权重和 KV 读进来） |
| batch 增大的效果 | 吞吐迅速上升并很快饱和 | 吞吐随 batch 近似线性上升（摊薄权重读取） |
| 对应延迟指标 | TTFT（首 token 延迟） | TPOT（每输出 token 延迟） |
| 调度含义 | 应切块，避免长 prompt 独占整批 | 应跨请求连续拼批，提高占用 |

工程含义很直接：**decode 阶段才是大多数在线服务的成本主体**（因为输出 token 数通常远大于输入，且持续时间长），但 decode 又是访存受限的，单纯堆算力没有意义。这也是后文所有手段的分界线——凡是能减少「每 token 读取字节数」或「每步参与计算的 token 数」的方法，都在 decode 阶段放大收益。

### 1.2 显存三本账：权重、激活、KV Cache

推理显存主要由三部分构成。设参数量为 P、每参数字节数为 b_w，则权重占用约为 `P × b_w`；KV Cache 占用可用下面的公式估算：

```
KV bytes = 2 × layers × heads × head_dim × seq_len × bytes_per_element
```

其中系数 2 表示 K 和 V 各一份，`bytes_per_element` 由精度决定（FP16/BF16 为 2，FP8 为 1，INT8 为 1，INT4 权重另计）。

| 显存块 | 随什么增长 | 什么时候成为主要矛盾 | 优化抓手 |
| --- | --- | --- | --- |
| 权重 | 参数量 P × 位宽 | 模型大、卡少；决定了「能不能装下」 | 量化、更小的模型、权重复用 |
| 激活 | 与 batch × 序列长度相关，通常远小于权重 | 超长序列 + 大 batch 的瞬态峰值 | 重计算换显存、序列长度上限、分页 |
| KV Cache | 层数 × 头数 × 头维 × 序列长度 × 精度 | 高并发、长上下文；决定「能同时服务多少人」 | 分页管理、前缀复用、KV 量化、压缩 |

按假设参数做一次纯算术演示（仅用于建立量级感，不是任何具体模型的实测值）：某 7B 模型，`layers=32, heads=32, head_dim=128, seq_len=4096, FP16`，则 KV Cache ≈ 2 × 32 × 32 × 128 × 4096 × 2 bytes ≈ **2 GiB**；同精度权重 ≈ 7×10⁹ × 2 bytes ≈ **14 GB**。可见当并发请求叠加时，KV Cache 会迅速超过单请求权重的份额——这正是「加并发比加模型更贵」的来源。

### 1.3 先把单位成本口径定下来

不同团队的账单口径差异极大，先统一指标再谈优化。常用口径如下：

| 指标 | 定义 | 主要用途 | 使用注意 |
| --- | --- | --- | --- |
| $/MTok_in | 输入百万 token 成本 | 对比模型定价、评估缓存价值 | 不含输出，容易误判 |
| $/MTok_out | 输出百万 token 成本 | 评估生成型业务（对话、总结） | 输出价通常显著高于输入 |
| $/request | 单次请求综合成本 | 面向业务方的成本看板 | 受输入/输出长度分布影响，需分层 |
| tokens/s/GPU | 单卡每秒产出 token 数 | 评估系统效率，排除价格波动 | 需区分 prefill/decode，且说明 batch |
| GPU·h/千次请求 | 基础设施侧消耗 | 容量规划与预算 | 需含空闲与排队损耗 |
| 缓存命中率 | 命中 token / 总输入 token | 评估前缀缓存投入 | 命中不等于省钱，要看折扣力度 |

用一段纯标准库代码把这些口径固化下来，避免每次手工换算出错：

```python
"""推理服务单位成本核算（纯标准库；价格字段按实际账单口径填写）。"""
from dataclasses import dataclass


@dataclass
class PriceCard:
    usd_per_mtok_in: float   # 输入百万 token 单价
    usd_per_mtok_out: float  # 输出百万 token 单价
    gpu_hour_usd: float      # 单卡小时成本（含电费与折旧）


def request_cost(tokens_in: int, tokens_out: int, price: PriceCard) -> float:
    return (tokens_in / 1_000_000) * price.usd_per_mtok_in + (
        tokens_out / 1_000_000
    ) * price.usd_per_mtok_out


def cluster_cost(gpu_hours: float, price: PriceCard) -> float:
    return gpu_hours * price.gpu_hour_usd


def blended_cost_per_request(
    tokens_in: int,
    tokens_out: int,
    gpu_hours: float,
    requests: int,
    price: PriceCard,
) -> float:
    """把模型调用费与自建集群成本合并成单一 $/request。"""
    if requests <= 0:
        raise ValueError("requests must be positive")
    return (
        request_cost(tokens_in, tokens_out, price) * requests
        + cluster_cost(gpu_hours, price)
    ) / requests
```

**工程结论：** 先建立「阶段 × 资源 × 单位」三维台账（prefill/decode 分开计时，权重/激活/KV 分开计量，输入/输出分开计价），否则后续所有优化都无法归因，也无法向业务方证明收益。

## 二、批处理：让 GPU 别闲着

批处理的本质是把「多次低效的小运算」合成「一次高效的大运算」，从而摊薄权重读取、提高算力占用。难点在于请求到达时间和生成长度都不同步。

### 2.1 三代调度策略的差别

| 策略 | 做法 | 优点 | 代价 |
| --- | --- | --- | --- |
| 静态批处理 | 等凑满一批再一起算，整批同进同出 | 实现简单 | 队头阻塞严重，短请求被长请求拖累，GPU 大量空转 |
| 连续批处理（iteration-level） | 每个 decode step 结束后重新组批，完成的请求立即退出、新请求立即插入 | 无队头阻塞，吞吐大幅提升 | 需要动态内存管理与调度器改造 |
| 分块 prefill + decode 最大批 | 把长 prompt 切块混入 decode 批次，并优先保证 decode 批的规模 | 兼顾 TTFT 与 decode 吞吐 | 实现复杂，切块大小需调参 |

Orca（OSDI'22）提出 iteration-level scheduling 与 selective batching，论文报告在 GPT-3 175B 上相比 NVIDIA FasterTransformer 取得 **36.9 倍吞吐提升（相同延迟水平）**（[https://www.usenix.org/conference/osdi22/presentation/yu](https://www.usenix.org/conference/osdi22/presentation/yu)）。vLLM 的 PagedAttention 把 KV Cache 做成类操作系统的分页管理，使显存浪费接近零，论文报告吞吐相比 FasterTransformer、Orca 等系统提升 **2-4 倍（相同延迟水平）**（arXiv:2309.06180，SOSP 2023）。

### 2.2 SARATHI 给出的量化拆解

SARATHI（arXiv:2308.16369）的贡献在于把两类现象拆开处理：chunked-prefills（分块预填充）与 decode-maximal batching（解码阶段尽量凑满批）。其报告数据如下（均为论文原始测试条件，硬件与模型对应关系不可忽略）：

| 模型 / 硬件 | 基线系统 | decode 吞吐提升 | 端到端提升 |
| --- | --- | --- | --- |
| LLaMA-13B / A6000 | 未分块的朴素调度 | 最高 10x | 1.33x |
| LLaMA-33B / A100 | 未分块的朴素调度 | 最高 4.25x | 1.25x |
| GPT-3（流水线并行） | 朴素流水线调度 | 流水线气泡减少 6.29x | 1.91x |

这张表最重要的信息不是「10x」这个数字，而是**端到端提升远小于 decode 吞吐提升**：因为 prefill、调度开销、长尾请求都会稀释收益。做任何优化预估时都应做同样口径的折算。

### 2.3 落地时的三个坑

- **只看平均不看 p99**：批处理会把长尾拉长，p99 恶化是常见的「吞吐涨了、投诉也涨了」。
- **切块大小一刀切**：长 prompt 与短 prompt 应使用不同 chunk 策略，固定值在混合流量下必然偏废。
- **忽略 KV 容量上限**：batch 上限往往由 KV Cache 容量而非算力决定，盲目加 batch 只会触发抢占或 OOM。

**工程结论：** 连续批处理是收益最确定、副作用最小的一步，应作为所有自建服务的首选基线；分块 prefill 属于「用 TTFT 换 decode 吞吐」的取舍，必须在 SLO 允许范围内灰度。

## 三、投机解码：让小模型替大模型「抢跑」

### 3.1 原理：先猜，再一次验完

投机解码（speculative decoding）的核心观察是：**验证一串 token 比生成一串 token 便宜**。目标模型一次前向可以并行处理多个位置，因此让草稿模型先连续猜 γ 个 token，再由目标模型一次性验证，若前缀全部正确即可一次吐出多个 token。

关键性质是**输出分布与目标模型完全一致**——被拒绝的位置会按修正分布重新采样，因此这不是「近似」，而是无损加速（Leviathan et al., ICML 2023 Oral，arXiv:2211.17192，T5-XXL 上报告相对标准 T5X 实现 **2X-3X 加速且输出完全一致**）。

记 γ 为草稿步数、α 为期望接受率、c 为草稿单步成本 / 目标单步成本、T 为目标单步耗时，论文给出的三个公式（已逐字核对论文 HTML）：

```
E[# generated tokens]      = (1 - α^(γ+1)) / (1 - α)
walltime 改善因子          = (1 - α^(γ+1)) / ((1 - α)(γc + 1))
单 token 期望成本 / T      = (cγ + 1)(1 - α) / (1 - α^(γ+1))
```

γ=1 时加速比退化为 `(1+α)/(1+c)`；当 c≈0（草稿几乎免费）时，上界为 `1/(1-α)`。注意最后这个上界是**理想极限**，它要求草稿零成本，实际中永远达不到。

### 3.2 把公式变成算例

下面按论文公式做纯数值演算（非实测，用于理解参数敏感性）：

| α | γ | 期望接受 token E | 每 token 成本（c=0.1） | 每 token 成本（c=0.2） | 加速比（c=0.1） | 加速比（c=0.2） | 理论上限 1/(1-α) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0.9 | 4 | 4.10 | 0.34 | 0.44 | 2.93 | 2.28 | 10.0 |
| 0.8 | 4 | 3.36 | 0.42 | 0.54 | 2.40 | 1.87 | 5.0 |
| 0.7 | 4 | 2.77 | 0.50 | 0.65 | 1.98 | 1.54 | 3.3 |
| 0.6 | 4 | 2.31 | 0.61 | 0.78 | 1.65 | 1.28 | 2.5 |
| 0.5 | 4 | 1.94 | 0.72 | 0.93 | 1.38 | 1.08 | 2.0 |
| 0.8 | 1 | 1.80 | 0.61 | 0.67 | 1.64 | 1.29 | 5.0 |

三个结论立刻可见：**α 的影响远大于 γ**；**草稿成本 c 会显著侵蚀收益**（α=0.8 时 c 从 0.1 升到 0.2，加速比从 2.40 掉到 1.87）；**α 低于 0.6 后收益迅速衰减**，此时不如不做。

```python
def expected_accepted_tokens(alpha: float, gamma: int) -> float:
    """E[# generated tokens] = (1 - alpha^(gamma+1)) / (1 - alpha)。"""
    return (1.0 - alpha ** (gamma + 1)) / (1.0 - alpha)


def speedup_factor(alpha: float, gamma: int, c: float) -> float:
    """walltime 改善因子 = E / (gamma*c + 1)。"""
    return expected_accepted_tokens(alpha, gamma) / (gamma * c + 1.0)


def cost_per_token_ratio(alpha: float, gamma: int, c: float) -> float:
    """单 token 期望成本相对目标模型单步耗时的比值。"""
    return (c * gamma + 1.0) * (1.0 - alpha) / (1.0 - alpha ** (gamma + 1))


if __name__ == "__main__":
    for alpha in (0.9, 0.8, 0.7, 0.6, 0.5):
        print(alpha, round(expected_accepted_tokens(alpha, 4), 3),
              round(speedup_factor(alpha, 4, 0.1), 2))
```

### 3.3 三类实现路线对比

| 路线 | 草稿从哪来 | 是否需要训练 | 报告收益 | 适用条件 |
| --- | --- | --- | --- | --- |
| 独立草稿模型 | 单独的小模型（如同族小号版） | 否（可直接用现成小模型） | T5-XXL 上 2X-3X（arXiv:2211.17192） | 有同源小模型，任务分布稳定 |
| 多头投机（Medusa） | 在原模型上加多个解码头并做树状注意力验证 | 是（训练解码头） | Medusa-1 无损 >2.2x，Medusa-2 2.3-3.6x（arXiv:2401.10774） | 希望不改部署形态、单模型自足 |
| 特征级自回归（EAGLE） | 复用目标模型的高层特征做草稿 | 是（训练草稿头） | LLaMA2-Chat 70B 延迟加速 2.7x-3.5x、吞吐翻倍（arXiv:2401.15077） | 追求更高接受率、可接受训练成本 |

伪代码描述一次典型的验证循环（仅为说明控制流，非可直接运行代码）：

```text
# 伪代码：投机解码单步
draft_tokens = draft_model.generate(prompt_suffix, steps=gamma)
logits, kv = target_model.forward(prompt_suffix + draft_tokens)   # 一次并行前向
for i, tok in enumerate(draft_tokens):
    if sample(target_dist[i]) != tok:          # 该位置被拒绝
        accepted = draft_tokens[:i]
        bonus = sample_from_corrected_dist(target_dist[i])
        return accepted + [bonus]
return draft_tokens + [sample(target_dist[-1])]  # 全部接受，白赚一个 bonus token
```

### 3.4 为什么生产环境常常只有 1.3-2x

- **α 随任务波动**：代码补全、格式化输出这类高度可预测的任务 α 很高；开放式创作 α 很低。用平均值规划等于自欺。
- **batch 内投机有额外开销**：一次验证要同时算 γ+1 个位置，批越大，被拒时的浪费越大；部分实现会在低并发时才启用投机。
- **短输出场景收益被摊薄**：生成 10 个 token 的请求根本吃不满 γ 步。
- **显存与调度复杂度上升**：草稿模型自身的权重、KV、以及双模型共存的调度都会挤占资源。

上线前应在**自己的真实流量分布**上测 α（可用贪心比对快速估计），而不是引用论文数字。

**工程结论：** 投机解码是「用多余算力换延迟」的手段，最适合**低并发、长输出、高可预测性**的场景；在已经充分批处理的高吞吐场景里，它更多是与批处理争抢算力，收益需要实测确认。

## 四、量化与蒸馏：把每个 token 的搬运量砍下来

decode 是访存受限的，所以**每参数字节数**直接决定速度：权重位宽减半，权重读取时间大致减半。量化就是在这条线上做文章，但它同时改变精度，必须按场景分级。

### 4.1 主流路线对比

| 路线 | 权重/激活位宽 | 是否需要校准集 | 代表工作 | 报告收益 |
| --- | --- | --- | --- | --- |
| FP16/BF16 基线 | 16 bit / 16 bit | 否 | — | — |
| W8A8 PTQ | 8 bit / 8 bit | 少量样本做平滑 | SmoothQuant（arXiv:2211.10438） | 最高 1.56x 加速、2x 内存下降，可单机服务 530B |
| W4A16（分组量化） | 4 bit / 16 bit | 需要代表性校准数据 | GPTQ（arXiv:2210.17323） | 175B 模型约 4 GPU 小时量化到 3/4 bit，精度损失可忽略；端到端相对 FP16 加速 A100 约 3.25x、A6000 约 4.5x |
| 激活感知权重量化 | 4 bit / 16 bit | 需要，但只保护少量显著权重 | AWQ（arXiv:2306.00978，MLSys 2024 Best Paper） | 只需保护 1% 显著权重；TinyChat 相比 Hugging Face FP16 实现 >3x 加速 |
| FP8 | 8 bit / 8 bit | 视硬件支持 | 厂商栈（如 TensorRT-LLM） | 取决于硬件：NVIDIA H100 SXM 规格中 FP8 Tensor Core 3958 TFLOPS vs FP16 1979 TFLOPS，约 2x 峰值算力（随 SKU 变化，见 nvidia.com/en-us/data-center/h100/） |

三个口径上的提醒：

- **这些数字不可相加**。GPTQ 的 3.25x 是相对 FP16 基线的端到端值，AWQ 的 >3x 是相对 Hugging Face FP16 实现，SmoothQuant 的 1.56x 又是另一种基线；混用会得到虚假预期。
- **量化收益在 batch 小时会被稀释**。batch=1 时权重读取是唯一瓶颈，量化近乎线性提速；batch 变大后逐渐转为算力受限，收益收窄。
- **精度必须先于速度验收**。先固定评测集与业务抽检，再谈加速。

### 4.2 用 roofline 思路判断该不该量化

```python
def kv_cache_bytes(num_layers: int, num_heads: int, head_dim: int,
                   seq_len: int, bytes_per_element: int = 2) -> int:
    return 2 * num_layers * num_heads * head_dim * seq_len * bytes_per_element


def weight_bytes(param_count: int, bits: int) -> int:
    return param_count * bits // 8


def is_memory_bound(arithmetic_intensity: float,
                    peak_tflops: float,
                    peak_bandwidth_gbps: float) -> bool:
    """arithmetic_intensity 单位 FLOP/Byte；ridge point 以下视为访存受限。"""
    ridge = peak_tflops * 1e12 / (peak_bandwidth_gbps * 1e9)
    return arithmetic_intensity < ridge


def estimate_decode_step_seconds(param_count: int, bits: int,
                                 bandwidth_gbps: float,
                                 batch_size: int = 1) -> float:
    """极简化估算：decode 单步主要成本 = 读取一遍权重。"""
    bytes_to_read = weight_bytes(param_count, bits) * batch_size
    return bytes_to_read / (bandwidth_gbps * 1e9)
```

上面这个估算故意忽略了 KV 读取、调度与 kernel 启动开销，只能用于**量级判断**；真实容量规划应使用实测的 tokens/s/GPU 曲线。

### 4.3 蒸馏：换模型而不是换位数

量化是在同一模型上省字节，蒸馏是直接换一个更小的模型。Distilling Step-by-Step!（arXiv:2305.02301，ACL 2023 Findings）报告：**770M 参数的 T5 仅用 80% 的数据，就在一个 benchmark 上超过了 few-shot 540B PaLM**——说明「把大模型的推理过程蒸馏给小模型」在特定任务上可以跨越数量级的参数差距。

三者的分工是：**量化改动小、可回滚，应先做；蒸馏需要数据与训练管线、存在任务迁移风险，应后做；直接换更小的开源模型则要与蒸馏并列评估**（许可、成本、能力上限都要看）。蒸馏的具体训练路线（logits 蒸馏、特征蒸馏、数据合成蒸馏）已在站内《小模型 vs 大模型：路由的工程决策》中展开，本节只把它当作「成本杠杆」来验收。

**工程结论：** 量化是低风险高确定性的一步，建议作为默认动作；蒸馏只在量化已到极限、且存在稳定高价值子任务时才启动，并必须配套独立的评测集与灰度。

## 五、KV Cache 与前缀缓存：重复计算是最贵的浪费

### 5.1 四类缓存手段的分工

| 层级 | 复用粒度 | 命中条件 | 主要收益 | 实现位置 |
| --- | --- | --- | --- | --- |
| PagedAttention | 单个请求内部的 KV 分页 | 无需命中，消除碎片 | 同等显存下并发数提升 | 推理引擎（vLLM，arXiv:2309.06180） |
| RadixAttention / 前缀树复用 | 跨请求的公共前缀 | 前缀 token 序列完全一致 | 跳过重复 prefill，报告整体最高 6.4x 吞吐提升 | 推理引擎（SGLang，arXiv:2312.07104） |
| 服务端 prompt caching | 输入前缀 | 前缀达到最小长度且未过期 | 输入价格与首 token 延迟同时下降 | 模型 API（见 5.2） |
| 客户端语义缓存 | 整个请求 | 语义相似或完全相同 | 极端热点请求近乎零成本 | 业务网关 |

### 5.2 服务端 prompt caching 的价格结构

Anthropic 的官方说明（[https://claude.com/resources/articles/prompt-caching](https://claude.com/resources/articles/prompt-caching)）给出的口径是：**长 prompt 场景最高可降低 90% 成本、85% 延迟**；计费上 **cache write = 基础输入价 × 1.25，cache read = 基础输入价的 10%**。其示例中，一本约 100k token 的书作为上下文进行多轮对话时，TTFT 从 11.5s 降到 2.4s（-79%），成本降低 90%。

OpenAI 侧采用自动前缀缓存机制，公开文档口径为：最小缓存前缀约 **1,024 token**，命中部分按输入价的 **5 折**计费。**该组数字未能直接抓取到官方原文核对（页面被 Cloudflare 拦截，第三方复核文档标注 last_verified_on 2026-05-14），本文按「待验证」处理，落地前请以官方文档为准**：[https://platform.openai.com/docs/guides/prompt-caching](https://platform.openai.com/docs/guides/prompt-caching)。

价格结构的差异意味着**缓存策略必须按厂商分别设计**：Anthropic 的 write 溢价要求前缀足够长、复用次数足够多才划算；5 折的读数则要求把「是否写入」本身当成成本项来评估。

```python
def cache_cost(total_input_tokens: int,
               cached_prefix_tokens: int,
               usd_per_mtok_in: float,
               read_multiplier: float = 0.10,
               write_extra_multiplier: float = 0.25) -> dict:
    """对比「完全不缓存」与「命中前缀缓存」两种口径的成本。"""
    if not (0 <= cached_prefix_tokens <= total_input_tokens):
        raise ValueError("cached prefix must be within input")
    full = total_input_tokens * usd_per_mtok_in / 1_000_000
    hit = (
        (total_input_tokens - cached_prefix_tokens) * usd_per_mtok_in / 1_000_000
        + cached_prefix_tokens * usd_per_mtok_in / 1_000_000 * read_multiplier
    )
    return {
        "uncached_usd": round(full, 6),
        "cached_usd": round(hit, 6),
        "saving_ratio": round(1 - hit / full, 4) if full else 0.0,
        "note": "未计入一次性的 cache write 溢价，需按调用次数摊销",
    }
```

注意函数注释里那句提醒：**前缀缓存的收益必须除以复用次数来看**。一个只被命中一次的 100k 前缀，在 write 溢价 25% 的口径下可能反而更贵。

### 5.3 长序列的专用手段

当序列长到 attention 本身成为瓶颈时，Flash-Decoding（Stanford CRFM 技术博客，[https://crfm.stanford.edu/2023/10/12/flashdecoding.html](https://crfm.stanford.edu/2023/10/12/flashdecoding.html)）报告：**超长序列生成最高 8x 加速**，其 attention 实现比 FlashAttention 最多快 50x，且在序列长度到 32k 之前 attention 耗时近似恒定（因为它把 K/V 并行载入、再单独 rescale 合并）。这类手段属于「换个 kernel」，不动模型与量化，适合作为长上下文业务的备选。

**工程结论：** 缓存是**唯一同时改善成本和延迟的手段**，优先级应高于量化与投机解码；但必须先搞清楚自己流量的前缀重复率，否则可能为几乎不命中的缓存付出 write 溢价。

## 六、模型路由与级联：把钱花在值得的请求上

### 6.1 已报告的收益与它的前提

| 工作 | 策略 | 报告结果 | 成立条件 |
| --- | --- | --- | --- |
| FrugalGPT（arXiv:2305.05176） | 多级 LLM 依次尝试 + 提前停止 | 最高 98% 成本降低仍匹配最佳单模型表现；或同成本下准确率比 GPT-4 高 4% | 需要高质量打分器与明确的任务分类 |
| RouteLLM（arXiv:2406.18665） | 训练路由器在强弱模型间选择 | 部分场景降本超过 2 倍且不牺牲回答质量；更换强弱模型后路由器仍可迁移 | 需要标注数据训练路由，且底座模型不能频繁更换 |

这两个结果都指向同一件事：**路由的上限由「任务可分性」决定**。如果所有请求难度相同，路由只能退化成随机分流，收益接近于零，还平添了路由错误的风险。

### 6.2 路由信号怎么选

| 信号 | 获取成本 | 稳定性 | 适用业务 |
| --- | --- | --- | --- |
| 输入长度 / 结构特征 | 极低 | 高 | 初步分流（短问答走小模型） |
| 任务类型分类器 | 中（需训练） | 中高 | 客服、检索、摘要等多意图入口 |
| 难度/置信度评分 | 中（可用小模型自评） | 中 | 代码、数学、工具调用 |
| 历史通过率/人工反馈 | 低（有埋点即可） | 高 | 有线上标注闭环的团队 |
| 随机探索（ε-greedy） | 极低 | 高 | 冷启动阶段收集数据 |

工程上建议「先规则、后学习」：用长度与任务类型把流量切成 5-10 档，先人工指定每档的模型，跑两周拿到分档的成本与质量数据，再决定是否训练路由器。直接上学习式路由，很容易在没有对照的情况下把质量退化误认为模型问题。

### 6.3 一个可运行的简易路由骨架

```python
ROUTES = [
    {"name": "tiny", "max_chars": 1200, "tasks": {"chitchat", "format"}},
    {"name": "mid", "max_chars": 8000, "tasks": {"summary", "extract"}},
    {"name": "strong", "max_chars": 10**9, "tasks": set()},
]


def classify(text: str) -> str:
    """占位实现：真实项目应替换为分类模型或规则表。"""
    lowered = text.lower()
    if any(k in lowered for k in ("总结", "摘要", "summary")):
        return "summary"
    if any(k in lowered for k in ("解释", "翻译", "格式")):
        return "format"
    return "chitchat"


def pick_route(text: str, policy: str = "cost_first") -> str:
    task = classify(text)
    length = len(text)
    candidates = [r for r in ROUTES if task in r["tasks"] and length <= r["max_chars"]]
    if policy == "quality_first":
        return candidates[-1]["name"] if candidates else "strong"
    return candidates[0]["name"] if candidates else "strong"


def cascade(text: str, cheap_model, strong_model, confidence_threshold: float = 0.8):
    """便宜模型先答；置信度不足时升级到强模型（示意，需接入真实置信度接口）。"""
    answer, confidence = cheap_model.answer_with_confidence(text)
    if confidence >= confidence_threshold:
        return {"answer": answer, "model": "cheap", "confidence": confidence}
    return {"answer": strong_model.answer(text), "model": "strong", "confidence": None}
```

这段代码只是骨架：真正的置信度来源（logprob、自一致性投票、独立评审模型）需要按业务选型，且**必须记录每次路由决策的理由**，否则出了问题无法复盘。

**工程结论：** 路由与级联的收益来自「任务难度的方差」，而不是模型的数量。上线前先算清楚流量的难度分布与分档成本，再决定值不值得引入这一层复杂度。路由器的训练、错误率分解与评测口径已在站内《小模型 vs 大模型：路由的工程决策》中展开，本文不再重复。

## 七、SLO 与单位成本：把优化做成仪表盘

没有度量就没有优化。下面给出一套可直接落地的指标表（阈值均为**示例值，需按自身业务校准**）。

| 类别 | 指标 | 建议告警阈值（示例） | 说明 |
| --- | --- | --- | --- |
| 延迟 | TTFT p99 | 超过基线 1.5 倍 | 受 prefill 与排队影响，对长 prompt 敏感 |
| 延迟 | TPOT p99 | 超过基线 1.3 倍 | 反映 decode 效率，量化/投机解码的首要观测项 |
| 延迟 | 端到端 p99 | 按业务 SLA 设定 | 唯一对用户有意义的延迟口径 |
| 质量 | 业务通过率 / 人工抽检不合格率 | 不低于基线 2 个百分点以内 | 任何降本动作都必须与质量指标同屏 |
| 成本 | $/1k 请求 | 周环比波动 > 10% 触发复核 | 需按输入/输出长度分层，避免结构性变化误报 |
| 效率 | tokens/s/GPU | 低于容量规划值 80% | 用于发现调度退化 |
| 资源 | GPU 利用率 / KV 占用率 | 利用率 < 50% 或 KV > 85% | 前者说明批没凑起来，后者预示即将降级 |
| 缓存 | 前缀缓存命中率 | 低于目标值 20% 个百分点 | 命中率低说明缓存策略与流量不匹配 |

```python
import statistics


def percentile(values, p: float) -> float:
    """线性插值分位数（示例实现，生产可用 numpy）。"""
    ordered = sorted(values)
    if not ordered:
        raise ValueError("empty sample")
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * p
    low = int(pos)
    high = min(low + 1, len(ordered) - 1)
    frac = pos - low
    return ordered[low] * (1 - frac) + ordered[high] * frac


def weekly_report(samples, price_per_1k: float) -> dict:
    costs = [s["usd_per_1k"] for s in samples]
    return {
        "p50_usd_per_1k": round(percentile(costs, 0.50), 4),
        "p99_usd_per_1k": round(percentile(costs, 0.99), 4),
        "mean_tokens_per_sec": round(statistics.fmean(s["tps"] for s in samples), 1),
    }
```

### 7.1 按变更规范推进每一次降本

参考本工作区的 SRE 规范，任何一项优化上线都应写成变更单，至少包含：

1. **影响范围**：涉及哪些业务线、流量比例、模型与版本。
2. **前置检查**：评测集回归结果、容量余量、回滚开关是否可用。
3. **执行步骤**：灰度比例（如 1% → 10% → 50% → 100%）与每档观察时长。
4. **验证**：成本指标与质量指标同屏对比，任一指标破阈立即停止。
5. **回滚**：保留原配置镜像与一键回退路径，并明确谁有权触发。

**工程结论：** 成本优化不是一次性项目，而是「观测 → 假设 → 小流量验证 → 全量 → 复盘」的循环；把指标、阈值和回滚预案固化下来，才能持续做而不失控。

## 八、落地清单与优先级

### 8.1 手段决策表

| 手段 | 典型收益量级 | 前置条件 | 主要风险 | 见效周期 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 连续批处理 | 吞吐 2-4 量级（依系统而定） | 换用支持 iteration-level 调度的引擎 | 长尾延迟上升 | 1-2 周 | 高 |
| 分块 prefill | decode 吞吐数倍，端到端 1.2-1.9x | 引擎支持，需调 chunk | TTFT 恶化 | 2-4 周 | 中 |
| PagedAttention / 分页 KV | 并发能力提升，显存近零浪费 | 换引擎（如 vLLM） | 无实质风险 | 随引擎迁移 | 高 |
| 前缀缓存 / RadixAttention | 报告整体最高 6.4x | 流量存在公共前缀 | 命中率不可控 | 2-4 周 | 高 |
| 服务端 prompt caching | 长 prompt 最高 90% 成本下降 | 前缀达到最小长度 | write 溢价、供应商绑定 | 数天 | 高 |
| 投机解码 | 1.3-3.5x（实测依赖 α） | 草稿模型与目标匹配 | 收益随 α 波动 | 2-6 周 | 中 |
| 权重量化 INT8/INT4 | 1.5-3x 区间（依基线与硬件） | 评测集与校准数据 | 精度损失 | 2-4 周 | 中 |
| FP8 | 峰值算力约 2x | 硬件与栈支持 | 数值稳定性 | 2-4 周 | 中 |
| 蒸馏小模型 | 参数规模下降一个量级 | 数据与训练管线 | 任务迁移风险 | 1-3 个月 | 低 |
| 模型路由 / 级联 | 报告最高 98% 成本下降 | 任务可分、有标注 | 路由错误难以察觉 | 1-2 个月 | 中 |

### 8.2 分阶段路线

| 阶段 | 时间盒 | 目标 | 关键动作 | 交付物 |
| --- | --- | --- | --- | --- |
| 第一阶段：可观测 | 0-2 周 | 建立成本基线 | 分阶段计时、分层计价、上线 p99 看板 | 成本台账与基线报告 |
| 第二阶段：低风险快赢 | 2-8 周 | 提升调度与缓存效率 | 迁移连续批处理、开启分页 KV、接入前缀缓存 | 吞吐/成本对比报告 |
| 第三阶段：精度换成本 | 8-16 周 | 量化与投机解码 | 评测集先行、小流量灰度、α 实测 | 精度-成本权衡曲线 |
| 第四阶段：结构性降本 | 16 周以上 | 路由、蒸馏与模型选型 | 难度分档、路由训练、小模型训练 | 分档成本模型与升级策略 |

### 8.3 上线前自检清单

- [ ] 是否已有分阶段（prefill/decode）的延迟与吞吐基线？
- [ ] 是否明确了本次优化的唯一主指标，以及不能恶化的护栏指标？
- [ ] 质量评测是否覆盖主流量任务与长尾 badcase？
- [ ] 灰度方案是否支持一键回滚，回滚是否演练过？
- [ ] 成本收益是否按端到端口径折算，而不是只看单项峰值？
- [ ] 容量余量是否留够（建议 KV 占用不超过 85%）？
- [ ] 是否记录了实验条件（模型版本、硬件、batch、序列长度），便于复现？

### 8.4 常见反模式

| 反模式 | 后果 | 纠正方式 |
| --- | --- | --- |
| 用峰值吞吐对外承诺 | 实际业务长尾体验恶化 | 一律用 p99 端到端延迟与分层成本承诺 |
| 引用论文数字作为收益预期 | 预期落空，团队失去信心 | 只用自己流量上的实测值做规划 |
| 先上优化、后补评测 | 质量退化无法归因 | 评测集与护栏指标先行 |
| 把所有请求都交给最便宜的模型 | 高难度请求体验崩塌 | 分档 + 升级兜底 |
| 忽略缓存 write 溢价 | 缓存越用越贵 | 按复用次数摊销后核算 |
| 只做均值、不看分布 | 尾部用户流失 | 所有指标看分位数 |

## 小结

推理成本优化的本质，是在**延迟、质量、成本**三者之间找到当前业务允许的最优点，而不是单向压低成本。三条核心结论：

1. **先归因，再动手。** 把成本拆到 prefill/decode、权重/激活/KV、输入/输出三个维度，才能区分「调度浪费」「显存浪费」和「模型本身贵」这三类完全不同的问题，避免用错工具。
2. **缓存与批处理的确定性高于投机解码与量化。** 前缀缓存与连续批处理是少见的「同时改善延迟和成本」的手段，应优先做；投机解码和量化的收益强烈依赖自身流量特征（接受率 α、batch 大小、精度容忍度），必须实测后再全量。
3. **把优化做成可回滚的变更循环。** 任何降本动作都要有基线、护栏指标、灰度和回滚预案；用 p99 而非均值承诺，用端到端单位成本而非单点峰值证明收益。

最后提醒一句：本文引用的所有论文与官方文档数字都受各自实验条件约束（模型、硬件、batch、序列长度、基线实现均不同），**它们用来判断量级和方向，不能直接当作你自己系统的预期收益**。

## 参考资料

1. Kwon et al., *Efficient Memory Management for Large Language Model Serving with PagedAttention* (vLLM), SOSP 2023. [https://arxiv.org/abs/2309.06180](https://arxiv.org/abs/2309.06180)
2. Yu et al., *Orca: A Distributed Serving System for Transformer-Based Generative Models*, OSDI 2022. [https://www.usenix.org/conference/osdi22/presentation/yu](https://www.usenix.org/conference/osdi22/presentation/yu)
3. Leviathan et al., *Fast Inference from Transformers via Speculative Decoding*, ICML 2023. [https://arxiv.org/abs/2211.17192](https://arxiv.org/abs/2211.17192)
4. Cai et al., *Medusa: Simple LLM Inference Acceleration Framework with Multiple Decoding Heads*, 2024. [https://arxiv.org/abs/2401.10774](https://arxiv.org/abs/2401.10774)
5. Li et al., *EAGLE: Speculative Sampling Requires Rethinking Feature Uncertainty*, 2024. [https://arxiv.org/abs/2401.15077](https://arxiv.org/abs/2401.15077)
6. Lin et al., *AWQ: Activation-aware Weight Quantization for LLM Compression and Acceleration*, MLSys 2024. [https://arxiv.org/abs/2306.00978](https://arxiv.org/abs/2306.00978)
7. Frantar et al., *GPTQ: Accurate Post-Training Quantization for Generative Pre-trained Transformers*, ICLR 2023. [https://arxiv.org/abs/2210.17323](https://arxiv.org/abs/2210.17323)
8. Zheng et al., *SGLang: Efficient Execution of Structured Language Model Programs*, 2023. [https://arxiv.org/abs/2312.07104](https://arxiv.org/abs/2312.07104)
9. Agrawal et al., *Sarathi: Efficient LLM Inference by Piggybacking Decodes with Chunked Prefills*, 2023. [https://arxiv.org/abs/2308.16369](https://arxiv.org/abs/2308.16369)
10. Chen et al., *FrugalGPT: How to Use Large Language Models While Reducing Cost and Improving Performance*, 2023. [https://arxiv.org/abs/2305.05176](https://arxiv.org/abs/2305.05176)
11. Ong et al., *RouteLLM: Learning to Route LLMs with Preference Data*, 2024. [https://arxiv.org/abs/2406.18665](https://arxiv.org/abs/2406.18665)
12. Hsieh et al., *Distilling Step-by-Step! Outperforming Larger Language Models with Less Training Data and Smaller Model Sizes*, ACL 2023 Findings. [https://arxiv.org/abs/2305.02301](https://arxiv.org/abs/2305.02301)
13. Xiao et al., *SmoothQuant: Accurate and Efficient Post-Training Quantization for Large Language Models*, ICML 2023. [https://arxiv.org/abs/2211.10438](https://arxiv.org/abs/2211.10438)
14. Anthropic, *Prompt caching with Claude*. [https://claude.com/resources/articles/prompt-caching](https://claude.com/resources/articles/prompt-caching)
15. OpenAI, *Prompt caching* (官方指南；文中 1024 token / 5 折口径为待验证). [https://platform.openai.com/docs/guides/prompt-caching](https://platform.openai.com/docs/guides/prompt-caching)
16. NVIDIA, *NVIDIA H100 Tensor Core GPU* 产品与规格页. [https://www.nvidia.com/en-us/data-center/h100/](https://www.nvidia.com/en-us/data-center/h100/)
17. Dao, Haziza et al., *Flash-Decoding* (Stanford CRFM 技术博客). [https://crfm.stanford.edu/2023/10/12/flashdecoding.html](https://crfm.stanford.edu/2023/10/12/flashdecoding.html)
18. DeepSeek, *DeepSeek-V3 Technical Report*. [https://arxiv.org/abs/2412.19437](https://arxiv.org/abs/2412.19437)
19. vLLM 官方文档. [https://docs.vllm.ai/en/latest/](https://docs.vllm.ai/en/latest/)
20. vLLM 项目仓库. [https://github.com/vllm-project/vllm](https://github.com/vllm-project/vllm)
21. NVIDIA TensorRT-LLM 官方文档. [https://nvidia.github.io/TensorRT-LLM/](https://nvidia.github.io/TensorRT-LLM/)

> 说明：本文所有性能数字均来自上列论文摘要或官方文档，代表其各自的实验条件；不同工作的基线、硬件、模型与批处理配置互不相同，数字之间不可直接比较或叠加。未能核对到官方原文的条目已在正文中标注「待验证」。
