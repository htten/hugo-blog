---
title: "多模态大模型应用：视觉编码、VLM 推理与工程取舍"
description: "多模态大模型的核心不是把图像塞进语言模型，而是视觉编码器、连接器与语言模型三者之间的分工与取舍。本文从 ViT 与对比学习讲起，梳理 MLP/Q-Former/cross-attention 三类连接器、动态高分辨率与视觉 token 预算、视频长时序处理，以及 vLLM 推理引擎中的多模态工程问题，最后给出可执行的落地清单与度量方法。"
date: 2026-11-13
categories: ["AI 应用"]
tags: ["多模态", "VLM", "视觉编码", "推理"]
---

## 引言：你可能早就遇到过这些问题

- 同一个模型，纯文本问答很准，一旦换成"看这张图"就开始胡编：把图里的数字说错、把表格读串行、把不存在的物体描述得栩栩如生。
- 把一张 4K 截图丢给多模态模型，要么直接报"图像过大"，要么被压成 336×336 后细节全丢。
- 多模态请求的推理成本远高于纯文本，但报表里只看到"输入 token 变多了"，说不清到底贵在哪。
- 换了一个更小的视觉编码器，评测分数没掉多少，但线上 OCR 场景明显变差。
- 视频理解功能上线后，长视频的显存占用和延迟失控。

这些问题的共同根源是：**多模态模型不是"语言模型 + 一个图像接口"，而是一条由视觉编码器、视觉-语言连接器、语言模型三段组成的链路**。任何一段的设计选择都会同时影响精度、延迟、显存和成本。

本文按这条链路展开，并在最后给出一份可以照着做的落地清单。

## 一、三段式架构：多模态模型到底由什么组成

几乎所有主流视觉语言模型（VLM）都可以拆成三段：

```
图像/视频 ──▶ [视觉编码器 ViT] ──▶ 视觉特征序列
                                      │
                                      ▼
                              [连接器 Connector]
                                      │
                                      ▼
文本 token ◀── [语言模型 LLM] ◀── 视觉 token（已对齐到文本嵌入空间）
```

三段各自的职责：

| 段 | 职责 | 典型实现 | 是否通常冻结 |
| --- | --- | --- | --- |
| 视觉编码器 | 把像素变成一组视觉特征向量 | ViT、SigLIP、InternViT | 多数冻结 |
| 连接器 | 把视觉特征映射到语言模型的嵌入空间 | MLP、Q-Former、cross-attention | 通常可训练 |
| 语言模型 | 理解与生成文本 | LLaMA、Qwen、Vicuna、Mistral | 可冻结或 LoRA |

这个拆分带来的第一个工程结论是：**三段的训练成本、显存占用和推理开销是完全不同量级的**。视觉编码器通常最小（几百 M 参数），语言模型最大（几十 B），连接器往往小得可以忽略。因此"冻结谁、训练谁"直接决定了微调成本。

### 1.1 视觉编码器：ViT 的基本盘

Vision Transformer（ViT，[arXiv:2010.11929](https://arxiv.org/abs/2010.11929)）证明了一件事：不需要 CNN 的归纳偏置，直接把图像切成 patch、当 token 序列喂给标准 Transformer，就能在图像分类上达到当时的最优。大规模预训练后，ViT 迁移到 ImageNet、CIFAR-100、VTAB 等任务时，比同期最优 CNN 使用的训练算力更少。

ViT 的几个关键工程参数：

- **patch size**：16×16 是原始设定。patch 越小，token 越多、细节越丰富，但注意力开销按平方增长。
- **分辨率**：原始 ViT 在固定分辨率上训练。后续工作普遍把分辨率提高（例如 336、448），这是多模态模型提升 OCR 和细节理解的关键一步。
- **位置编码**：标准 ViT 用可学习的绝对位置编码，换分辨率需要重新插值。

### 1.2 对比学习：CLIP 与 SigLIP

视觉编码器要输出"语言模型能用的特征"，前提是这些特征与文本语义对齐。对齐靠对比学习。

**CLIP**（[arXiv:2103.00020](https://arxiv.org/abs/2103.00020)）用 4 亿 (image, text) 对训练，任务非常朴素：给定一张图，预测哪条 caption 配它。训练完成后，CLIP 的图像特征与文本特征落在同一个空间里，可以直接用余弦相似度做零样本分类。论文报告：零样本 ImageNet 分类达到了原版 ResNet-50 的精度，而 ResNet-50 是用 128 万标注样本训练出来的。

**SigLIP**（[arXiv:2303.15343](https://arxiv.org/abs/2303.15343)，ICCV'23 Oral）把对比学习的损失从 softmax 换成 **pairwise sigmoid loss**。区别在于：softmax 需要全局归一化（一张图的 loss 依赖 batch 内所有其它样本），sigmoid 则逐对独立。带来的直接好处是 **batch size 可以大幅扩展**，小 batch 下表现也更好。论文里 batch 推到 100 万后收益递减，32k 已经足够。SigLIP 配合 Locked-image Tuning，用 4 块 TPUv4 训练两天就达到 84.5% ImageNet 零样本。

工程上要注意：**SigLIP 系列（如 SigLIP2）已成为很多开源 VLM 的默认视觉编码器**，因为它在相同参数量下通常比 CLIP 更准，且对 batch 规模更友好。

## 二、连接器：三种主流方案

连接器是整个架构里最值得讲的部分，因为它是"视觉如何进入语言"的唯一通道，也是各家方案差异最大的地方。

### 2.1 MLP 投影：LLaVA 的极简方案

**LLaVA**（[arXiv:2304.08485](https://arxiv.org/abs/2304.08485)，NeurIPS 2023 Oral）的做法简单到令人意外：视觉编码器输出的特征，经过一个**单层 MLP** 投影到语言模型的嵌入空间，然后当作普通 token 拼在文本前面。

LLaVA 的两个真正贡献不在连接器，而在数据：

- **第一次用纯语言模型（GPT-4）生成多模态指令跟随数据**。做法是让 GPT-4 只读文本标注（caption、检测框、OCR 结果），生成"图像 + 指令 + 回答"的训练样本。
- 在这个合成数据上训练后，LLaVA 相对 GPT-4 在合成多模态指令数据集上得到 85.1% 的得分；ScienceQA 上 LLaVA+GPT-4 达到 92.53% 的 SOTA。

**LLaVA-1.5**（[arXiv:2310.03744](https://arxiv.org/abs/2310.03744)，CVPR 2024 highlight）进一步证明了这个连接器"出奇地强且数据高效"。改动只有三处：

1. 把视觉编码器换成 CLIP-ViT-L-336px（分辨率 336）；
2. 把连接器从单层 MLP 换成 MLP projection；
3. 加入学术 VQA 数据，并用简单的回答格式提示。

结果是 11 个基准上的 SOTA；最终 13B 模型只用 **1.2M 公开数据**，在**单台 8×A100 节点上训练约 1 天**。这个数据效率是多模态领域的一个分水岭。

> 注意：`arXiv:2310.03777` 不是 LLaVA-1.5，它是 PrIeD-KIE（隐私保护文档关键信息抽取）。引用时别搞混。

### 2.2 Q-Former：BLIP-2 的轻量桥接

**BLIP-2**（[arXiv:2301.12597](https://arxiv.org/abs/2301.12597)）面对的问题是：CLIP 这类视觉编码器和 LLM 都很大，全量训练不起。它的方案是**两端都冻结**，中间加一个轻量的 **Querying Transformer（Q-Former）**。

Q-Former 的结构要点：

- 一组**可学习的 query token**（通常 32 个）通过 cross-attention 从冻结的视觉编码器里"抽取"信息；
- 再用一个 BERT 式的 Transformer 做自注意力，把 query 的输出投影到语言模型维度；
- 训练分两阶段：先学"从图像抽特征"，再学"把抽到的特征对齐到文本"。

效果：在零样本 VQAv2 上，BLIP-2 用**比 Flamingo-80B 少 54 倍的可训练参数**，超过了它 8.7%。这是"冻结大模型 + 小连接器"路线的代表作。

### 2.3 Cross-Attention：Flamingo 的交错序列

**Flamingo**（[arXiv:2204.14198](https://arxiv.org/abs/2204.14198)，NeurIPS）走的是另一条路：用 **cross-attention** 把冻结的视觉/语言模型桥接起来，让模型能处理**任意交错的图像和文本序列**，并且同时支持图像与视频。

Flamingo 的卖点是 **few-shot**：单个模型在不做任务微调的情况下，就能在多个基准上达到 SOTA，超过那些用数千倍任务数据微调的模型。代价是架构更复杂、工程实现难度更高。

### 2.4 三种方案的取舍

| 方案 | 代表 | 可训练参数 | 训练成本 | 工程复杂度 | 适用场景 |
| --- | --- | --- | --- | --- | --- |
| MLP 投影 | LLaVA / LLaVA-1.5 | 少（连接器 + 可选 LLM） | 低 | 低 | 资源有限、快速起步 |
| Q-Former | BLIP-2 | 很少（只有 Q-Former） | 很低 | 中 | 冻结大模型、追求参数效率 |
| Cross-Attention | Flamingo | 中等 | 中 | 高 | 交错序列、few-shot、视频 |

**经验法则**：如果你是要快速做出一个能用的多模态应用，MLP 投影是默认起点；如果你要冻结一个巨大的语言模型并且卡很紧，Q-Former 更省；如果你需要处理复杂交错的图文序列或者强 few-shot 能力，再考虑 cross-attention。

## 三、动态高分辨率：多模态的真正难点

前面的结构都是"固定分辨率"的。真实场景里图像分辨率差异极大：手机截图 1080×2400、文档扫描件 3000×4000、监控画面 4K。固定 336×336 意味着要么把长图压扁（细节丢失），要么直接报错。

**LLaVA-NeXT**（官方博客 [2024-01-30](https://llava-vl.github.io/blog/2024-01-30-llava-next/)）提出了 **AnyRes**：把高分辨率图像按宽高比切成若干块，每块单独过视觉编码器，再把所有块的特征拼起来。

网格配置为 `{2×2, 1×{2,3,4}, {2,3,4}×1}`，支持到 672×672、336×1344、1344×336 三种典型宽高比。这样一张 1344×336 的长图会被竖切成 4 块，每块 336×336，模型能"看到"完整的长边信息。

LLaVA-NeXT 的其它改进：

- **视觉指令数据混合**：移除 TextCaps（因为它的训练图像与 TextVQA 重叠，会高估零样本 OCR 能力），换成 DocVQA 和 SynDog-EN；再补充 ChartQA、DVQA、AI2D 增强图表理解。
- **复用 LLaVA-1.5 的连接器**，仍然只用不到 1M 视觉指令样本。
- **34B 变体用 32×A100 训练约 1 天**，总数据 1.3M 条。

模型卡里的关键数字（LLaVA-NeXT-34B）：

| 组件 | 参数量 |
| --- | --- |
| 总参数 | 34.75B |
| 视觉编码器 | 303.5M |
| 连接器 | 58.7M |
| 语言模型 | 34.39B |

可以看到：**视觉编码器只占 0.87%，连接器只占 0.17%**。换一个更强的视觉编码器，对总参数量的影响微乎其微，但对 OCR、图表、细粒度识别的影响可能非常大。这是选型时最容易被忽略的不对称性。

**InternVL 1.5**（[arXiv:2404.16821](https://arxiv.org/abs/2404.16821)）走了另一条路：用 **InternViT-6B** 这种 6B 级视觉编码器直接"力大砖飞"，配合动态高分辨率（按宽高比切成 1～40 个 448×448 tile，最高支持 4K）和高质量双语数据集，在 18 个基准中的 8 个拿到 SOTA。

> 这里的取舍很清楚：**用视觉编码器的参数量换细节能力**。InternViT-6B 本身就有 6B，加上语言模型后总参数量远超 LLaVA-NeXT-34B 的 34.75B。

### 3.1 视觉 token 预算

动态分辨率带来一个直接后果：**视觉 token 数量不再固定**。一张 336×336 的图可能产生 576 个 token，而一张切成 40 块的高分辨率图会产生 23040 个 token。

**Qwen2-VL**（[arXiv:2409.12191](https://arxiv.org/abs/2409.12191)）用 **Naive Dynamic Resolution**：任意分辨率的图像被切成不同数量的 visual token，再配合 **M-RoPE**（Multimodal Rotary Position Embedding）——把旋转位置编码拆成时间、高、宽三个分量，让模型知道每个 token 在图像中的二维位置。

Qwen2-VL 官方博客（[2024-08-29](https://qwenlm.github.io/blog/qwen2-vl/)）给出了一个工程上极其实用的参数：

> 每张图的 visual token 范围默认 **4–16384**，可用 `min_pixels` / `max_pixels` 设置（例如 256–1280）来平衡速度与显存。

这就是多模态推理成本失控的根源：**图像 token 可以比整个系统提示还长**。做容量规划时必须把它算进去。

## 四、视频：从空间到时间

视频理解的难点不是"多帧图像"，而是：

1. **帧数多**：一段 20 分钟视频按每秒 1 帧采样就是 1200 帧；
2. **时间关系**：动作、因果、状态变化都跨帧；
3. **音频缺失**：大多数 VLM 只看画面，不看声音。

Qwen2-VL 博客明确列出了自己的局限：**无法提取视频音频**、知识截止 2023 年 6 月、复杂指令/场景不保证准确、**计数/字符识别/3D 空间感知较弱**。这些局限不是 Qwen2-VL 独有的，而是当前 VLM 的共性。

处理长视频的常见工程手段：

- **抽帧策略**：均匀抽帧、关键帧抽取、按场景切换抽帧；
- **时间位置编码**：让模型知道每帧的时间戳（M-RoPE 的时间分量就是干这个的）；
- **分层摘要**：先把每帧/每段压成短描述，再让语言模型做全局推理；
- **滑动窗口**：超长视频切段处理，最后合并。

**DeepSeek-VL2**（[arXiv:2412.10302](https://arxiv.org/abs/2412.10302)）在视觉侧用**动态 tiling** 处理高分辨率不同宽高比图像，在语言侧用 **DeepSeekMoE + Multi-head Latent Attention（MLA）**。MLA 的核心是把 KV cache 压缩成 latent 向量，这对视频场景尤其重要——帧数越多，KV cache 越大，压缩收益越明显。DeepSeek-VL2 三个变体的激活参数量分别是 1.0B / 2.8B / 4.5B，属于"用 MoE 换推理成本"的路线。

## 五、推理引擎：多模态请求的特殊性

多模态请求在推理引擎里的行为与纯文本差异很大，主要体现在四个方面。

### 5.1 视觉 token 参与 prefill，也参与 KV cache

纯文本请求的 KV cache 只随文本长度增长。多模态请求还要加上所有视觉 token 的 KV。一张高分辨率图产生 2 万个视觉 token，就相当于凭空多了 2 万 token 的上下文。

这直接导致：

- **prefill 阶段显著变慢**：视觉编码器要跑一遍，投影要跑一遍；
- **KV cache 显存暴涨**：批大小必须相应缩小；
- **前缀缓存收益巨大**：如果系统提示和图像前缀固定不变，命中缓存后能省掉大量 prefill 计算。

### 5.2 vLLM 的多模态支持

vLLM 提供了多模态输入支持，文档在 `https://docs.vllm.ai/en/latest/features/multimodal_inputs/`，多模态数据处理细节在 `https://docs.vllm.ai/en/latest/design/mm_processing/`，示例在 `https://docs.vllm.ai/en/latest/examples/generate/multimodal/`。

> 注意：`https://docs.vllm.ai/en/latest/models/vision.html` 这个路径返回 404，正确路径是 `features/multimodal_inputs`。

vLLM 的关键设计是把多模态处理拆成**预处理阶段**（图像解码、resize、token 化）和**模型阶段**（视觉编码器 + 语言模型），让视觉编码可以独立于语言解码做调度。这对吞吐优化很重要：视觉编码是一次性的重计算，语言解码是逐 token 的增量计算。

### 5.3 部署选项

Qwen2-VL 博客推荐的部署路径：

- **`qwen-vl-utils`**：官方工具库，处理图像/视频输入的预处理；
- **flash attention 2**：显著降低长序列（尤其是视觉 token 多时）的注意力开销；
- **量化**：支持 AutoGPTQ 和 AutoAWQ；
- **vLLM 部署**：高吞吐服务的首选。

### 5.4 成本模型

多模态请求的成本可以拆成：

```
输入成本 = 文本 token × 文本单价 + 视觉 token × 视觉单价
```

视觉 token 的单价通常与文本相同或相近，但由于视觉 token 数量可能远超文本，**视觉部分往往是成本大头**。一个务实的优化是：**降低 `max_pixels`**，在不影响任务的前提下把视觉 token 数压下来。Qwen2-VL 允许通过 `min_pixels`/`max_pixels` 精确控制，这是一个非常值得用的旋钮。

## 六、幻觉与评测：多模态的特殊困难

### 6.1 多模态幻觉

多模态模型的幻觉有两种典型形态：

- **凭空生成**：图像里没有的物体、文字、数字被描述出来；
- **细节错位**：颜色、数量、位置、图表数值说错。

LLaVA-NeXT 博客提到，提高分辨率能**减少幻觉**——因为低分辨率下模型看不清，只能"猜"。这提示了一个实践方向：**当模型频繁出现细节错误时，先怀疑分辨率不够，而不是先怀疑模型能力**。

### 6.2 评测基准

多模态评测比纯文本更碎片化，常见基准：

| 基准 | 覆盖 | 备注 |
| --- | --- | --- |
| MMMU | 大学水平多模态题 | 11.5K 题，6 大学科、30 学科、183 子领域、30 种图像类型 |
| VQAv2 | 视觉问答 | 最经典 |
| TextVQA | 图中文字识别 | 对 OCR 能力敏感 |
| DocVQA / ChartQA / AI2D | 文档与图表 | 高分辨率场景关键 |
| MMBench | 综合能力 | 分中英文版本 |
| MathVista | 视觉数学推理 | 需要多步推理 |

**MMMU**（[arXiv:2311.16502](https://arxiv.org/abs/2311.16502)，CVPR 2024 Oral）是衡量"大学水平多模态理解"的基准。论文里 GPT-4V 和 Gemini Ultra 的准确率分别只有 56% 和 59%——说明这个基准对当前模型仍然很难，也说明**多模态能力的评估不能只看 VQAv2 这类简单问答**。

### 6.3 评测的三个陷阱

1. **训练数据泄漏**：LLaVA-NeXT 移除 TextCaps 就是因为它与 TextVQA 的图像重叠，会让零样本 OCR 能力被高估。自己构造评测集时要注意同类问题。
2. **只看综合分**：综合分涨了 1 分，可能只是某类简单题涨了，而 OCR 或图表能力反而掉了。**要按任务类型分桶看**。
3. **分辨率混淆**：同一模型在 336 和 672 分辨率下评测，分数差异可能很大。对比不同模型时必须对齐分辨率设置。

## 七、选型决策：一个实用的判断框架

面对一堆 VLM 方案，按下面的顺序决策：

**第一步：明确任务的分辨率需求。**

- 主要处理文档/图表/OCR → 必须选支持动态高分辨率的方案（LLaVA-NeXT AnyRes、Qwen2-VL、InternVL 动态切图）。
- 主要是自然场景问答、物体识别 → 336 分辨率可能就够，MLP 投影方案（LLaVA-1.5）足够。

**第二步：明确卡资源。**

- 单卡 24GB 以内 → 7B 级模型 + LoRA 微调，冻结视觉编码器。
- 8×A100 → 可以训练 13B～34B 的全量连接器。
- 想冻结大模型只做连接器 → BLIP-2 式 Q-Former。

**第三步：明确是否要微调。**

- 不微调，只做提示工程 → 选 zero-shot 能力强的（Flamingo 系、CLIP 系）。
- 要微调 → LLaVA-1.5 是最低成本起点（1.2M 数据、8×A100 一天）。

**第四步：明确部署形态。**

- 离线批处理 → 可以用最大的模型，慢慢跑。
- 在线服务 → 用 vLLM + flash attention 2 + 量化，并严格限制 `max_pixels`。

## 八、落地清单与度量

### 8.1 上线前检查清单

- [ ] 确定任务的**最低可用分辨率**：用一批真实样本，从 672 逐步降到 336，看哪个分辨率开始掉点。
- [ ] 确定 `min_pixels` / `max_pixels`：在分辨率与视觉 token 数之间找到平衡点。
- [ ] 统计**典型请求的视觉 token 数分布**（P50 / P95 / P99），而不只是平均值。
- [ ] 确认**前缀缓存**是否命中：系统提示 + 固定图像前缀能否复用。
- [ ] 用真实业务样本做**分桶评测**（OCR / 图表 / 自然场景 / 计数 / 空间关系），不要只看综合分。
- [ ] 测试**极端输入**：超大图、超长图、纯文字截图、低对比度扫描件、纯白图。
- [ ] 验证**视频场景**的抽帧策略与延迟是否符合预期。
- [ ] 确认音频缺失是否影响任务（VLM 普遍不处理音频）。

### 8.2 建议监控的指标

| 指标 | 为什么重要 | 建议告警阈值 |
| --- | --- | --- |
| 视觉 token 数 P95 | 直接决定 prefill 延迟与 KV cache 占用 | 超过窗口 50% 时告警 |
| 单请求首 token 延迟（TTFT） | 视觉编码 + prefill 的耗时 | 按 SLO 设定 |
| 单请求总延迟 | 端到端体验 | 按 SLO 设定 |
| 前缀缓存命中率 | 决定成本 | 低于 80% 需排查 |
| 每请求输入成本 | 视觉 token 是成本大头 | 环比上涨 20% 告警 |
| 分桶准确率 | 防止综合分掩盖退化 | 任一桶下降 5% 告警 |
| 幻觉率 | 多模态特有风险 | 抽样人工评估 |

### 8.3 常见反模式

1. **无脑提高分辨率**：分辨率翻倍，视觉 token 翻四倍，成本翻四倍，收益可能只有几个点。
2. **冻结视觉编码器却不做域适配**：自然图像上训练的编码器在文档、医学影像、工业缺陷上表现可能很差。
3. **只看 VQAv2**：简单问答高分不代表 OCR、图表、计数能力强。
4. **把视觉 token 当普通 token 计费核算**：会严重低估成本。
5. **忽略音频**：视频任务里声音往往携带关键信息，VLM 看不到。
6. **用同一套提示处理所有图像类型**：文档、图表、自然场景需要的提示策略不同。
7. **上线前不做极端输入测试**：超大图和超长图是最常见的线上故障来源。

## 小结

多模态大模型的核心是一条三段链路：**视觉编码器 → 连接器 → 语言模型**。三段的成本结构高度不对称——视觉编码器和连接器通常只占参数总量的百分之几，但它们对精度的影响可能是决定性的。

几条最实用的结论：

1. **连接器方案的选择**：MLP 投影是最低成本起点（LLaVA-1.5 用 1.2M 数据、8×A100 一天训出 11 个基准 SOTA）；Q-Former 适合冻结大模型的参数效率路线；cross-attention 适合交错序列与 few-shot。
2. **动态高分辨率是必选项**：LLaVA-NeXT 的 AnyRes（切网格）和 Qwen2-VL 的 Naive Dynamic Resolution 都指向同一结论——固定 336 分辨率无法覆盖真实场景。
3. **视觉 token 是成本与延迟的大头**：Qwen2-VL 默认 4–16384 个 visual token，必须用 `min_pixels`/`max_pixels` 主动约束。
4. **视频的关键是 KV cache**：帧数越多，KV cache 越大，MLA 这类压缩技术价值越大。
5. **评测要分桶**：MMMU 上 GPT-4V 只有 56%，说明多模态能力远未到"随便用用就行"的程度。

最后一条建议：**先量视觉 token，再谈模型选型**。很多多模态项目的成本问题，最后都归结为"没控制好图像分辨率"。

## 参考资料

1. Dosovitskiy et al., *An Image is Worth 16x16 Words: Transformers for Image Recognition at Scale* — [arXiv:2010.11929](https://arxiv.org/abs/2010.11929)
2. Radford et al., *Learning Transferable Visual Models From Natural Language Supervision*（CLIP）— [arXiv:2103.00020](https://arxiv.org/abs/2103.00020)
3. Alayrac et al., *Flamingo: a Visual Language Model for Few-Shot Learning* — [arXiv:2204.14198](https://arxiv.org/abs/2204.14198)
4. Li et al., *BLIP-2: Bootstrapping Language-Image Pre-training with Frozen Image Encoders and Large Language Models* — [arXiv:2301.12597](https://arxiv.org/abs/2301.12597)
5. Liu et al., *Visual Instruction Tuning*（LLaVA）— [arXiv:2304.08485](https://arxiv.org/abs/2304.08485)
6. Zhai et al., *Sigmoid Loss for Language Image Pre-Training*（SigLIP）— [arXiv:2303.15343](https://arxiv.org/abs/2303.15343)
7. Liu et al., *Improved Baselines with Visual Instruction Tuning*（LLaVA-1.5）— [arXiv:2310.03744](https://arxiv.org/abs/2310.03744)
8. Liu et al., *LLaVA-NeXT: Improved reasoning, OCR, and world knowledge* — [官方博客](https://llava-vl.github.io/blog/2024-01-30-llava-next/)
9. Chen et al., *InternVL: Scaling up Vision Foundation Models and Aligning for Generic Visual-Linguistic Tasks*（InternVL 1.5）— [arXiv:2404.16821](https://arxiv.org/abs/2404.16821)
10. Wang et al., *Qwen2-VL: Enhancing Vision-Language Model's Perception of the World at Any Resolution* — [arXiv:2409.12191](https://arxiv.org/abs/2409.12191)
11. Qwen2-VL 官方博客 — [qwenlm.github.io/blog/qwen2-vl](https://qwenlm.github.io/blog/qwen2-vl/)
12. Wu et al., *DeepSeek-VL2: Mixture-of-Experts Vision-Language Models for Advanced Multimodal Understanding* — [arXiv:2412.10302](https://arxiv.org/abs/2412.10302)
13. Yue et al., *MMMU: A Massive Multi-discipline Multimodal Understanding and Reasoning Benchmark for Expert AGI* — [arXiv:2311.16502](https://arxiv.org/abs/2311.16502)
14. vLLM 多模态输入文档 — [docs.vllm.ai/en/latest/features/multimodal_inputs](https://docs.vllm.ai/en/latest/features/multimodal_inputs/)
15. vLLM 多模态数据处理设计 — [docs.vllm.ai/en/latest/design/mm_processing](https://docs.vllm.ai/en/latest/design/mm_processing/)
16. vLLM 多模态示例 — [docs.vllm.ai/en/latest/examples/generate/multimodal](https://docs.vllm.ai/en/latest/examples/generate/multimodal/)
