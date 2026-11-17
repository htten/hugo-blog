---
title: "结构化输出与函数调用：JSON Schema、工具编排与容错"
description: "结构化输出与函数调用是 LLM 应用从 Demo 走向生产的两道门槛：schema 设计不严谨会让解析随机失败，工具编排没有幂等与重试会让一次网络抖动变成数据事故。本文拆解 JSON Schema 工程化、各厂商能力差异、约束解码原理、工具编排模式与容错分层，并给出可执行的落地清单。"
date: 2026-11-17
categories: ["AI 应用"]
tags: ["结构化输出", "函数调用", "JSON Schema", "工具编排", "容错"]
---

## 引言：五个反复出现的故障

做过 Agent 或数据抽取系统的团队，大概率都踩过下面这些坑：

- 模型今天按 `{ "city": "上海" }` 返回，明天变成 `{ "city": "上海市" }`，下游直接报类型错误；
- 你写了 200 行正则去解析模型的「JSON」，一次 Markdown 代码围栏就把它打穿；
- 工具调用循环里，模型第三次重试同一个写接口，线上出现三条重复记录；
- 给模型 40 个工具，它开始稳定地选错工具，但你不知道是描述写得差还是数量太多；
- 供应商升级了 API，`strict` 模式直接拒了你用了半年的 schema，服务在发布窗口里挂掉。

这些故障的共同点是：**它们都不是「模型不够聪明」，而是工程契约没定义清楚。** 结构化输出负责把模型的自由文本压缩成可验证的数据，函数调用负责把模型的意图翻译成可执行的动作，而容错负责在两者都失败时不把事故放大。

本文按这条链路展开：先讲 JSON Schema 怎么设计才经得起演进，再对比各厂商的结构化输出能力，接着解释约束解码为什么「保证 JSON 合法」不等于「保证语义正确」，然后深入工具编排与容错，最后给出一份可以直接抄进 checkist 的落地清单。

## 一、结构化输出到底解决什么

### 1.1 三类问题的边界

| 问题 | 纯文本方案 | 结构化输出方案 |
| --- | --- | --- |
| 解析失败 | 靠正则 + 人工修补，模型换版本即失效 | 由解码层保证输出是合法 JSON |
| 类型漂移 | 下游 `int()` / `dict.get()` 抛异常 | 输出前用 JSON Schema 校验 |
| 字段语义漂移 | 只能靠 prompt 反复强调 | schema 的 `description` 参与生成约束 |

关键认知是：**结构化输出保证的是「形状」，不是「语义」。** 模型可以合法地返回 `{ "city": "北京" }` 而完全答非所问。所以它不能替代评测，只能替代脆弱的解析代码。

### 1.2 什么时候不需要结构化输出

不要为了「显得专业」而到处套 schema。以下场景用纯文本更合适：

- 输出是给人看的自然语言（总结、文案、解释）；
- 结构无法在请求前确定（开放式探索、创意写作）；
- 下游只是把整段文本存起来，没有程序消费。

判断标准很简单：**如果下游有代码在读这个字段，就该有 schema；如果只有人在读，就别加。**

### 1.3 一次真实事故的代价

假设一个订单抽取服务，模型返回的 JSON 里 `amount` 有时是字符串 `"129.00"`，有时是数字 `129.0`。如果没有 schema 约束，下游 `Decimal(row["amount"])` 在字符串分支上可能正常工作，但在带千分位的 `"1,290.00"` 上崩溃。一次崩溃如果触发自动重试，重复写入的订单就是资金损失。这类问题的根因永远不是「模型抽错了」，而是**契约里没规定 `amount` 的类型和格式**。

## 二、JSON Schema 工程化

### 2.1 设计原则

一条可长期维护的 schema，通常满足以下约束：

| 原则 | 反例 | 正例 |
| --- | --- | --- |
| 明确类型 | `{"type": ["string", "null"]}` 混用 | `{"type": "string"}` |
| 枚举收敛 | `{"type": "string"}` 表示状态 | `{"enum": ["pending", "paid", "closed"]}` |
| 禁止额外字段 | 无 `additionalProperties` | `"additionalProperties": false` |
| 必填显式 | 靠模型「猜」必填 | 所有字段进 `required` |
| 描述承担语义 | `{"city": {"type": "string"}}` | 加 `description: "ISO 3166-1 alpha-3 国家码"` |
| 稳定标识 | 字段名随展示文案变 | 展示文案放 `title`，字段名不变 |

最后一条最容易被忽略：**字段名是接口契约，不是 UI 文案。** 想改展示名就改 `title`，不要改 `properties` 里的 key。

### 2.2 用代码模型生成 schema，而不是手写 JSON

手写 JSON Schema 的维护成本高，且容易和运行时校验逻辑不一致。用 pydantic 这类库从模型定义生成 schema，可以保证「校验用的」和「发给模型的」是同一份：

```python
from pydantic import BaseModel, Field
from typing import Literal

class OrderIntent(BaseModel):
    """从用户消息中抽取的订单意图。"""
    city: str = Field(description="城市名，使用中文全称，例如「上海」")
    amount: float = Field(description="订单金额，单位人民币元，不含千分位")
    status: Literal["pending", "paid", "closed"] = Field(description="订单状态")

schema = OrderIntent.model_json_schema()
print(schema)
```

这样做的收益是：加字段时只改一处，schema 自动同步；类型错误在开发期就被 pydantic 拦住。

### 2.3 版本兼容：加字段容易，删字段要命

schema 一旦上线就变成对外契约。演进规则建议固定为：

- **只加可选字段**，且新字段必须有默认值或允许 `null`；
- 删除字段前先标记 `deprecated`，观察一个发布周期；
- 破坏性变更走新 endpoint 版本（`/v2/extract`），不要原地改；
- 所有 schema 变更进入代码评审，因为它是接口契约。

一个常见错误是让模型输出「可选」的嵌套对象，然后在下游用 `data["address"]["city"]` 直接取。一旦模型合法地省略了 `address`，就是 `KeyError`。正确写法是 `data.get("address", {}).get("city")`，或者在 schema 里把 `address` 设为必填。

### 2.4 校验：生成后必须再过一遍

约束解码能保证 JSON 合法，但不保证符合你的 schema 的全部语义（取决于后端能力，见第四章）。所以生产路径上仍然要显式校验：

```python
import jsonschema

def validate(instance: dict, schema: dict) -> None:
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
    if errors:
        detail = "; ".join(
            f"{'/'.join(map(str, e.path)) or '<root>'}: {e.message}"
            for e in errors[:5]
        )
        raise ValueError(f"schema 校验失败: {detail}")
```

注意这里用的是 `Draft202012Validator`，而不是默认的 `validate()`。不同 JSON Schema 草稿版本对 `items`、`$defs` 的解释不同，混用会产生「本地校验通过、线上解码失败」的错位。

## 三、各厂商结构化输出能力对比

### 3.1 OpenAI 的 strict 模式

OpenAI 的结构化输出通过 `response_format` 指定 JSON Schema，`strict: true` 时由服务端保证输出符合 schema。但 strict 模式不是「完整 JSON Schema」，而是一个受约束的子集。

根据 OpenAI 官方文档（经第三方镜像核对，标注核对于 2026-08-03），strict 模式的支持边界如下：

| 类别 | 支持 | 不支持 |
| --- | --- | --- |
| 类型 | String / Number / Boolean / Integer / Object / Array / Enum / anyOf | 其他类型关键字 |
| string | `pattern`，`format`（限 9 种） | `minLength` / `maxLength` |
| number | `multipleOf` / `maximum` / `exclusiveMaximum` / `minimum` / `exclusiveMinimum` | 其他数值约束 |
| array | `minItems` / `maxItems` | `uniqueItems` / `contains` |
| 组合 | `anyOf`（**不得出现在根**，根必须是 object） | `allOf` / `not` / `oneOf` |
| 条件 | — | `if` / `then` / `else` / `dependentRequired` / `dependentSchemas` |
| 引用 | `$ref` / `$defs`（含递归） | — |
| 强制项 | 所有属性列入 `required`；所有对象 `additionalProperties: false` | — |

这张表的工程含义是：**如果你的 schema 用了 `allOf` 做「基础字段 + 可选扩展」的复用，strict 模式会直接拒绝。** 必须把字段拍平。这也是为什么很多团队在上线前才发现 strict 报错——本地用 `jsonschema` 校验通过了，但 OpenAI 的子集规则更窄。

调用示例：

```python
from openai import OpenAI

client = OpenAI()
resp = client.responses.parse(
    model="gpt-4o-mini",
    input="帮我把「上海，129 元，待支付」抽成订单",
    text_format=OrderIntent,   # 内部用 pydantic 生成 json_schema 并开启 strict
)
print(resp.output_parsed)
```

`responses.parse` / `chat.completions.parse` 这类封装会自动把 pydantic 模型转成 strict schema，并在解析失败时提供 `refusal` 或重试入口。

### 3.2 其它厂商与本地方案

| 方案 | 结构化输出入口 | 约束保证强度 | 备注 |
| --- | --- | --- | --- |
| OpenAI | `response_format: {type: json_schema, json_schema: {strict: true}}` | 强（服务端） | 受 strict 子集限制 |
| Anthropic | tool use（把目标结构定义成一个「工具」） | 中（模型遵循 + 客户端校验） | 无独立 json_schema 入口 |
| Google Gemini | `responseSchema` / `responseJsonSchema` | 中 | 支持字段子集，注意枚举与格式限制 |
| Ollama | `format` 参数（JSON Schema） | 中 | 本地模型遵循度依赖模型能力 |
| vLLM | `guided_json` / `guided_grammar` / `guided_regex` | 强（解码层） | 本地部署可控性最好 |
| 开源模型 | 模板 / chat template / 专用 function-call 模型 | 弱到中 | Qwen、DeepSeek 等有自己的工具调用格式 |

**选型建议**：需要强保证且能接受子集限制 → OpenAI strict；需要本地可控、可审计 → vLLM guided decoding；需要跨厂商一致 → 自己加一层 pydantic 校验，把厂商差异收敛到一个函数里。

### 3.3 别把「支持」当成「可靠」

即便服务端宣称支持，也要在真实模型上压测。常见退化行为包括：

- 长 schema（> 50 个字段）下模型开始忽略 `description`；
- 嵌套超过 3 层后，内层字段类型错误率上升；
- `enum` 值相似时（`"paid"` vs `"pending"`）选错；
- 模型用自然语言解释替代 JSON 输出（尤其在 prompt 不强调时）。

所以第三章的结论是：**schema 设计要「少而准」，不要「大而全」。**

## 四、约束解码：保证合法，不保证正确

### 4.1 原理

约束解码（constrained / guided decoding）的核心是在**解码阶段**而不是解析阶段做限制：每生成一个 token，先根据当前已生成前缀计算「下一个 token 的合法集合」，把不合法的 logits 置为负无穷。这样输出必然落在约束语言内。

对 JSON 来说，这等价于用一个有限状态机（FSM）描述「当前可以出现什么字符」：

```
START -> '{' -> KEY_OR_END
KEY_OR_END -> '"' (key) | '}' (结束)
KEY -> ... -> ':' -> VALUE
VALUE -> '"' (string) | digit | 't' | 'f' | 'n' | '{' | '['
```

### 4.2 三种实现路线

| 路线 | 代表项目 | 约束来源 | 特点 |
| --- | --- | --- | --- |
| FSM / 掩码 | outlines | JSON Schema → 正则 → FSM | 通用性强，首次编译有开销 |
| 语法编译 | XGrammar（mlc-ai） | JSON Schema / EBNF → 语法树 | 支持自适应分枝，性能好 |
| 增量解析器 | lm-format-enforcer | JSON Schema → Tokenizer 级前缀树 | 与 transformers 生态贴合 |

vLLM 把这三种都作为可选后端，通过 `guided_decoding_backend` 切换；离线推理用 `GuidedDecodingParams`：

```python
from vllm import LLM, SamplingParams
from vllm.sampling_params import GuidedDecodingParams

llm = LLM(model="Qwen/Qwen2.5-3B-Instruct")
guided = GuidedDecodingParams(json=OrderIntent.model_json_schema())
outputs = llm.generate(
    prompts="把「上海，129 元，待支付」抽成订单",
    sampling_params=SamplingParams(guided_decoding=guided, max_tokens=256),
)
```

在线服务则通过 `extra_body` 传参：

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-3B-Instruct",
    "messages": [{"role": "user", "content": "把「上海，129 元，待支付」抽成订单"}],
    "guided_json": {"type": "object", "properties": {"city": {"type": "string"}}}
  }'
```

### 4.3 合法 ≠ 符合 schema

这是约束解码最容易被误解的地方。FSM 保证的是「字符序列在语言内」，而 JSON Schema 的某些约束无法被 FSM 表达，例如：

- `maximum` / `minimum`：数值大小限制，需要语义判断；
- `pattern`：部分正则可以转 FSM，复杂正则不行；
- `enum`：可以转 FSM（有限集合）；
- `required`：可以转 FSM（状态里记录已出现字段）；
- 跨字段条件（`if/then`）：FSM 难以表达。

所以工程上正确的分层是：**解码层保证语法，校验层保证语义，评测层保证质量。** 三层都不能省。

### 4.4 约束失败时的行为

如果约束与模型分布冲突（比如 schema 要求一个很长的固定前缀），模型会「硬着头皮」生成合法但质量很差的文本。表现为：重复、空洞字段、用默认值填充。监控这个现象的指标是「约束命中率」和「约束后输出长度分布」——如果长度突然坍缩到最小值，说明模型在凑约束。

## 五、函数调用协议

### 5.1 一次调用的完整生命周期

| 阶段 | 参与者 | 常见失败 |
| --- | --- | --- |
| 1. 声明工具 | 应用 | 描述不清、参数类型错误、schema 不合法 |
| 2. 模型选择 | 模型 | 选错工具、幻觉出不存在的工具 |
| 3. 参数生成 | 模型 | 类型错、缺必填、编造 ID |
| 4. 客户端校验 | 应用 | 校验缺失导致非法参数进入执行层 |
| 5. 执行 | 应用/外部系统 | 超时、限流、权限、网络 |
| 6. 结果回填 | 应用 | 结果过大撑爆上下文 |
| 7. 模型续写 | 模型 | 忽略工具结果、重复调用 |

**第 4 步是生产环境最该加的一环。** 模型返回的参数必须过一遍和工具定义一致的 schema 校验，再决定是否执行。

### 5.2 工具定义写法

```python
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "create_order",
            "description": "在订单系统创建一笔新订单。仅在用户明确表达下单意愿时调用。",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {"type": "string", "description": "城市中文名"},
                    "amount": {"type": "number", "description": "金额（元）"},
                    "status": {"type": "string", "enum": ["pending", "paid"]},
                },
                "required": ["city", "amount"],
                "additionalProperties": False,
            },
        },
    }
]
```

三个细节决定工具选择准确率：

1. `description` 写「什么时候该用」，而不是「这个函数做什么」；
2. 参数 `description` 给出格式示例（`"例如「上海」"`）；
3. 互斥工具之间写清边界（「查订单用 get_order，不要用 list_orders」）。

### 5.3 tool_choice 语义

| 取值 | 行为 | 适用场景 |
| --- | --- | --- |
| `auto` | 模型自己决定是否调用 | 通用助手 |
| `required` | 必须调用某个工具 | 强制走结构化流程 |
| `none` | 禁止调用工具 | 纯文本回答 |
| `{type: function, function: {name: X}}` | 强制调用指定工具 | 槽位填充、分步向导 |

`required` 常被滥用来「提高工具调用率」，但会让模型在用户只是闲聊时也硬凑一个调用。更好的做法是在系统提示里明确「不需要工具时直接回答」，让 `auto` 去判断。

### 5.4 MCP：把工具接入标准化

工具接入的长期痛点是「每个应用各自定义一套工具协议」。MCP（Model Context Protocol）是一个开源标准，目标是把 AI 应用与外部系统（数据源、工具、工作流）的连接方式统一，可以类比为「AI 应用的 USB-C」。

| 维度 | 传统 function calling | MCP |
| --- | --- | --- |
| 工具定义 | 每个应用硬编码 | server 声明，client 动态发现 |
| 发现机制 | 静态列表 | `tools/list` 动态拉取 |
| 复用性 | 应用内私有 | 跨 client 复用 |
| 生态 | 碎片化 | Claude、ChatGPT、VS Code、Cursor 等均支持 |

MCP 不替代函数调用，它替代的是「工具接入层」。典型架构是：应用通过 MCP client 从多个 server 拉取工具列表，再转换成模型需要的 function calling 格式。这样新增一个数据库能力，只需要加一个 MCP server，而不需要改应用代码。

一个最小的 MCP server 声明（Python SDK 风格）大致是：

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("orders")

@mcp.tool()
def create_order(city: str, amount: float) -> dict:
    """创建一笔订单。仅在用户明确表达下单意愿时调用。"""
    return {"order_id": "ord_123", "city": city, "amount": amount}

if __name__ == "__main__":
    mcp.run()
```

## 六、工具编排

### 6.1 从单次调用到编排

单个工具调用很简单，难的是多步。常见编排模式：

| 模式 | 结构 | 优点 | 风险 |
| --- | --- | --- | --- |
| 单轮单次 | 一次调用一个工具 | 简单可控 | 只能做一步 |
| 并行调用 | 一次返回多个独立调用 | 延迟低 | 结果聚合复杂 |
| ReAct 循环 | 思考 → 调用 → 观察 → 再思考 | 灵活 | 容易跑飞、循环 |
| Plan-and-Execute | 先规划 DAG 再执行 | 可审计、可重放 | 计划可能过时 |
| 分层委派 | 主 Agent 调子 Agent | 复杂任务可分解 | 成本与延迟翻倍 |

生产系统里最稳的是 **Plan-and-Execute + 有界 ReAct**：先让模型产出计划（DAG），人工或规则校验后执行；执行中允许有限的 ReAct 修正，但必须设置步数上限。

### 6.2 工具数量与选择准确率

工具数量是选择准确率的第一杀手。经验规律（需按自己的工具集实测）：

- 10 个以内：准确率通常可接受；
- 10~30 个：需要靠描述和分组，开始出现混淆；
- 30 个以上：建议做工具检索（先按语义召回 top-k，再让模型选）。

工程做法是**两级选择**：先用向量检索或关键词把工具集从 50 个缩小到 5 个，再交给模型。这样既保留了灵活性，又避免模型在长尾工具上犯错。

### 6.3 幂等与重试

写操作必须有幂等键。否则一次超时重试就是重复下单：

```python
def call_tool(tool: str, args: dict, idempotency_key: str) -> dict:
    headers = {"Idempotency-Key": idempotency_key}
    for attempt in range(3):
        try:
            return execute(tool, args, headers=headers, timeout=10)
        except TimeoutError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
```

要点：

- 幂等键由**业务语义**生成（`hash(user_id + intent + 时间窗)`），不要用随机数；
- 重试只对**读操作**或**幂等写操作**生效；非幂等写要么禁止重试，要么先查询状态；
- 超时后不要立刻重试，先确认上一次是否已生效（查单而不是再下单）。

### 6.4 危险操作与人工确认

涉及不可逆动作（删数据、付款、发外部消息）必须加确认层：

| 风险等级 | 示例 | 处置 |
| --- | --- | --- |
| 低 | 查询、只读统计 | 自动执行 |
| 中 | 写入业务库、改配置 | 记录审计 + 可回滚 |
| 高 | 删除、对外发送、资金 | 人工确认后执行 |

实现上把「确认」建模成一次工具调用：模型返回 `request_confirmation`，应用暂停并把参数展示给人，人确认后再以同一幂等键继续。**不要**让模型自己判断「这够不够危险」——风险分级应该是代码里的静态规则。

### 6.5 沙箱、权限与超时

- 代码执行类工具必须沙箱化，限制网络、文件系统、CPU 时间；
- 工具凭据按最小权限签发，能用临时凭证就不用长期密钥；
- 每个工具独立超时，慢工具不能拖垮整个循环；
- 工具结果进上下文前做截断/摘要，避免超长结果挤占后续推理。

## 七、容错设计

### 7.1 错误分类决定处置

不要笼统地「重试」。先把错误分类：

| 错误类型 | 例子 | 处置 |
| --- | --- | --- |
| 格式错 | JSON 解析失败、缺字段 | 带错误信息重试一次，再降级 |
| 语义错 | 类型对但值不合理（金额为负） | 用规则/校验器拒绝，要求模型修正 |
| 工具不存在 | 模型编了一个工具名 | 直接返回错误列表给模型，让它重选 |
| 参数越界 | ID 不存在、枚举外取值 | 业务层拒绝，不重试 |
| 依赖故障 | 超时、限流、5xx | 指数退避 + 熔断 |
| 内容风险 | 提示注入、越权请求 | 拦截并告警，不进入执行 |

### 7.2 分层降级

```
结构化输出失败
  -> 带错误信息重试 1 次
  -> 降级到 JSON mode（只保证 JSON，不保证 schema）
  -> 正则/关键字段抽取兜底
  -> 返回「无法处理」并记录
```

关键原则：**降级路径必须显式且可观测。** 如果系统在悄悄降级，你会在某天的对账里才发现数据少了一半。

### 7.3 重试 prompt 的写法

重试时不要只说「请重试」，要把具体错误喂回去：

```python
repair_messages = messages + [
    {"role": "assistant", "content": bad_output},
    {"role": "user", "content": f"输出不符合 schema：{error_detail}。请只返回修正后的 JSON。"},
]
```

`error_detail` 越具体，修复成功率越高。实测中「city 字段应为字符串，实际为 null」比「格式错误」有效得多。

### 7.4 部分结果与 checkpoint

长链路里不要等全部成功才返回。做法：

- 每一步落库（状态机 + step 记录）；
- 失败时保存已完成步骤，支持从断点续跑；
- 对外提供幂等的「继续执行」入口。

这样一次外部依赖抖动不会让整个任务从头再来。

### 7.5 可观测性

最少要记录的字段：

| 字段 | 用途 |
| --- | --- |
| `tool_name` | 统计工具使用分布 |
| `latency_ms` | 发现慢工具 |
| `error_type` | 定位失败模式 |
| `retry_count` | 评估容错有效性 |
| `idempotency_key` | 对账与去重 |
| `schema_version` | 归因供应商升级影响 |

没有这些字段，线上问题只能靠猜。

## 八、评测与基准

### 8.1 函数调用基准

| 基准 | 规模 | 评测方式 | 关注点 |
| --- | --- | --- | --- |
| BFCL V1 | 2,000 条 question-function-answer | AST + 可执行 | 单函数/多函数/并行/相关性检测 |
| BFCL V2 | 企业贡献数据 | AST + 可执行 | 防污染、动态场景（2024-08-19 发布） |
| BFCL V3 | 多轮多步 | 执行 + 状态追踪 | 多轮依赖、多步编排（2024-09-19 发布） |
| ToolBench / ToolLLM | 万级真实 API | 执行 | 真实 API 覆盖度 |
| API-Bank | 数百条对话 | 执行 | 多轮工具调用 |

BFCL 值得单独说：它把 2,000 条数据拆成 100 Java / 50 JavaScript / 70 REST API / 100 SQL / 1,680 Python，并区分 **AST 评测**（比对函数调用结构）与 **可执行评测**（真正跑函数比对结果）。后者更接近生产，但成本更高。它还专门评测**相关性检测**——给了不相关的函数时，模型是否幻觉出调用。这个指标在生产里比「调用准确率」更重要。

### 8.2 幻觉工具与幻觉参数

两类幻觉要分开治理：

- **幻觉工具**：调用不存在的工具。治理靠工具列表收敛 + 客户端白名单校验。
- **幻觉参数**：工具存在但参数是编的（最常见的就是编造 ID）。治理靠参数校验 + 服务端二次确认。

BFCL 的相关性检测类目就是为第一类设计的：预期行为是**不调用任何工具**，而不是「随便调一个」。

### 8.3 从基准到线上

基准分数不能直接外推线上。建议自建一套小规模「影子评测」：

- 从真实流量采样 100~300 条，人工标注期望行为；
- 每次模型/prompt/工具集变更时跑一遍；
- 关注三个指标：工具选择准确率、参数合法率、端到端任务完成率；
- 用影子评测代替盲发，能在上线前拦住大部分回归。

## 九、落地清单

### 9.1 分层检查表

| 层级 | 检查项 | 通过标准 |
| --- | --- | --- |
| Schema 设计 | 类型明确、枚举收敛、禁额外字段 | 无隐式可选字段 |
| Schema 设计 | 字段名稳定、描述承担语义 | 展示名改动不改字段名 |
| 运行时 | 生成后显式校验 | 校验失败有分类与计数 |
| 运行时 | 解码后端可切换 | 能在 strict / guided / 无约束间降级 |
| 编排 | 工具数量受控 | 超过 20 个引入工具检索 |
| 编排 | 写操作幂等 | 所有写工具有幂等键 |
| 容错 | 错误分类 | 六类错误有各自处置 |
| 容错 | 降级链显式 | 无静默降级 |
| 观测 | 全链路字段 | 5 个核心字段齐全 |

### 9.2 上线前必须验证的三件事

1. **strict 兼容性**：把 schema 发给目标供应商，确认不被拒；
2. **幂等性**：对每个写工具故意超时一次，确认不产生重复副作用；
3. **降级演练**：手动让结构化输出失败，确认降级路径和告警都触发。

### 9.3 一条最小可用的生产链路

```python
def run(user_text: str) -> dict:
    # 1) 结构化抽取，失败则修复重试一次
    intent = extract_intent(user_text)          # 内部：strict -> 校验 -> repair
    # 2) 工具选择，白名单校验
    tool_calls = select_tools(intent)           # 内部：参数 schema 校验
    # 3) 执行，写操作带幂等键
    results = [call_tool(c, idempotency_key=key) for c in tool_calls]
    # 4) 续写与最终校验
    answer = finalize(results)
    return {"answer": answer, "steps": results}
```

这段代码里每个注释背后都是一类事故。把它们显式化，是结构化输出与函数调用从 Demo 走向生产的全部秘密。

## 小结

结构化输出解决的是「模型输出可被程序消费」，函数调用解决的是「模型意图可被执行」，容错解决的是「两者失败时不放大事故」。三者的共同基础是**契约先行**：schema 是契约，工具定义是契约，幂等键是契约。把契约写清楚、校验到位、降级显式、观测齐全，模型能力反而成了最不需要操心的一环。

## 参考资料

- [OpenAI — Structured model outputs（strict 模式支持子集）](https://developers.openai.com/api/docs/guides/structured-outputs)
- [apcore::schema::openai_strict（strict 模式关键字清单镜像，核对日期 2026-08-03）](https://docs.rs/apcore/latest/apcore/schema/openai_strict/index.html)
- [vLLM — Structured Outputs（guided_json / guided_grammar / guided_regex / guided_choice）](https://docs.vllm.ai/en/latest/features/structured_outputs/)
- [vLLM — Structured Outputs（离线 GuidedDecodingParams 示例，v0.7.1）](https://docs.vllm.ai/en/v0.7.1/features/structured_outputs.html)
- [vLLM 项目仓库](https://github.com/vllm-project/vllm)
- [outlines（FSM 约束解码）](https://github.com/dottxt-ai/outlines)
- [lm-format-enforcer](https://github.com/noamgat/lm-format-enforcer)
- [XGrammar（mlc-ai，语法编译约束解码）](https://github.com/mlc-ai/xgrammar)
- [Berkeley Function Calling Leaderboard 官方博客（2,000 条数据构成、AST/可执行评测、9 类榜单）](https://gorilla.cs.berkeley.edu/blogs/8_berkeley_function_calling_leaderboard.html)
- [BFCL V3 多轮多步评测博客](https://gorilla.cs.berkeley.edu/blogs/13_bfcl_v3_multi_turn.html)
- [BFCL V2 Live 博客](https://gorilla.cs.berkeley.edu/blogs/12_bfcl_v2_live.html)
- [BFCL 数据集（Hugging Face）](https://huggingface.co/datasets/gorilla-llm/Berkeley-Function-Calling-Leaderboard)
- [BFCL 评测代码仓库](https://github.com/ShishirPatil/gorilla/tree/main/berkeley-function-call-leaderboard)
- [Model Context Protocol 官方文档（什么是 MCP）](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro)
- [MCP 规范（版本 2026-07-28）](https://modelcontextprotocol.io/specification/2026-07-28)
- [MCP 项目仓库](https://github.com/modelcontextprotocol)
- [Pydantic v2 — JSON Schema 生成](https://docs.pydantic.dev/latest/concepts/json_schema/)
- [JSON Schema 官方站](https://json-schema.org/)
- [OpenAI Python SDK — chat.completions.parse / Structured Outputs 示例](https://github.com/openai/openai-python)
- [OpenAI — Function calling 指南](https://developers.openai.com/api/docs/guides/function-calling)
- [Anthropic — Tool use 文档](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview)
- [Google Cloud — Gemini function calling 文档](https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling)
- [Ollama — format 参数与结构化输出](https://docs.ollama.com/)
