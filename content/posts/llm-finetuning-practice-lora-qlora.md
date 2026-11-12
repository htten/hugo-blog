---
title: "大模型微调实战：LoRA/QLoRA、数据配比与评估"
description: "微调改变的是模型的行为，不是知识。本文从「要不要微调」讲起，拆解 LoRA/QLoRA 的省显存原理、超参起点、数据配比与格式、训练框架选型，并解释为什么 loss 下降不等于模型变好——附可运行代码与评估清单。"
date: 2026-11-12
categories: ["AI 应用"]
tags: ["微调", "LoRA", "QLoRA", "评估"]
---

## 引言：你可能早就遇到过这些问题

- 全量微调一个 70B 模型要几张卡？为什么现在大家都在说 LoRA？
- LoRA 只训练 0.1% 的参数，凭什么效果不输全量微调？rank 选 8 还是 64？
- QLoRA 说单卡 48G 就能微调 65B，4-bit 量化真的不掉精度吗？
- 数据准备 1 万条还是 100 万条？LIMA 用 1000 条就够，是真的吗？
- Alpaca 格式和 ShareGPT 格式差在哪？去重和质量哪个更值得花时间？
- 学习率、epoch、batch size 有没有靠谱起点？为什么 loss 一路降，模型却变笨了？
- 怎么评估微调效果？MMLU、GSM8K 还可信吗？LLM-as-Judge 能代替人工吗？
- 训练到一半 OOM、loss 爆炸、灾难性遗忘，分别怎么排查？

这些问题的答案分散在论文、文档、框架源码和踩坑记录里。本文把它们串成一条可执行的路径：**先判断该不该微调，再选对方法（LoRA/QLoRA），然后搞定数据，最后用对的指标验收**。

## 一、什么时候该微调

微调不是万能药。它改变的是模型的**行为**——输出格式、语气风格、领域术语、工具调用习惯——而不是往模型里"写入"新知识。

| 手段 | 适合的场景 | 不适合的场景 | 主要成本 |
| --- | --- | --- | --- |
| 提示词工程 | 任务明确、模型本身能力足够 | 需要稳定格式、稳定风格 | 低（改提示词） |
| RAG | 需要外部知识、知识经常变化 | 改变模型行为、语气、格式 | 中（检索链路） |
| 微调 | 需要稳定输出格式、领域风格、固定术语 | 注入大量新知识（容易编造） | 高（数据 + 算力） |

判断标准可以压缩成一句话：**如果你发现自己在提示词里反复写同一段"输出格式要求"，或者反复纠正模型的语气和术语，那就该考虑微调了。**

反过来，如果模型"不知道某个事实"，先想 RAG。微调注入知识的效率很低，而且容易产生"看起来合理但编造"的输出。

### 1.1 微调的典型适用场景

- **格式约束**：要求模型输出严格的 JSON、固定的报告模板、特定的 API 调用结构。
- **风格对齐**：客服话术、法律文书、医疗问诊记录，需要稳定的措辞和措辞边界。
- **领域适应**：把通用模型调到某个垂直领域（金融研报、工业维修手册、方言对话）。
- **工具调用**：让模型稳定地在正确时机调用正确的工具，减少多余调用。
- **推理习惯**：强制模型先分析再结论，或固定使用某种思维链格式。

### 1.2 微调前的三个自检

1. **提示词能不能解决？** 把提示词写到最好，再评估差距。如果提示词已经能到 90 分，微调只能省下 token，不值得。
2. **RAG 能不能解决？** 如果缺的是"知识"，RAG 的边际成本远低于微调。
3. **有没有足够的高质量数据？** 微调的上限由数据决定，不由算力决定。没有 1000 条高质量样本，别急着开训。

## 二、LoRA 的数学与工程实现

### 2.1 论文结论

LoRA（Low-Rank Adaptation）来自 Hu 等人 2021 年的论文 [arXiv:2106.09685](https://arxiv.org/abs/2106.09685)。核心做法是：**冻结预训练权重，只往 Transformer 的每一层注入可训练的低秩矩阵**。

论文里几个关键数字（对比 GPT-3 175B 用 Adam 做全量微调）：

- 可训练参数减少 **10,000 倍**
- GPU 显存需求减少 **3 倍**
- 在 RoBERTa、DeBERTa、GPT-2、GPT-3 上效果**持平或更好**
- **不引入额外推理延迟**（因为可以把低秩矩阵合并回原权重）

### 2.2 数学形式

对原始权重矩阵 $W_0 \in \mathbb{R}^{d \times d}$，LoRA 不直接更新 $W_0$，而是学习一个增量：

$$
W = W_0 + \Delta W, \qquad \Delta W = B A
$$

其中 $A \in \mathbb{R}^{r \times d}$，$B \in \mathbb{R}^{d \times r}$，$r \ll d$ 就是 **rank**。实际前向时会乘一个缩放系数 $s$：

$$
h = W_0 x + \underbrace{\frac{\alpha}{r} \cdot B A x}_{\text{LoRA 分支}}
$$

- $r$ 是秩，控制容量上限
- $\alpha$（代码里的 `lora_alpha`）是缩放系数，最终缩放是 $\alpha / r$
- 初始化时 $A$ 用 Kaiming-uniform，$B$ 全零，所以训练开始时 $\Delta W = 0$，模型行为与原始模型完全一致

### 2.3 最小可运行示例

```python
from peft import LoraConfig, get_peft_model
from transformers import AutoModelForCausalLM

model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-0.5B-Instruct")

config = LoraConfig(
    r=16,
    lora_alpha=16,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)
model = get_peft_model(model, config)
model.print_trainable_parameters()
# trainable params: 1,xxx,xxx || all params: 494,xxx,xxx || trainable%: 0.2x
```

`print_trainable_parameters()` 是判断配置是否合理的第一道关：**trainable% 在 0.1%～2% 之间通常是合理区间**。

### 2.4 target_modules 怎么选

PEFT 的 `LoraConfig` 里 `target_modules` 默认是 `None`，表示按模型架构自动选择；如果架构未知会直接报错，此时必须手动指定。

| 写法 | 含义 | 适用 |
| --- | --- | --- |
| `["q_proj", "v_proj"]` | 只对注意力的 Q、V 投影加 LoRA | 省显存、最常用 |
| `["q_proj", "k_proj", "v_proj", "o_proj"]` | 注意力全部四个投影 | 效果更好、显存更高 |
| `"all-linear"` | 对所有线性层加 LoRA | QLoRA 风格，最接近全量微调 |
| `None` | 按架构自动推断 | 快速起步 |

QLoRA 论文的做法是对**所有线性层**加 LoRA，PEFT 里用 `target_modules="all-linear"` 一行就能复现。

### 2.5 rank 和 alpha 的关系

缩放系数是 $\alpha / r$，所以：

- 只改 $r$ 不改 $\alpha$，会同时改变**容量**和**有效学习率**
- 常见做法是让 $\alpha = r$（缩放恒为 1），这样调 $r$ 只影响容量
- 另一种做法是让 $\alpha = 2r$，给低秩分支更大的更新幅度

**[Rank-Stabilized LoRA（rsLoRA）** 建议把缩放改成 $\alpha / \sqrt{r}$，这样在高 rank 时不会让有效学习率漂移。PEFT 里一个开关搞定：

```python
config = LoraConfig(r=32, lora_alpha=32, use_rslora=True, ...)
```

### 2.6 全量微调 vs LoRA vs QLoRA

| 维度 | 全量微调 | LoRA | QLoRA |
| --- | --- | --- | --- |
| 可训练参数 | 100% | 0.1%～2% | 0.1%～2% |
| 显存占用 | 最高（权重 + 梯度 + 优化器状态） | 中 | 最低（权重 4-bit） |
| 效果上限 | 最高 | 接近全量 | 接近全量 |
| 需要数据量 | 大 | 中 | 中 |
| 典型场景 | 7B 以下 + 多卡 | 单卡 / 少卡 | 单卡 + 大模型 |
| 推理延迟 | 无额外 | 无额外（合并后） | 无额外（合并后） |

## 三、QLoRA：4-bit 量化 + LoRA

### 3.1 论文结论

QLoRA 来自 Dettmers 等人 2023 年的论文 [arXiv:2305.14314](https://arxiv.org/abs/2305.14314)。论文的核心结论是：

> 通过把 4-bit 量化模型 + LoRA 结合，可以在**单张 48GB GPU 上微调 65B 模型**，同时保持与 16-bit 全量微调相当的任务效果。

论文提出的模型系列叫 Guanaco，在 Vicuna benchmark 上达到 **ChatGPT 99.3% 的水平**，且只在单卡上训练了 **24 小时**。

### 3.2 三个关键创新

1. **4-bit NormalFloat（NF4）**：一种针对正态分布权重优化的 4-bit 数据类型。论文指出，预训练权重近似正态分布，因此 NF4 在信息论上比均匀量化更优。
2. **双重量化（double quantization）**：量化本身会产生量化常数（每 256 个权重一个），再对这些常数做第二次量化。bitsandbytes 文档指出，这能额外节省约 **0.4 bits/参数**。
3. **分页优化器（paged optimizers）**：利用 NVIDIA 统一内存，在显存吃紧时把优化器状态分页换出到内存，避免因偶发的显存尖峰直接 OOM。

### 3.3 量化 + LoRA 的标准写法

```python
import torch
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

# 1. 以 4-bit 加载基座
quant_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_use_double_quant=True,
    bnb_4bit_compute_dtype=torch.bfloat16,
)
model = AutoModelForCausalLM.from_pretrained(
    "meta-llama/Llama-2-13b-chat-hf",
    quantization_config=quant_config,
    device_map="auto",
)

# 2. 为 k-bit 训练做准备（冻结基座、开梯度检查点、归一化输入）
model = prepare_model_for_kbit_training(model)

# 3. 挂 LoRA
lora_config = LoraConfig(
    r=16,
    lora_alpha=16,
    target_modules="all-linear",
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)
model = get_peft_model(model, lora_config)
model.print_trainable_parameters()
```

`prepare_model_for_kbit_training` 这一步不能省。它负责把量化后的模型处理成"可安全反向传播"的状态，包括冻结基座参数、启用输入梯度、处理 layer norm 的数值稳定性。

### 3.4 量化对效果的影响

QLoRA 论文用超过 1000 个模型的实验说明：**4-bit 量化 + LoRA 的效果可以接近 16-bit 全量微调**。但这是在"数据质量足够、超参合理"的前提下。

实际工程里要注意：

- 量化误差在**小模型**上相对更明显，7B 以下模型用 4-bit 微调要格外验证效果。
- 推理阶段，`bnb_4bit_quant_type` 对效果影响不大；但训练阶段用 NF4 是论文推荐做法。
- 量化模型**不能直接 dequantize 回原精度**而不损失质量，合并 LoRA 时要在量化域内操作。

### 3.5 双卡口的显存账

bitsandbytes 文档给了一个参考：开启 nested quantization 后，可以在 **16GB 的 NVIDIA T4** 上微调 **Llama-2-13b**，条件是序列长度 1024、batch size 1、梯度累积 4 步。

这说明 QLoRA 的价值不只在"能不能跑起来"，更在**单卡可实验**——你可以在一张消费级卡上把整个流程跑通，再决定要不要上多卡。

## 四、超参实战

### 4.1 一张起点表

下表是社区和文档里较常被引用的起点，不是真理，但是个省事的起点。

| 超参 | 推荐起点 | 说明 |
| --- | --- | --- |
| `r` | 8 / 16 / 32 | 从 16 开始，效果不够再加 |
| `lora_alpha` | 等于 `r` | 缩放恒为 1，便于单独调 rank |
| `lora_dropout` | 0.05 | 数据少时加到 0.1 |
| `target_modules` | `q_proj`+`v_proj` | 显存紧就用两个，宽裕就四个 |
| `learning_rate` | 1e-4 | LoRA 通常比全量微调高一个量级 |
| `num_train_epochs` | 1～3 | 小数据集容易过拟合，先跑 1 个 epoch 看 |
| `per_device_train_batch_size` | 1～4 | 配合梯度累积 |
| `gradient_accumulation_steps` | 4～16 | 让有效 batch size 到 16～32 |
| `lr_scheduler_type` | `cosine` | 配 3%～10% 的 warmup |
| `weight_decay` | 0.0～0.1 | 从 0 开始 |
| `max_seq_length` | 1024～4096 | 按数据长度分布定，别盲目开大 |
| `bf16` / `fp16` | `bf16=True` | Ampere 及以后优先 bf16 |

### 4.2 学习率：LoRA 和全量微调不是一个量级

TRL 文档里专门给了一条提示：训练 adapter 时通常用**更高的学习率（约 1e-4）**，因为只有新参数在学。全量微调的学习率一般在 1e-5～5e-5。

```python
from trl import SFTConfig

args = SFTConfig(
    learning_rate=1e-4,
    num_train_epochs=1,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,
    lr_scheduler_type="cosine",
    warmup_ratio=0.03,
    max_seq_length=2048,
    bf16=True,
    logging_steps=10,
)
```

### 4.3 epoch 不是越多越好

微调最常见的失败不是"训得不够"，而是**过拟合**。判断信号：

- 训练 loss 持续下降，验证 loss 开始上升
- 模型开始逐字背诵训练样本
- 输出变得僵硬、重复、模板化

经验做法：先跑 1 个 epoch，在留出集上评测；如果还在涨，再跑第 2 个 epoch。**不要一上来就 5 个 epoch。**

### 4.4 rank 越大越好吗

不是。rank 决定容量上限，但容量用满需要足够的数据。经验规律：

- 数据少于 1000 条：`r=8` 或 `r=16`
- 数据 1000～10000 条：`r=16` 或 `r=32`
- 数据几万条以上：`r=32` 或 `r=64`
- rank 开到 128 以上：只在数据量很大、任务很复杂时才考虑

一个实用的调试顺序：**先固定 rank=16 跑通流程，再扫 rank ∈ {8, 16, 32, 64}，用留出集选最优**。

### 4.5 初始化方法

除了默认的 Kaiming-uniform + 零初始化，PEFT 还内置了几种改进初始化：

| 方法 | 作用 | 开启方式 |
| --- | --- | --- |
| 默认 | A 用 Kaiming-uniform，B 全零 | 不设置 |
| LoftQ | 让 LoRA 初始化就尽量抵消量化误差 | `init_lora_weights="loftq"` |
| PiSSA | 用主奇异向量初始化，收敛更快 | `init_lora_weights="pissa"` |
| rsLoRA | 缩放改成 $\alpha/\sqrt{r}$ | `use_rslora=True` |
| DoRA | 把权重分解成幅度和方向分别训练 | `use_dora=True` |

这些不是必选项。先用默认跑通，再按需要逐个尝试。

## 五、数据工程：配比、去重与格式

### 5.1 数据质量比数量重要

LIMA 论文（[arXiv:2305.11206](https://arxiv.org/abs/2305.11206)）是一个常被误读的证据：

> 作者用**仅 1000 条**精心策划的 prompt-response，在 65B LLaMA 上做标准监督微调，没有用任何强化学习，就在受控人工研究中取得与 GPT-4 相当或更优 43% 的结果。

重点在"精心策划"四个字，而不是"1000 条"。LIMA 的结论不是"数据越少越好"，而是**质量、多样性、一致性比数量更关键**。

实战里的推论：

- 1000 条高质量、格式统一、覆盖目标场景的样本，通常好过 10 万条来源混杂的样本
- 宁可少而准，不要多而杂
- 数据里混入少量错误样本，模型会稳定地学会错误模式

### 5.2 两种主流数据格式

**Alpaca 格式**（Stanford Alpaca 项目使用的格式）：

```json
{
  "instruction": "把下面这句话翻译成英文",
  "input": "今天天气不错",
  "output": "The weather is nice today."
}
```

**ShareGPT 格式**（多轮对话）：

```json
{
  "conversations": [
    {"from": "human", "value": "你好"},
    {"from": "gpt", "value": "你好，有什么可以帮你的？"},
    {"from": "human", "value": "介绍一下你自己"}
  ]
}
```

TRL 的 `SFTTrainer` 支持四种格式：标准语言建模（`text`）、对话式语言建模（`messages`）、标准 prompt-completion（`prompt` + `completion`）、对话式 prompt-completion。数据不符合格式时，用 `formatting_func` 或 `dataset_text_field` 做转换。

```python
from trl import SFTTrainer, SFTConfig
from datasets import load_dataset

dataset = load_dataset("tatsu-lab/alpaca", split="train")

trainer = SFTTrainer(
    model="Qwen/Qwen2.5-0.5B-Instruct",
    args=SFTConfig(max_seq_length=2048, learning_rate=1e-4),
    train_dataset=dataset,
    formatting_func=lambda x: f"{x['instruction']}\n{x['input']}\n\n{x['output']}",
)
```

### 5.3 数据清洗清单

- **去重**：完全重复和近似重复都要去掉。近似重复可以用 MinHash / SimHash 或 embedding 相似度。
- **去污染**：把评测集里的题目从训练集里删掉，否则 benchmark 分数虚高。
- **长度分布**：检查 token 长度分布，避免绝大多数样本都集中在某个长度，导致 `max_seq_length` 浪费或截断。
- **标签一致性**：同一个指令在不同样本里的输出风格要一致，否则模型会学到矛盾的模式。
- **错误样本**：人工抽检 100～200 条，统计错误率。错误率超过 5% 就该重新做数据。
- **难度分布**：全是最简单的样本，模型学不到推理；全是难题，模型学不会基础格式。

### 5.4 数据配比

如果你要在一个模型上同时保留多种能力（通用对话 + 垂直领域 + 代码），配比就很重要：

| 数据类型 | 建议占比 | 目的 |
| --- | --- | --- |
| 通用指令数据 | 30%～50% | 防止灾难性遗忘，保留通用能力 |
| 目标领域数据 | 30%～50% | 教会目标格式和风格 |
| 代码 / 数学 | 10%～20% | 维持推理能力 |
| 安全 / 拒答数据 | 5%～10% | 保持边界 |

配比不是固定的。核心原则是：**目标领域数据要足够让模型学会格式，通用数据要足够防止模型变窄。**

### 5.5 训练时只对回答算 loss

多轮对话数据里，如果对 user 和 assistant 的内容都算 loss，模型会学会"生成用户会说的话"，而不是"生成助手会说的话"。

TRL 提供了两个开关：

```python
# 对话数据：只对 assistant 消息算 loss
SFTConfig(assistant_only_loss=True)

# prompt-completion 数据：默认只对 completion 算 loss
SFTConfig(completion_only_loss=True)
```

`assistant_only_loss=True` 要求 chat template 里包含 `{% generation %}` 和 `{% endgeneration %}` 标记；TRL 对 Qwen3 等已知模型族会自动打补丁。

## 六、训练框架与工具链

| 框架 | 定位 | 适合谁 | 特点 |
| --- | --- | --- | --- |
| PEFT + TRL | 官方组合，脚本化 | 想快速跑通、要可控 | 生态最完整，文档最齐 |
| Axolotl | 配置驱动，YAML | 想复现、要调参 | 支持 LoRA/QLoRA/GPTQ/QAT、DPO/GRPO、FSDP2/DeepSpeed |
| Unsloth | 性能优先 | 单卡、想省显存省时间 | 官方称 2× 更快、70% 更少显存 |
| llama.cpp | 本地/边缘推理 | 想在 CPU/消费级卡推理 | 训练示例标注 WIP，不是训练主战场 |
| DeepSpeed / FSDP | 分布式后端 | 多卡训练 | 通常作为上述框架的后端 |

### 6.1 PEFT + TRL：最小闭环

```python
from datasets import load_dataset
from peft import LoraConfig
from trl import SFTConfig, SFTTrainer

dataset = load_dataset("tatsu-lab/alpaca", split="train")

trainer = SFTTrainer(
    model="Qwen/Qwen2.5-0.5B-Instruct",
    args=SFTConfig(
        output_dir="./out",
        learning_rate=1e-4,
        num_train_epochs=1,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=8,
        max_seq_length=2048,
        bf16=True,
        packing=True,
    ),
    train_dataset=dataset,
    peft_config=LoraConfig(
        r=16,
        lora_alpha=16,
        target_modules="all-linear",
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    ),
)
trainer.train()
trainer.save_model("./out/final")
```

`packing=True` 会把多条短样本拼进同一个序列，显著提升短数据集的训练效率。

### 6.2 Axolotl：用 YAML 描述整个流程

Axolotl 把数据预处理、训练、评估、量化、推理都收进一个 YAML 文件，适合需要复现和批量的场景。它支持 LoRA、QLoRA、GPTQ、QAT（int8/int4/FP8/NVFP4/MXFP4）、DPO/IPO/KTO/ORPO、GRPO 等方法。

```yaml
base_model: Qwen/Qwen2.5-7B-Instruct
model_type: AutoModelForCausalLM
load_in_4bit: true
adapter: qlora

lora_r: 16
lora_alpha: 16
lora_dropout: 0.05
lora_target_modules: [q_proj, k_proj, v_proj, o_proj]

datasets:
  - path: tatsu-lab/alpaca
    type: alpaca

sequence_len: 2048
max_packed_sequence_len: 2048
sample_packing: true

output_dir: ./out
learning_rate: 1.0e-4
num_epochs: 1
micro_batch_size: 2
gradient_accumulation_steps: 8
```

### 6.3 Unsloth：单卡提速

Unsloth 官方 README 声称：训练速度提升 **2×**，显存占用减少 **70%**，且不损失精度；支持 LoRA、QLoRA、全量微调、预训练、RL、GRPO、DPO、FP8。

它的用法与 HF 生态兼容，典型写法：

```python
from unsloth import FastLanguageModel

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="unsloth/Qwen2.5-7B-Instruct-bnb-4bit",
    max_seq_length=2048,
    load_in_4bit=True,
)
model = FastLanguageModel.get_peft_model(
    model, r=16, lora_alpha=16, lora_dropout=0.0,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    use_rslora=False, use_gradient_checkpointing="unsloth",
)
```

注意：`use_gradient_checkpointing="unsloth"` 是它省显存的关键开关之一。

### 6.4 llama.cpp 的定位

llama.cpp 的 `examples/training` 提供了 `llama-finetune`，但官方 README 明确写着：

> finetuning is technically functional (for FP32 models and limited hardware setups) but the code is very much WIP.

并且训练时会禁用 flash attention（因为 `FLASH_ATTN_EXT` 没有反向传播）。代码里只支持加载已有的 LoRA 适配器，不是训练 LoRA 的主要路径。

**结论**：想训练 LoRA/QLoRA，用 HF 生态（PEFT/TRL/Axolotl/Unsloth）；llama.cpp 负责训练完之后的本地推理。

## 七、评估：loss 不等于效果

### 7.1 为什么 loss 不可信

训练 loss 只说明"模型在训练集上更会预测下一个 token 了"，它不说明：

- 模型是否学会了你想要的格式
- 模型是否还保留通用能力
- 模型是否开始编造
- 模型在真实用户输入上是否真的更好

一个典型反例：训练 loss 一路下降，模型学会了逐字背诵训练样本，留出集上的实际任务成功率反而下降——这就是过拟合。

### 7.2 三层评估体系

| 层次 | 方法 | 回答的问题 | 成本 |
| --- | --- | --- | --- |
| L1 自动指标 | 训练/验证 loss、perplexity、格式合法率 | 训练是否稳定、格式是否学会 | 低 |
| L2 标准 benchmark | MMLU、GSM8K 等 | 通用能力是否退化 | 中 |
| L3 任务评测 | 留出集人工评 / LLM-as-Judge | 目标场景是否真的变好 | 高 |

**L1 用来判断训练有没有崩，L3 用来判断该不该上线。** L2 用来做回归检查，防止微调把通用能力打坏。

### 7.3 常用 benchmark 的适用边界

| Benchmark | 内容 | 适合 | 注意 |
| --- | --- | --- | --- |
| MMLU | 57 个学科的多选题 | 通用知识广度 | 容易被数据污染，分数虚高 |
| GSM8K | 8.5K 道小学数学应用题 | 多步数学推理 | 只覆盖数学，不代表通用推理 |
| MT-Bench | 多轮开放问题 | 对话能力 | 用 GPT-4 做裁判 |
| Arena-Hard-Auto | 500 条高难度开放问题 | 区分度高 | 自动裁判，与人类偏好 98.6% 相关 |
| AlpacaEval | 指令跟随 | 快速迭代 | 有长度偏置，用 length-controlled 版 |

MMLU 来自 [arXiv:2009.03300](https://arxiv.org/abs/2009.03300)（57 个任务）；GSM8K 来自 [arXiv:2110.14168](https://arxiv.org/abs/2110.14168)（8.5K 道题）。

MT-Bench 与 Chatbot Arena 来自 [arXiv:2306.05685](https://arxiv.org/abs/2306.05685)。论文报告：强 LLM 裁判与人类偏好的吻合度**超过 80%**，与人类之间的一致性水平相当；同时指出了位置偏置、冗长偏置、自我增强偏置等局限。

Arena-Hard-Auto 来自 [arXiv:2406.11939](https://arxiv.org/abs/2406.11939)：500 条 prompt，相比 MT-Bench 有 3 倍的性能区分度，与人类偏好排名 98.6% 相关，自动评测成本约 20 美元。

AlpacaEval 的长度控制版本来自 [arXiv:2404.04475](https://arxiv.org/abs/2404.04475)：通过回归控制长度偏置后，与 LMSYS Chatbot Arena 的 Spearman 相关从 0.94 提升到 0.98。

### 7.4 LLM-as-Judge 的使用守则

LLM-as-Judge 是可扩展的，但有系统性偏差：

- **位置偏置**：两个答案的顺序会影响判断 → 跑两遍，交换顺序
- **冗长偏置**：更长的答案更容易被判赢 → 用 length-controlled 指标
- **自我增强偏置**：模型偏好自己风格的输出 → 换一个不同家族的模型当裁判
- **推理能力有限**：涉及复杂推理的题目，裁判本身会判错

实用做法：**用 LLM-as-Judge 做初筛，用人工抽检做校准**。比如每 100 条里抽 10 条人工判，算裁判与人工的一致率，低于 80% 就换裁判模型或改 prompt。

### 7.5 留出集设计

评估集不能随便切。建议：

- 从目标场景的真实输入里抽 100～500 条
- 覆盖简单、中等、困难三档
- 覆盖常见失败模式（格式错误、拒答、幻觉）
- 固定下来，每次微调都用同一套

**没有固定留出集，就无法判断"这次微调是否比上次好"。**

## 八、常见故障排查

| 现象 | 可能原因 | 排查 / 处置 |
| --- | --- | --- |
| OOM（显存不足） | batch 太大、序列太长、模型太大 | 降 batch、开梯度检查点、降 `max_seq_length`、用 QLoRA、用 Unsloth |
| loss 不降 | 学习率太低、数据格式错、loss 被 mask 掉 | 先打印几条样本确认格式；把学习率提到 1e-4 |
| loss 爆炸 / NaN | 学习率太高、bf16 溢出、数据里有异常值 | 降学习率、开梯度裁剪、检查数据 token 分布 |
| 训练 loss 降但效果变差 | 过拟合、灾难性遗忘 | 减 epoch、加通用数据、降 rank |
| 输出格式错乱 | 数据格式不统一、loss 算到了 prompt | 检查 `assistant_only_loss` / `completion_only_loss` |
| 模型开始编造 | 用微调注入知识 | 改用 RAG |
| benchmark 涨了但用户觉得变差 | benchmark 污染、评测集不匹配真实场景 | 检查训练集与评测集是否重叠 |
| 训练速度极慢 | 没用 packing、没开 flash attention、数据加载阻塞 | 开 `packing=True`、用 flash-attn 2、检查 dataloader worker 数 |

### 8.1 梯度检查点

梯度检查点（gradient checkpointing）用时间换显存：反向传播时重新计算部分激活，而不是全部缓存。QLoRA 的 `prepare_model_for_kbit_training` 默认会开启。

```python
model.gradient_checkpointing_enable()
model.enable_input_require_grads()   # 配合量化模型
```

### 8.2 灾难性遗忘

微调后模型"变窄"——只会目标任务，不会通用对话了。处置：

- 混入 30%～50% 通用指令数据
- 减少训练 epoch
- 降低学习率
- 用更小的 rank

### 8.3 合并与部署

训练完的 LoRA 适配器只有几 MB 到几百 MB，可以：

- 单独保存适配器，推理时动态挂载（多租户场景）
- 合并回基座权重（`model.merge_and_unload()`），得到一个普通模型，推理无额外开销

```python
merged = model.merge_and_unload()
merged.save_pretrained("./merged-model")
```

合并后再做量化（GPTQ/AWQ）通常比"量化 + 训练"更容易部署。

## 九、落地清单与度量

### 9.1 微调前

- [ ] 已确认提示词和 RAG 都无法满足需求
- [ ] 已准备至少 1000 条高质量、格式统一的目标数据
- [ ] 已准备固定的 100～500 条留出评测集
- [ ] 已确认训练集与评测集无重叠
- [ ] 已明确目标指标（格式合法率、任务成功率、用户满意度）

### 9.2 训练中

- [ ] `print_trainable_parameters()` 的 trainable% 在 0.1%～2%
- [ ] 训练 loss 稳定下降，无 NaN
- [ ] 验证 loss 没有持续上升（过拟合信号）
- [ ] 每 10～50 步抽样看一次生成结果

### 9.3 上线前

- [ ] 留出集上的目标指标优于微调前基线
- [ ] 通用 benchmark（MMLU/GSM8K）没有明显退化（建议阈值：下降 < 2 个点）
- [ ] 人工抽检 50～100 条真实输入，通过率达标
- [ ] 已合并适配器或确认动态挂载方案
- [ ] 已准备回滚路径（保留原模型）

### 9.4 建议跟踪的指标

| 指标 | 定义 | 建议阈值 |
| --- | --- | --- |
| 格式合法率 | 输出能被目标 parser 解析的比例 | > 98% |
| 任务成功率 | 留出集上人工判定正确的比例 | 比基线提升 > 10% |
| 通用能力保持率 | MMLU/GSM8K 相对基线的变化 | 下降 < 2 个点 |
| 平均输出长度 | 生成 token 数 | 与目标场景匹配 |
| 拒答正确率 | 该拒答的场景里正确拒答的比例 | > 95% |
| 训练稳定性 | 出现 NaN / loss 尖峰次数 | 0 |

## 小结

- **微调改变行为，不注入知识**。需要知识先想 RAG，需要稳定格式和风格再想微调。
- **LoRA 用低秩矩阵替代全量更新**，可训练参数减少上千倍、显存减少约 3 倍，且合并后无推理延迟。
- **QLoRA = 4-bit 量化基座 + LoRA**，靠 NF4、双重量化、分页优化器把 65B 微调压进单张 48GB 卡。
- **数据质量比数量重要**。LIMA 的 1000 条是"精心策划"，不是"越少越好"。
- **loss 下降不等于模型变好**。用固定留出集 + 人工抽检做最终验收，用 LLM-as-Judge 做可扩展初筛。
- **先跑通再调优**：rank=16、lr=1e-4、1 个 epoch、验证集先立好，然后按指标迭代。

## 参考资料

- [LoRA: Low-Rank Adaptation of Large Language Models (arXiv:2106.09685)](https://arxiv.org/abs/2106.09685)
- [QLoRA: Efficient Finetuning of Quantized LLMs (arXiv:2305.14314)](https://arxiv.org/abs/2305.14314)
- [Hugging Face PEFT — LoRA 文档](https://huggingface.co/docs/peft/package_reference/lora)
- [Hugging Face PEFT — 量化指南](https://huggingface.co/docs/peft/developer_guides/quantization)
- [Hugging Face Transformers — bitsandbytes 量化](https://huggingface.co/docs/transformers/main/en/quantization/bitsandbytes)
- [Hugging Face TRL — SFT Trainer 文档](https://huggingface.co/docs/trl/sft_trainer)
- [Unsloth — Fast LoRA Fine-Tuning](https://github.com/unslothai/unsloth)
- [Axolotl — 配置驱动的训练框架](https://github.com/axolotl-ai-cloud/axolotl)
- [llama.cpp — examples/training 说明](https://github.com/ggml-org/llama.cpp/tree/master/examples/training)
- [LIMA: Less Is More for Alignment (arXiv:2305.11206)](https://arxiv.org/abs/2305.11206)
- [Measuring Massive Multitask Language Understanding / MMLU (arXiv:2009.03300)](https://arxiv.org/abs/2009.03300)
- [Training Verifiers to Solve Math Word Problems / GSM8K (arXiv:2110.14168)](https://arxiv.org/abs/2110.14168)
- [Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena (arXiv:2306.05685)](https://arxiv.org/abs/2306.05685)
- [Arena-Hard and BenchBuilder Pipeline (arXiv:2406.11939)](https://arxiv.org/abs/2406.11939)
- [Length-Controlled AlpacaEval (arXiv:2404.04475)](https://arxiv.org/abs/2404.04475)
- [Stanford Alpaca 项目](https://github.com/tatsu-lab/stanford_alpaca)
