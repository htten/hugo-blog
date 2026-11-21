---
title: "LLM 应用可靠性工程：重试、降级、幂等与限流"
description: "面向 LLM 应用调用层的可靠性工程实践：拆解 HTTP 状态码的可重试语义（408/409/429/5xx）、RFC 9110 对幂等方法与 Retry-After 的规范定义、Envoy 熔断与 retry budget 的并发上限设计，以及幂等键、流式响应、限流令牌桶的落地边界与常见陷阱。"
date: 2026-11-21
categories: ["AI 应用"]
tags: ["可靠性", "重试", "降级", "限流"]
---

## 引言：LLM 应用的故障大多不是"模型挂了"，而是"超时后不知道该不该重试"

跑过 LLM 应用的人几乎都遇到过这样一幕：用户点了生成，页面转了 40 秒，然后弹出一个"服务繁忙，请稍后重试"。你重试一次，它好了；你重试两次，它报"请求已提交"。再往后，账单多了一笔，客服收到一条"为什么扣了我两次钱"。

这类事故的共同点是：**上游模型 API 是一个概率性的、共享资源的、有排队延迟的远端服务**，而你的应用代码把它当成了一个"要么成功要么失败"的确定性函数。两者之间的语义鸿沟，就是 LLM 应用可靠性工程的全部内容。

先看几个具体问题。它们看起来琐碎，但每一个都对应一次真实的生产故障：

- 收到 **429** 之后我应该等多久？服务端返回了 `Retry-After`，我到底要不要采信它，还是自己算指数退避？
- 我给模型调用加了三层重试封装，结果上游过载时重试量翻了三倍，反而把下游打挂——**重试是放大器还是稳定器**？
- 用户的对话要落库、要扣配额、要触发下游动作。这三步里第二步成功了，第三步超时了，我能不能直接重试整个请求？**幂等键到底该放在哪一层**？
- 流式响应已经吐了 200 个字给用户，突然连接断了。我能重连续接吗？**重放会不会让用户看到两遍内容**？
- 熔断器阈值设多少？设 5% 错误率熔断，结果正常业务抖动直接全挂；设 50%，等于没熔断。**阈值该怎么算，而不是怎么抄**。

本文要把这些问题落到可执行的工程结论上。方法是：先讲清 HTTP 层到底规定了哪些语义（这部分是**已确认**的，有 RFC 原文和 SDK 源码支撑），再讲熔断与限流怎么设计（**工程经验**为主），最后给一张端到端的检查清单。

全文区分三类陈述：

- **已确认**：有 RFC、官方文档或源码可以直接支撑的机制与数字。
- **工程经验**：业界常见做法，数字随场景变化，需要在自己的流量上验证。
- **待验证**：需要你用自己的数据做实验才能确定的结论。

> 边界说明：本文讨论的是 **LLM 应用调用层**的可靠性——即你的服务与模型 API 之间的那一段 HTTP 调用与状态管理。与 Agent 的任务级可靠性（长任务编排、工具失败恢复、状态持久化）不是同一层问题，那部分另有讨论。

---

## 一、先把 HTTP 语义搞清楚：哪些错误可以重试

重试的第一个前提是知道**哪些错误重试有意义**。这部分不需要靠猜，HTTP 规范里写得很清楚，只是大部分人没读过。

### 1.1 五类错误的性质完全不同

RFC 9110（STD 97，2022 年 6 月）里对状态码的分类，直接决定了重试策略。按**已确认**的规范原文：

| 状态码 | 规范原文要点 | 语义 | 可重试性 |
| --- | --- | --- | --- |
| 400 Bad Request | "the server cannot or will not process the request due to something that is perceived to be a client error" | 请求本身有问题 | **不可重试**，重试没有意义 |
| 408 Request Timeout | "the server did not receive a complete request message within the time that it was prepared to wait" | 服务端没在时限内收全请求 | **可重试**（但要确认请求体可安全重发） |
| 409 Conflict | "the request could not be completed due to a conflict with the current state of the target resource" | 资源状态冲突 | **通常不可重试**，需先解决冲突 |
| 429 Too Many Requests | "the user has sent too many requests in a given amount of time ('rate limiting')" | 被限流 | **可重试**，但必须退避 |
| 500 Internal Server Error | "the server encountered an unexpected condition that prevented it from fulfilling the request" | 服务端内部异常 | **可重试**（请求幂等的前提下） |
| 503 Service Unavailable | "the server is currently unable to handle the request due to a temporary overload or scheduled maintenance, which will likely be alleviated after some delay" | 临时过载或维护 | **可重试**，且规范明确建议用 `Retry-After` |

这六行里最有价值的是**最后两行的对比**：500 和 503 都是服务端错误、都应该重试，但 503 的定义里明确写了 "temporary"（临时的）和 "likely be alleviated after some delay"（延迟后大概率会缓解）。而 500 的定义是 "unexpected condition"——意外状况。**你的重试逻辑应该对这两者区别对待**：503 是"过载信号"，是让你退避的提示；500 是"未知异常"，是让你告警的信号。

规范还给了两条实操提示：

- 408 的原文："If the client has an outstanding request in transit, it MAY repeat that request."——明确允许重发未完成请求。
- 409 的原文："This code is used in situations where the user might be able to resolve the conflict and resubmit the request."——**它假设的是用户去解决冲突**，而不是客户端盲目重试。把 409 当成"服务端忙"来重试，是很多线上雪崩的起点。

### 1.2 Retry-After：规范怎么定义它

`Retry-After` 是 LLM 应用最该用好、却最常被忽略的响应头。RFC 9110 §10.2.3 的定义是：

> "Servers send the 'Retry-After' header field to indicate how long the user agent ought to wait before making a follow-up request. When sent with a 503 (Service Unavailable) response, Retry-After indicates how long the service is expected to be unavailable to the client. When sent with any 3xx (Redirection) response, Retry-After indicates the minimum time that the user agent is asked to wait before issuing the redirected request."

值的语法：

```
Retry-After = HTTP-date / delay-seconds
delay-seconds = 1*DIGIT
```

也就是说，**它可以是秒数，也可以是 HTTP 日期**。规范给了两个例子：

```
Retry-After: Fri, 31 Dec 1999 23:59:59 GMT
Retry-After: 120
```

这里有一个非常容易踩的坑（**已确认**的语法事实 + **工程经验**的处置）：很多 SDK 把这个头统一解析成一个整数秒数，遇到 HTTP-date 格式就返回 `None`，然后你的代码 fall back 到指数退避——这本身不算错，但如果你**同时**还有自己算的退避逻辑，就可能出现"服务端让我等 120 秒，我等了 2 秒就重试"的叠加错误。**处置原则（工程经验）**：`Retry-After` 与本地退避取**较大值**，而不是二选一；并且服务端给了 `Retry-After` 时，应当**以它为准**并在其之上叠加抖动（jitter），而不是用本地公式覆盖它。

另外，429 的规范（RFC 6585）也允许带 `Retry-After`："the response content SHOULD include details explaining the condition, and MAY include a Retry-After header field indicating how long to wait before making a new request."

### 1.3 一个能直接用的状态码决策表

把上面两节合起来，产出一张**工程经验**性质的重试决策表（这是实现层面的归纳，不是 RFC 原文）：

| 情况 | 动作 | 退避策略 | 是否告警 |
| --- | --- | --- | --- |
| 400 / 401 / 403 / 404 / 422 | 立即失败，不重试 | — | 4xx 配额低时告警 |
| 408 | 重试 | 指数退避 + 抖动 | 连续失败才告警 |
| 409 | 失败并透出冲突信息 | — | 视业务，通常不告警 |
| 429 | 重试 | **优先采信 `Retry-After`**，否则指数退避 + 抖动 | 触发限流阈值时告警 |
| 500 | 重试（幂等前提下） | 指数退避 + 抖动 | **必须告警** |
| 502 / 503 / 504 | 重试 | 同上，503 优先用 `Retry-After` | 503 持续超阈值告警 |
| 连接错误 / DNS / TLS | 重试 | 指数退避 + 抖动 | 连续失败告警 |

注意 401/403 在这张表里被归为"不重试"——因为重试一个错误的 API key 只会更快触发上游的风控。

### 1.4 SDK 已经替你做了一部分，别重复造

OpenAI Python SDK 的 README 明确写了默认重试行为（**已确认**，来源为 `openai/openai-python` 仓库 README）：

> "Certain errors are automatically retried 2 times by default, with a short exponential backoff. Connection errors (for example, due to a network connectivity problem), 408 Request Timeout, 409 Conflict, 429 Rate Limit, and >=500 Internal errors are all retried by default."

还有一条非常关键：

> "Requests are retried only when their body can be safely resent."

以及超时行为："The request timeout is 10 minutes by default."、"Requests that time out are retried twice by default, **unless** the request was streamed."——**流式请求默认不重试**，原因 SDK 也写了：

> "Stream consumption is not automatically retried, because replaying a request could duplicate output already delivered to your application."

这条正好对应本文开头那个"用户看到两遍内容"的场景。**推论（工程经验）**：如果你在 SDK 之上再包一层通用重试中间件，你就把 SDK 这个保护破坏了——SDK 故意不重试流式，你的中间件会重试。**通用重试层必须能识别"已开始向用户投递内容"的请求并跳过它。**

SDK 的错误映射表也值得抄进你的设计文档（**已确认**）：

| HTTP 状态 | 异常类 |
| --- | --- |
| 400 | `BadRequestError` |
| 401 | `AuthenticationError` |
| 403 | `PermissionDeniedError` |
| 404 | `NotFoundError` |
| 422 | `UnprocessableEntityError` |
| 429 | `RateLimitError` |
| >= 500 | `InternalServerError` |
| 无状态码（网络层） | `APIConnectionError` |

全部继承自 `openai.APIError`；`APIStatusError` 上带有 `status_code` 和 `response` 属性。超时单独抛 `APITimeoutError`。

**排查技巧（工程经验）**：失败时一定要记录 `request_id`。SDK 的响应对象有 `_request_id` 属性（来自响应头 `x-request-id`），但失败请求的 request id **只有捕获到 `APIStatusError` 才能拿到**（`exc.request_id`）。这个 id 是向模型厂商提工单时唯一能定位到具体请求的凭据——没有它，客服基本查不了。

### 1.5 幂等方法：为什么 PUT/DELETE 可以重试而 POST 不行

RFC 9110 §9.2.2 对幂等方法的定义：

> "A request method is considered 'idempotent' if the intended effect on the server of multiple identical requests with that method is the same as the effect for a single such request. Of the request methods defined by this specification, PUT, DELETE, and safe request methods are idempotent."

以及最关键的一句：

> "Idempotent methods are distinguished because the request can be repeated automatically if a communication failure occurs before the client is able to read the server's response. For example, if a client sends a PUT request and the underlying connection is closed before any response is received, then the client can establish a new connection and retry the idempotent request. It knows that repeating the request will have the same intended effect, **even if the original request succeeded**, though the response might differ."

反过来，对于非幂等方法，规范给的是明确的禁令：

> "A client SHOULD NOT automatically retry a request with a non-idempotent method unless it has some means to know that the request semantics are actually idempotent, regardless of the method, or some means to detect that the original request was never applied."

以及一条容易被忽略的、专门针对代理的规则：

> "A proxy MUST NOT automatically retry non-idempotent requests. A client SHOULD NOT automatically retry a failed automatic retry."

最后一句值得单独拎出来：**"重试的失败不能再自动重试"**。这正是很多"无限重试链"的规范依据——每一层重试都必须有明确的最大次数上界。

规范还举了两个值得学的例子：

- 一个 UA 可以在**知道该资源上的 POST 是安全的前提下**（通过设计或配置）自动重试 POST。
- 一个专门操作版本控制仓库的客户端，可以在连接失败后**检查目标资源的修订版本**，回滚或修复部分应用的变更，然后自动重试失败的请求。

第二条给了一个重要思路：**幂等性不一定要靠请求头来实现，可以靠"查询状态"来实现**。

同时别误解幂等的边界，规范补充道：

> "the idempotent property only applies to what has been requested by the user; a server is free to log each request separately, retain a revision control history, or implement other non-idempotent side effects for each idempotent request."

即：幂等性是**语义层面**的，不代表服务端不能有副作用。日志、计费、版本历史都不影响幂等判定。

安全方法的定义（§9.2.1）是："Of the request methods defined by this specification, the GET, HEAD, OPTIONS, and TRACE methods are defined to be safe."（safe = 语义上只读）。

### 1.6 落到 LLM 调用上：为什么你的"调用模型"其实是 POST

上面这段规范解释了为什么"能不能重试"不能一概而论。LLM 调用绝大多数是 **POST**（`/v1/chat/completions`、`/v1/responses`），语义上**非幂等**——同样的输入提交两次，服务端可能产生两次计费、两次写入请求日志、两次占用推理容量。

于是有两个层次要分清：

1. **HTTP 层的幂等性**：这次 POST 重复发出去，服务端会不会产生额外的、可观察的业务副作用？（会——至少计费）
2. **业务层的幂等性**：这次"用户提问"这个动作，重复执行是否应该只产生一次效果？（取决于你的系统设计）

**结论（工程经验）**：LLM 调用要实现"可安全重试"，**必须在业务层实现幂等，而不是指望 HTTP 语义**。这就是下一节幂等键的由来。

## 二、幂等键：让"重试同一个请求"和"提交一个新请求"可区分

### 2.1 Stripe 的幂等键设计（可直接借鉴的范式）

Stripe 的幂等文档是这一领域事实上的参考实现（**已确认**，来源 `docs.stripe.com/api/idempotent_requests`）。核心机制：

- 请求头 `Idempotency-Key`；API v1 会在 endpoint 执行开始后**保存首次请求的状态码和响应体**。
- **重试返回已保存的响应，包括 500 错误**。这点很关键：它保证了"重试"和"首次"在客户端看来是同一个结果。
- API v2 的语义更进一步：重试不重复成功的操作；失败或部分失败的工作会重试到完成并返回更新后的响应；若无法成功则返回说明原因的错误。

几条实操约束（**已确认**）：

- 幂等键最长 **255 字符**；建议用 V4 UUID 或足够熵的随机串。
- **不要用敏感数据（邮箱、个人标识）作幂等键**——这既是安全问题，也是隐私问题。
- API v1 中键可在**至少 24 小时**后自动清理；键被清理后复用会生成新请求（**待验证**：具体到你的实现，键的 TTL 是多少？）。
- **幂等层会比较入参与原请求，不一致则报错**——这防止了"同一个 key 配不同 body"的误用。
- API v1 **只在 endpoint 执行开始后保存结果**：参数校验失败或与并发中的请求冲突时**不保存**，所以这两种情况可以安全重试。
- API v1 中**所有 POST 请求都接受幂等键**；GET/DELETE 不要发（它们本身幂等）。

### 2.2 幂等键放在哪一层：三个候选位置

把上面的范式映射到 LLM 应用（**工程经验**）：

| 位置 | 幂等键含义 | 覆盖范围 | 评价 |
| --- | --- | --- | --- |
| 模型 API 调用层 | 这一条 prompt 请求 | 只覆盖模型调用本身 | 覆盖不足：扣配额、落库不在保护范围内 |
| 业务服务接口层（对外） | 用户的这一次"提问"动作 | 覆盖扣配额 + 落库 + 模型调用 | **推荐**：这是用户视角的"一次操作" |
| 前端提交层 | 一次表单提交 | 覆盖所有后续 | 可用但难防"用户双击"以外的重放 |

**推荐做法（工程经验）**：在**业务服务对外接口**上生成幂等键，由它贯穿"扣配额 → 落库 → 调模型 → 回写结果"整条链路。这样任何一个环节超时，重试时整条链路都以同一个 key 重放，服务端在第一道关卡（配额扣减）就识别出"这是重试"，直接返回已有结果。

关键配套：**幂等键必须在"处理请求之前"生成并落盘**。如果你的幂等键是"用 prompt 内容哈希算出来的"，那么用户**两次真正相同的提问**（比如重复问同一句"你好"）会被误判成重试而返回旧结果——这是很常见的 bug。

### 2.3 一个可落地的幂等实现骨架

下面是**伪代码**（**待验证**：具体存储与锁语义需按你的基础设施实现），演示三个关键点：key 生成时机、入参一致性校验、结果缓存。

```python
# 伪代码：幂等请求处理中间件
import hashlib, json, uuid
from dataclasses import dataclass

@dataclass
class IdempotencyRecord:
    key: str
    request_fingerprint: str   # 入参哈希，用于检测 key 复用但参数不同
    state: str                # IN_PROGRESS / DONE
    status_code: int | None
    response_body: bytes | None
    created_at: float


class IdempotencyStore:
    """需要原子性的 put-if-absent 语义（Redis SETNX / DB 唯一索引均可）"""
    def claim(self, key: str, fingerprint: str) -> IdempotencyRecord | None:
        """返回已有记录；None 表示本次抢到了执行权"""
        raise NotImplementedError

    def complete(self, key: str, status_code: int, body: bytes) -> None:
        raise NotImplementedError

    def get(self, key: str) -> IdempotencyRecord | None:
        raise NotImplementedError


def fingerprint(payload: dict) -> str:
    """稳定序列化后哈希，避免 dict 顺序导致的假不一致"""
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def handle(request, store: IdempotencyStore, handler):
    key = request.headers.get("Idempotency-Key")
    if not key:
        key = str(uuid.uuid4())          # 客户端没带就服务端生成
    fp = fingerprint(request.body)

    existing = store.claim(key, fp)
    if existing is not None:
        if existing.request_fingerprint != fp:
            raise IdempotencyKeyReuseError("同一个幂等键配了不同的请求参数")
        if existing.state == "DONE":
            return existing.status_code, existing.response_body   # 直接重放旧响应
        # IN_PROGRESS：另一个执行还在跑
        return poll_or_409(key)

    try:
        status, body = handler(request)
    except Exception:
        store.release(key)      # 执行失败不写缓存，允许客户端重试
        raise
    store.complete(key, status, body)
    return status, body
```

三个设计点值得单独说：

1. **指纹校验**（对应 Stripe 的"比较入参，不一致则报错"）。没有这一步，用户复制了一个旧 key 但改了参数，你会把旧答案返回给他——比报错更糟。
2. **失败不写缓存**。只有成功完成的请求才缓存失败结果。Stripe 的做法是"endpoint 执行开始后保存结果"，但同时保证参数校验失败和并发冲突时不保存——本质是同一个原则：**没有确定结果的请求，不要留下"已完成"的痕迹**。
3. **IN_PROGRESS 状态**。这是流式与长耗时场景必需的：模型生成可能要 30 秒，期间客户端超时重试，如果此时第二个请求直接执行，就会双倍扣费。

### 2.4 幂等键的 TTL 该多长

（**工程经验**，具体值需按业务定）

- **TTL 应大于"客户端最长的重试窗口"**，否则键过期后复用会生成新请求。
- **TTL 应短于"业务上两次相同操作的最短合法间隔"**。如果你的接口允许用户 1 分钟内重发同一个问题，而 TTL 是 30 秒，就会漏判成新请求。
- Stripe 给的 24 小时是一个**参考上界**，不是通用值。

**待验证**：你的业务里"同一请求"的时间窗口是多久？把这个数字和 TTL 一起写进设计文档，而不是随手填个 1 小时。

---

## 三、重试：退避、抖动与重试预算

### 3.1 朴素重试是故障放大器

这是本文最重要的一句话（**工程经验**）：

> **重试在下游正常时是加速器，在下游异常时是放大器。**

一个量级直觉：假设上游过载时错误率是 50%。你的服务收到请求，失败后重试 3 次，那么单次用户请求对上游产生的负载是 `1 + 0.5 + 0.25 + 0.125 ≈ 1.875` 倍。看起来还好。但如果上游错误率是 90%，负载就是 `1 + 0.9 + 0.81 + 0.729 ≈ 3.44` 倍；如果你有 3 层嵌套重试（应用层 → SDK 层 → 网关层），负载会指数叠加。

更糟的情况是**同步重试**：上游过载时，所有客户端在同一时刻重试，形成尖峰，把刚恢复的服务再打死一次。这叫重试风暴（retry storm）。

### 3.2 指数退避 + 抖动

标准的对策是指数退避（exponential backoff）叠加随机抖动（jitter）：

```
delay(attempt) = min(max_delay, base * 2^attempt) * random(0.5, 1.0)
```

- **指数部分**让重试间隔快速拉长，避免在几毫秒内把上游再打三次。
- **抖动部分**（jitter）把重试时刻打散，避免所有客户端同步重试。

**抖动不是可选项**。没有抖动的指数退避，在大规模客户端下等价于同步重试。

常见实现里有三种 jitter 变体（**工程经验**，业界通用做法）：

| 变体 | 公式 | 效果 |
| --- | --- | --- |
| Full jitter | `random(0, min(cap, base * 2^attempt))` | 抹平尖峰最好，推荐 |
| Equal jitter | `half + random(0, half)`，half = `min(cap, base*2^attempt)/2` | 保留一定确定性下限 |
| Decorrelated jitter | `random(base, prev * 3)` | 相邻重试不会太接近，长尾更平滑 |

（**待验证**：不同变体在你自己的流量形态下的差异需要压测，表中结论是业界共识而非本博客实测数据。）

### 3.3 重试预算：Envoy 怎么解决这个问题

Envoy 的熔断文档（**已确认**，来源 `envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking`）给出了一个我认为最值得学的思路——**重试预算（retry budget）**。原文：

> "we recommend using retry budgets; however, if static circuit breaking is preferred it should aggressively circuit break retries. This is so that retries for sporadic failures are allowed, but the overall retry volume cannot explode and cause large scale cascading failure."

它和普通熔断器的区别在于：普通熔断器数的是**请求**，重试预算数的是**重试**，而且预算不是固定值，而是**按当前负载动态计算**的。

Envoy 的 `RetryBudget` proto（**已确认**，来源 `circuit_breaker.proto`）有四个字段：

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `budget_percent` | **20%** | 并发重试数上限 = (当前活跃请求数 + 当前 pending 请求数) × 该百分比 |
| `budget_interval` | **0ms** | 计算预算时考虑请求的时间窗口 |
| `min_retry_concurrency` | **3** | 重试并发数下限，永不低于此值 |
| `max_retries`（普通熔断器） | **3** | 当 `retry_budget` 存在时被覆盖 |

`budget_percent` 的规范示例："if there are 100 active requests and the budget_percent is set to 25, there may be 25 active retries"。

`budget_interval` 的语义值得仔细看：默认为 0ms，意味着只统计**当前**活跃与 pending 的请求。若设为 100ms，则"如果 10 个请求同时开始、budget_interval=100ms，接下来 100ms 内这 10 个请求都被计入预算，不论是否完成"；且**全部在 budget_interval 之后过期**。

这个设计的精髓是：**上游负载越高，允许的重试越少；上游空闲时，重试额度自动放大。** 它天然抑制了重试风暴，因为它把重试量和上游的实时健康度绑定在一起，而不是固定一个数字。

**迁移到 LLM 应用**（**工程经验**）：

```python
# 伪代码：按上游活跃请求数动态计算重试预算
def retry_budget_allowed(active_requests: int, pending_requests: int,
                        budget_percent: float = 0.20,
                        min_concurrency: int = 3) -> bool:
    """语义参考 Envoy RetryBudget；数字需按自己的上游配额压测确定"""
    budget = int((active_requests + pending_requests) * budget_percent)
    budget = max(budget, min_concurrency)   # 永不低于下限
    return current_inflight_retries() < budget
```

需要注意 `min_retry_concurrency` 这个下限的存在：它保证了**即使上游完全空闲、预算算出来是 0，也允许少量重试**。否则小流量场景下会退化成"永不重试"。Envoy 把这个下限设为 3。

Envoy 的五类熔断器及溢出计数（**已确认**）：

| 熔断器 | 溢出计数器 |
| --- | --- |
| Cluster maximum connections | `upstream_cx_overflow` |
| Cluster maximum pending requests | `upstream_rq_pending_overflow` |
| Cluster maximum requests | `upstream_rq_active_overflow` |
| Cluster maximum active retries | `upstream_rq_retry_overflow` |
| Cluster maximum concurrent connection pools | `upstream_cx_pool_overflow` |

另有几个容易忽略的细节（**已确认**）：

- 熔断按 **upstream cluster + priority** 维度配置；worker 线程**共享**熔断额度，实现是最终一致的，线程竞争时**可能超限**。
- 熔断**默认开启**，默认值较保守（例如每 cluster **1024** 条连接）。
- 触发熔断时，Envoy 的 router filter 会设置 **`x-envoy-overloaded`** 响应头——这是一个很好的下游可观测信号。
- 关于连接数的精确语义："even if there are overflowed connections, the selected host is guaranteed at least one connection"；因此 `upstream_cx_active` 的上界实际是 `max_connections + (端点数 × 连接池数)`。

最后一条是很多容量估算会算错的地方：**熔断阈值不等于硬上限**，因为溢出的连接仍会至少为选中的 host 保留一条。

### 3.4 重试次数与超时的配合

重试次数和超时必须一起设计，否则会出现"总耗时不可控"（**工程经验**）：

```
总最坏耗时 ≈ (超时 + 退避延迟) × (最大重试次数 + 1)
```

假设单次超时 30 秒、最多重试 2 次、退避最多 2 秒，那么最坏耗时是 `30 + 2 + 30 + 2 + 30 = 94` 秒。这个数字要小于你的上游网关/负载均衡器的超时，否则**你的重试还没完成，网关已经把连接掐了**——你会看到一堆莫名其妙的 502。

**建议（工程经验）**：把"端到端预算"（用户能接受的最大等待时长）先定下来，比如 60 秒，然后反推单次超时和重试次数：

```
单次超时 = (端到端预算 - 退避总开销) / (最大重试次数 + 1)
```

OpenAI SDK 的默认超时是 **10 分钟**（**已确认**），这个值对大多数 LLM 应用来说过长——一个用户请求挂 10 分钟，在移动端基本等于超时断开。你应该显式设一个更短的超时，比如 60~120 秒（流式场景可以更长，因为 token 是持续吐出来的）。

### 3.5 可重试的判定不能只看状态码

最后一条容易忽略的规则（**已确认**，来自 OpenAI SDK README）：

> "Requests are retried only when their body can be safely resent."

也就是说，**请求体能否安全重发**是一个独立的判断维度。对 LLM 调用来说：

- 非流式的 chat completion：body 是 JSON 字符串，可以安全重发 ✅
- 带文件上传的多模态请求：body 是 multipart 流，可能已经被消费了一部分 ❌
- 流式请求：body 本身可重发，但**响应已经部分投递给了用户** ❌

所以完整的重试判定应该是三个条件的合取：

```python
# 伪代码：是否可重试
def can_retry(exc, request_state) -> bool:
    # 1. 状态码层面可重试
    if not status_is_retryable(exc.status_code):     # 参见 1.3 决策表
        return False
    # 2. 请求体可安全重发
    if not request_state.body_resendable:
        return False
    # 3. 响应未开始向用户投递
    if request_state.stream_started:
        return False
    # 4. 未超过重试预算
    if not retry_budget_allowed(...):
        return False
    return True
```

第 3 条尤其重要。SDK 自己已经做了这层保护（"Stream consumption is not automatically retried"），**你在 SDK 外面加的通用 HTTP 重试中间件会把它破坏掉**。这是很多流式场景重复扣费的根因。

---

## 四、降级：熔断、限流与分层兜底

### 4.1 熔断器：快速失败比排队更好

Envoy 熔断文档开篇的一句话是整章的题眼（**已确认**）：

> "Circuit breaking is a critical component of distributed systems. It's nearly always better to fail quickly and apply back pressure downstream as soon as possible."

**快速失败并把压力反压回下游**，永远优于让请求堆在队列里直到超时。对 LLM 应用而言，"快速失败"的表现形式不是返回一个 500，而是返回一个**有价值的降级结果**。

三态熔断器的经典结构（**工程经验**）：

| 状态 | 含义 | 行为 |
| --- | --- | --- |
| Closed（关闭） | 正常 | 放行全部请求，按窗口统计失败率 |
| Open（打开） | 熔断中 | 立即拒绝（不打到上游），走降级路径 |
| Half-Open（半开） | 试探 | 放行少量探测请求，成功则回 Closed，失败则回 Open |

两个必须做对的参数：

1. **统计窗口**：太短会被正常抖动误触发（5 次失败就熔断，遇到并发尖峰直接挂）；太长则熔断来得太慢（1 分钟窗口，故障已经扩散了）。经验起点是**滑动窗口 + 最小请求数阈值**：窗口内请求数少于 N（比如 20）时不做判定，避免低流量误判。
2. **熔断持续时间**：Open 状态保持多久。Envoy 的做法是"恢复是渐进的"——它没有单一的全开/全关开关，而是用连接池的 gradually 机制慢慢放回容量。工程上常见的近似是：Open 持续 T 秒后进 Half-Open，Half-Open 期间放行 k 个探测请求。

**熔断要按什么维度开？**（**工程经验**）答案通常是**按上游依赖**（哪个模型服务、哪个向量库），而不是按接口。但更细的粒度更好：如果你的应用有"快模型"和"慢模型"两条路径，**只熔断慢的那条**，让流量降级到快模型上，比整体失败好得多。

### 4.2 限流：令牌桶的三个参数

限流是防止单个用户/单个租户把配额吃光的第一道防线。RFC 6585 定义了 429 的语义（**已确认**）：

> "The 429 status code indicates that the user has sent too many requests in a given amount of time ('rate limiting')."

并且特别强调了一个缓存相关的坑：

> "Responses with the 429 status code MUST NOT be stored by a cache."

以及一条安全考量（§7.2）：在被攻击或请求量超大时，**逐个回 429 本身是要消耗资源的**——"it may be more appropriate to just drop connections, or take other steps"。这个观察点在防爬/防刷场景里很有价值：当你已经确定流量是攻击流量时，返回 429 是浪费，直接断连更省。

令牌桶算法（**工程经验**）有三个参数：

| 参数 | 含义 | 调错的症状 |
| --- | --- | --- |
| 容量 `capacity` | 桶里最多能攒多少个令牌 | 太小则突发流量全被拒；太大则单次突发能打穿上游 |
| 填充速率 `rate`（令牌/秒） | 每秒补充多少令牌 | 太小则正常业务被限；太大则起不到保护作用 |
| 消费方式 | 每个请求扣 1 个还是按权重扣 | 不分权重则大请求和小请求代价相同，不合理 |

**关键点（工程经验）**：令牌桶允许**突发**（burst），桶里攒的令牌可以被一次性取走。所以"容量"不是速率的附属品，它单独决定了允许多大的瞬时突发。如果你的上游是 LLM API，突发容量建议按"允许的最大并发请求数"而不是"平均 QPS"来定。

429 的响应体应该带上足够信息，让客户端知道怎么调整（**已确认**的规范要求 + **工程经验**的实践）：

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 30
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1732300000
Content-Type: application/json

{
  "error": {
    "type": "rate_limit_error",
    "message": "并发请求数超过上限（当前 12，上限 10），请在 30 秒后重试"
  }
}
```

注意 `Retry-After` 与自定义 `X-RateLimit-*` 头的分工：`Retry-After` 是**标准语义**，任何 HTTP 客户端库都能理解；`X-RateLimit-*` 是**厂商扩展**，需要客户端自己解析。两者都发，是最省事的做法。

### 4.3 客户端限流 vs 服务端限流

两级限流，缺一不可（**工程经验**）：

| 层级 | 位置 | 防的是 | 实现要点 |
| --- | --- | --- | --- |
| 客户端限流 | 你的服务出站前 | 保护上游配额 | 按租户/用户维度的令牌桶；能排队就排队，别直接拒 |
| 服务端限流 | 你的服务入口 | 保护自己 | 按 API Key / IP 维度；超限返回 429 + `Retry-After` |

**客户端限流的关键设计**（**工程经验**）：它不应该是"拒绝"，而应该是"排队 + 降级"。因为在 LLM 应用里，一个用户请求可能同时触发多次模型调用（多轮对话、工具调用、子代理）。这些调用共享同一个令牌桶，一旦超限，最合理的处置是：

1. 优先**降级**：把这次调用换成小模型 / 缓存结果 / 截断上下文；
2. 其次**排队**：等令牌，但排队等待要有上限（比如 5 秒），超过就降级；
3. 最后才**拒绝**：返回 429。

**排队而非拒绝**是用户体验差异最大的一点。用户在高峰期等 3 秒拿到结果，和立刻看到"繁忙"，是两种完全不同的感受。

### 4.4 降级链：LLM 应用特有的降级层次

这是 LLM 相对传统 Web 服务的一个**优势**：降级路径比传统服务丰富得多（**工程经验**）。

从质量最高到最低，一份典型降级链：

| 层级 | 手段 | 质量损失 | 适用场景 |
| --- | --- | --- | --- |
| L0 | 正常调用目标模型 | 无 | 默认路径 |
| L1 | 换同族小模型 | 中 | 主模型过载、配额耗尽 |
| L2 | 换其他厂商模型 | 中 | 单厂商故障（这是**跨厂商容灾**的核心） |
| L3 | 读缓存（语义缓存 / 固定答案） | 大 | 高频问题、离线兜底 |
| L4 | 裁剪上下文（只保留最近 N 轮） | 中 | 长对话超长导致失败 |
| L5 | 返回预设提示或人工转接 | 大 | 最终兜底 |

几个设计细节：

- **L2 跨厂商降级是抗上游故障最有效的手段**。单一厂商的 503 你是控制不了的，但如果你有第二条供应商链路，就有了真正的容灾。代价是要维护两套 prompt 适配和评测。
- **L3 语义缓存要小心**：缓存命中率在 FAQ 型产品上极高，但命中错误答案的代价也极高。至少要做"缓存答案 + 原始来源"的对照测试。
- **L4 裁剪上下文是最被低估的一层**。很多"请求超时"的根因其实是上下文太长导致首 token 延迟超标。裁剪到最近 N 轮往往就解决了。
- **L5 必须真的存在**。大量应用在最后一步没有兜底，用户看到的是裸 500。返回一句"系统繁忙，请稍后重试"虽然体验一般，但比白屏好得多。

**重要提醒（工程经验）**：降级必须是**显式设计**的，而不是"捕获异常后返回个默认值"。默认的 `except: return None` 式降级，会把上游故障静默转成业务逻辑错误，通常比直接报错更难排查。

---

## 五、流式响应：最容易被重试逻辑破坏的场景

### 5.1 为什么流式不能自动重试

前文已引 SDK 的原文（**已确认**）：

> "Stream consumption is not automatically retried, because replaying a request could duplicate output already delivered to your application."

流式的本质困难在于**响应是一次性的**：一旦开始向用户投递，重放请求会产生第二份内容，而 HTTP 本身没有"从第 N 个 token 继续"的机制。

### 5.2 流式的三种失败点

| 失败点 | 现象 | 处置 |
| --- | --- | --- |
| 建连阶段失败 | 一 个 token 都没收到 | **可以重试**（未投递任何内容） |
| 首 token 前失败 | 收到状态码但还没内容 | **可以重试**（同上） |
| 已经开始投递后中断 | 用户看到半句话 | **不能重试**，需要断点续接或降级 |

判定标准很简单：**一旦有任何内容字节写给了用户，就进入"不可自动重试"状态**。这个状态应该由传输层（写客户端 socket 的那一层）来维护，而不是由业务代码猜测。

### 5.3 断点续接的思路

如果确实需要"接着上次继续"（**工程经验**，各家实现差异大）：

1. **服务端持久化**：为每个流式会话分配一个 id，把已生成的 token 增量写入持久化存储（Redis Stream / KV）。
2. **客户端携带续接点**：重连时带上 `Last-Event-ID`（SSE 规范自带这个头）或自定义的 `resume_from` 序号。
3. **服务端比对**：如果请求参数与原会话一致且存在续接点，则从该位置续发；否则从头发。

这个方案的代价是**服务端要为每个活跃流维护状态**，成本不低。判断是否值得的标准是：**你的流式请求失败率高不高、用户对"半句话"的容忍度低不低**。如果流式失败率低于 0.5%，先把失败率降下来比做续接更划算。

### 5.4 流式的超时设置

流式的超时不能设成"整个响应读完的时间"——那等于没设。正确做法是**分别设置建连超时和首 token 超时**（**工程经验**）：

- 建连超时：TCP + TLS 握手，5~10 秒
- 首 token 超时：从发出请求到收到第一个 token，这是**最关键的指标**，通常 30~60 秒
- token 间超时：两个 token 之间的最大间隔，通常 10~30 秒

SDK 层面给的例子（**已确认**）是 `httpx2.Timeout(60.0, read=5.0, write=10.0, connect=2.0)` 这种分项写法，正好对应上面的拆分思路。

**指标建议**：把"首 token 延迟"（TTFT）作为独立的 SLI 监控，因为它是用户感知的主要延迟来源；端到端总时长反而不是好的 SLI（它随输出长度线性变化）。

---

## 六、可观测性：没有数据就没有调优

### 6.1 必须记录的字段

（**工程经验**，字段选择）

| 字段 | 为什么需要 |
| --- | --- |
| `request_id` | 排障时向模型厂商提工单的唯一凭据 |
| `attempt` | 第几次尝试。没有它就无法分析重试分布 |
| `status_code` / `error_type` | 区分 429 / 5xx / 超时 / 连接错误 |
| `latency_ms` | 端到端延迟 |
| `ttft_ms` | 首 token 延迟（流式） |
| `retry_after_present` | 是否收到 `Retry-After`，收到但没采信是需要排查的问题 |
| `idempotency_key_hit` | 幂等键是否命中已有结果（区分真实请求和重放） |
| `input_tokens` / `output_tokens` | 成本与容量分析 |
| `circuit_state` | 请求被拒时记录熔断器状态 |

### 6.2 关键 SLI 与告警阈值

（**工程经验**，阈值需按自己的基线调整）

| SLI | 定义 | 建议告警阈值 |
| --- | --- | --- |
| 成功率（排除 4xx） | 2xx+3xx / 总请求 | 5 分钟窗口 < 99% |
| 重试放大系数 | 总上游请求数 / 客户端请求数 | > 1.2 说明上游开始不稳；> 2 需立即介入 |
| 熔断触发次数 | 每分钟 `x-envoy-overloaded` 计数 | > 0 就需要看 |
| 429 占比 | 429 / 总请求 | 突增即查配额 |
| 首 token 延迟 P99 | TTFT P99 | 超过 SLO 目标 |
| 幂等命中率 | 命中已有结果 / 幂等请求 | 异常高说明客户端在疯狂重试 |
| 降级触发率 | 走 L1~L5 的请求占比 | 突增即查上游 |

**重试放大系数是最值得盯的一个指标**。它是一个提前量指标：上游还没完全挂，但重试放大系数开始爬升，就说明要出事了。相比之下成功率是滞后指标——它掉下来的时候，故障已经发生了。

### 6.3 日志级别要分级

失败日志的级别设置直接影响告警质量（**工程经验**）：

| 场景 | 级别 | 理由 |
| --- | --- | --- |
| 单次 429 | INFO/DEBUG | 正常限流信号，不是故障 |
| 单次 5xx 且已重试成功 | WARN | 已自愈，但要观察趋势 |
| 重试耗尽最终失败 | ERROR | 需要人看 |
| 熔断打开 | ERROR | 需要人看 |
| 幂等键命中 | INFO | 正常现象 |

**常见错误**：把所有 5xx 都记 ERROR。结果是告警噪声淹没真实问题，值班的人开始忽略告警——这是很多团队告警失效的起点。

---

## 七、端到端检查清单

### 7.1 发布前的门禁

| # | 检查项 | 验收标准 |
| --- | --- | --- |
| 1 | 超时显式设置 | 单次超时 ≤ 60s；流式分项设置 |
| 2 | 重试次数有上界 | 每层 ≤ 2；总链路 ≤ 3（规范："A client SHOULD NOT automatically retry a failed automatic retry"） |
| 3 | 退避带抖动 | full jitter，`base` 与 `cap` 已确定 |
| 4 | 状态码白名单 | 只对 408/429/5xx/连接错误重试；4xx 其余不重试 |
| 5 | 流式请求不进通用重试 | 有独立标记位并被中间件识别 |
| 6 | 幂等键覆盖业务链路 | 业务接口层生成，贯穿扣配额→落库→调模型 |
| 7 | 幂等键指纹校验 | 同 key 不同参数 → 报错而非返回旧结果 |
| 8 | 幂等记录 TTL 已定 | 有明确数值并写入文档 |
| 9 | `Retry-After` 采信逻辑 | 与本地退避取较大值 + 抖动 |
| 10 | 熔断阈值非固定值 | 有基于上游负载的重试预算或等效机制 |
| 11 | 降级链完整 | 至少实现到 L3（缓存或小模型） |
| 12 | 跨厂商降级 | 至少有一条备用模型链路（可选但强烈建议） |
| 13 | request_id 已记录 | 失败路径也记录 |
| 14 | 重试放大系数有监控 | 有指标 + 有告警阈值 |
| 15 | 告警分级 | 单次 429 不告警；重试耗尽才 ERROR |

### 7.2 故障演练建议

设计得再好也要验证（**工程经验**）：

1. **限流演练**：人为把上游限流调低，验证 429 → 退避 → 降级链路通畅。
2. **熔断演练**：注入 5xx 比例，验证熔断打开后快速失败而不是堆积超时。
3. **幂等演练**：在扣配额后强制抛异常，验证重试不会重复扣费。
4. **流式中断演练**：中途断连，验证不会出现重复内容。
5. **重试风暴演练**：模拟上游 90% 错误率，验证重试放大系数有界。

演练要记录**恢复时间**和**用户可见影响**，而不只是"演练成功"。

### 7.3 常见误区速查

| 误区 | 正确做法 |
| --- | --- |
| 所有 5xx 都重试 | 区分 503（过载，退避）与 500（未知，告警） |
| 在 SDK 外再包一层通用重试 | 先读 SDK 的重试策略，避免叠加；尤其要排除流式 |
| 指数退避不带抖动 | 必须加 jitter，否则等于同步重试 |
| 429 立即重试 | 必须退避，优先用 `Retry-After` |
| 用 prompt 哈希当幂等键 | 用随机 UUID/V4，在业务接口层生成 |
| 熔断阈值照抄别人 | 按上游配额和自身并发量算；考虑用重试预算 |
| 依赖 SDK 默认 10 分钟超时 | 显式设置更短的超时 |
| 所有失败都记 ERROR | 分级，避免告警噪声 |
| 降级写成一个 catch-all | 显式的多层降级链，每层单独监控 |
| 只看成功率 | 同时盯重试放大系数这个先行指标 |

---

## 八、小结

把全文压成几句可执行的话：

**关于语义**（已确认，有 RFC 与 SDK 源码支撑）：HTTP 规范已经把重试的前提写清楚了——408/429/5xx 可重试，4xx 其余不可重试；`Retry-After` 是服务端给你的等待指令；幂等方法是规范定义的少数几个（PUT/DELETE/安全方法）；而"自动重试不应自动重试失败的重试"是规范原文。

**关于实现**（工程经验）：LLM 调用是 POST，天然非幂等，所以幂等必须在业务层用幂等键实现，且键要带指纹校验、要有 TTL、失败不能写缓存。

**关于过载**（工程经验 + Envoy 规范佐证）：重试在正常时是加速器、在异常时是放大器；解法是指数退避 + 抖动 + 按上游负载动态计算的重试预算。Envoy 的 `budget_percent`（默认 20%）与 `min_retry_concurrency`（默认 3）给出了具体形态。

**关于降级**：LLM 应用有传统 Web 服务没有的降级空间——小模型、跨厂商、语义缓存、上下文裁剪、预设答案。把它们显式列成链，并且每一层单独监控。

**关于流式**：一旦内容开始投递，就不能自动重试；通用重试中间件必须能识别流式请求；首 token 延迟（TTFT）才是该盯的 SLI。

**关于可观测**：重试放大系数是先行指标，比成功率更早预警。

最后一条元建议：这份清单里每一条都应该在**自己的流量上验证过**。上面标注为"工程经验"的数字（退避的 base/cap、熔断阈值、预算百分比、降级触发率）都是起点，不是答案。

---

## 参考资料

1. [RFC 9110 — HTTP Semantics（STD 97, 2022-06）](https://www.rfc-editor.org/rfc/rfc9110.txt) —— §9.2.1 安全方法、§9.2.2 幂等方法、§10.2.3 Retry-After、§15.5.9 408、§15.5.10 409、§15.6.1 500、§15.6.4 503、§15.6.5 504
2. [RFC 6585 — Additional HTTP Status Codes（429 Too Many Requests, 2012-04）](https://www.rfc-editor.org/rfc/rfc6585.txt) —— 429 语义与缓存约束
3. [Envoy 文档：Circuit Breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking) —— 熔断器分类、溢出计数、重试预算建议
4. [Envoy API：circuit_breaker.proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/circuit_breaker.proto) —— `budget_percent` / `budget_interval` / `min_retry_concurrency` 默认值
5. [OpenAI Python SDK README](https://raw.githubusercontent.com/openai/openai-python/main/README.md) —— 默认重试策略、错误码映射、超时、流式不重试、request id
6. [Stripe Docs：Idempotent requests](https://docs.stripe.com/api/idempotent_requests.md) —— `Idempotency-Key` 语义、键长度与 TTL、入参一致性校验
7. [RFC 7231 — Hypertext Transfer Protocol (HTTP/1.1): Semantics and Content](https://www.rfc-editor.org/rfc/rfc7231.txt) —— 幂等方法与安全方法的原始定义（已被 RFC 9110 取代）
