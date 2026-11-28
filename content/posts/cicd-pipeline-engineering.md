---
title: "CI/CD 流水线工程：可复现构建、缓存与测试分流"
description: "流水线慢、绿灯是假的、今天能过明天不能过。本文从 CI/CD 三个核心属性——可复现性、幂等性与速度——出发，拆解依赖安装缓存、构建产物缓存、测试分流的真实代价模型，讲清矩阵测试、增量测试与变更检测的边界，最后给出流水线设计的工程清单与常见失效模式。"
date: 2026-11-26
categories: ["开发者工具"]
tags: ["CI/CD", "流水线", "缓存", "测试分流"]
---

## 引言：三种最常见的流水线谎言

CI/CD 流水线上有三类看起来正常、实际有害的"谎言"：

**谎言一：绿灯。** PR 上的检查全绿，合并后主分支构建却失败。原因通常是测试环境与 CI 环境不一致，或者流水线依赖了某个只在特定 runner 上存在的状态。

**谎言二：可复现。** 同一个 commit，同一份代码，今天构建出 `sha256:abc...`，明天构建出 `sha256:xyz...`。依赖锁文件写了但没被真正使用，或者构建过程引入了时间戳、随机数、字典序不定的文件遍历。

**谎言三：快。** 流水线跑了 25 分钟，其中 20 分钟是在下载依赖和重装浏览器驱动。开发者为了避开它，把改动攒成大批次提交，反过来拖慢了集成速度——**CI 慢是团队吞吐的直接损失，不是"工具问题"**。

本文不谈具体平台的按钮怎么点，只谈流水线的工程属性：

1. **第一节**：可复现构建——锁定什么、怎么锁、锁不住的怎么办；
2. **第二节**：缓存——两类缓存（依赖 vs 产物）、键的设计、失效的正确边界；
3. **第三节**：测试分流——矩阵 vs 增量 vs 变更检测，各自适用什么；
4. **第四节**：幂等性与重跑——失败重试的正确语义；
5. **第五节**：一条流水线的成本模型与工程清单。

全文区分三类陈述：**已确认**（有官方文档或工具规范直接支撑）、**工程经验**（社区常见做法，随版本与场景变化）、**待验证**（需要你在自己的项目上测）。

## 一、可复现构建：把不确定性钉死

### 1.1 可复现的三个层级

「可复现」在不同层次上有不同的严格程度：

| 层级 | 定义 | 判定方法 |
| --- | --- | --- |
| **依赖可复现** | 同样的源码装出同样的依赖版本 | 两次 `npm ci` 后 `node_modules` 内容一致 |
| **产物可复现** | 同样的源码 + 同样的依赖 → 逐字节相同的产物 | 两次构建产物 sha256 相同 |
| **环境可复现** | 在任何机器上都能构建成功 | 换一台干净的 runner 仍能构建 |

大多数团队卡在第一层和第二层之间：**锁文件写了，但构建过程本身有随机性**。

### 1.2 依赖锁定：锁文件到底锁住了什么

不同生态的锁文件锁定粒度不同：

| 生态 | 锁文件 | 锁定内容 | 陷阱 |
| --- | --- | --- | --- |
| Node.js | `package-lock.json` | 完整依赖树 + 完整性哈希 | 需 `npm ci` 而非 `npm install` |
| Python | `requirements.txt` / `uv.lock` / `poetry.lock` | 直接依赖或完整解析结果 | 仅 `--requirement` 的文件不锁传递依赖 |
| Go | `go.sum` | 模块版本 + 内容哈希 | `go.mod` 的 `replace`/`exclude` 指令可绕过 |
| Rust | `Cargo.lock` | 完整依赖解析 | 库项目通常不提交它 |
| Java | `gradle.lockfile` | 依赖版本 | 需要插件显式启用 |
| Ruby | `Gemfile.lock` | 完整依赖树 | 平台特定依赖需分平台锁定 |

**Node 的关键区分**：`npm install` 会**更新** lock 文件（如果 `package.json` 与 lock 不一致），`npm ci` 则严格按 lock 安装且**在 lock 与 `package.json` 不一致时直接失败**。官方 npm 文档说明 `npm ci` 的用途就是 CI：

> "If you do not use npm ci and use npm install, ... the lock file may be updated, which can cause the build to install different dependencies than expected."

这不只是"慢一点"的问题——它意味着**CI 里安装的依赖可能和你本地测的不是同一批**。

**Python 的陷阱更隐蔽**：一个只写直接依赖的 `requirements.txt`：

```
flask==3.0.0
```

`flask` 的传递依赖（如 `werkzeug`、`jinja2`）版本是浮动的。解析结果会随 PyPI 上游发布而变化。这类项目必须使用会生成完整锁文件的工具（`pip-compile`、`poetry`、`uv`），或用 `pip install --require-hashes` 强制校验。

### 1.3 构建期的随机源

即使依赖完全锁定，构建过程本身仍可能产生不同输出。以下是常见的不确定源：

| 随机源 | 表现 | 消除方法 |
| --- | --- | --- |
| **时间戳** | 产物内嵌构建时间 | `SOURCE_DATE_EPOCH` / 固定值 |
| **随机数** | UUID、随机 ID 生成 | 固定种子 |
| **文件遍历顺序** | 打包顺序不确定，tar 字节不同 | 按名称排序 |
| **绝对路径** | 调试符号含构建机路径 | `-trimpath`（Go）、`-ffile-prefix-map`（GCC/Clang） |
| **压缩元数据** | gzip header 含 mtime | `gzip -n` / `tar --mtime` |
| **并行写入顺序** | 容器镜像层内文件顺序不同 | BuildKit 的确定性排序 |

Go 生态的 `-trimpath` 是一个好范例：它把编译单元的路径从绝对路径映射为模块相对路径，让同一个模块在 `/home/alice/go` 和 `/home/bob/go` 下构建出相同二进制。

### 1.4 校验和与签名：验证一致性

有了可复现构建，才能做「构建一次、多处部署」和「事后验证」：

```bash
# 构建产物哈希
sha256sum target/app-1.2.3-linux-amd64

# 部署后校验
sha256sum -c app-1.2.3-linux-amd64.sha256
```

更强的一层是**供应链证明**（SLSA 框架的思路）：把「构建用了什么源码、什么依赖、什么构建器」记录成一份可验证的 provenance，并与产物一同分发。这样部署方不需要信任构建服务器，只需要验证签名。

### 1.5 基础镜像的不确定性

依赖锁文件只管应用层依赖，基础镜像是另一个独立的漂移源：

```dockerfile
FROM node:20          # ❌ tag 可变
FROM node:20.11.1     # ✅ 版本固定
FROM node:20.11.1@sha256:abc123...  # ✅✅ digest 固定
```

digest 固定最强，但也最易过期（安全补丁要手动更新 digest）。实践上的折中是：**生产镜像用 digest 固定，开发环境用版本 tag**。

## 二、缓存：区分两类，用对键

### 2.1 两类缓存的边界

CI 缓存最容易出问题的地方，是把所有东西都塞进一个缓存里。实际上有两种性质完全不同的缓存：

| 类型 | 内容 | 失效条件 | 存储位置 |
| --- | --- | --- | --- |
| **依赖缓存** | `node_modules/`、`~/.m2/`、pip 缓存、Go module cache | 锁文件变化 | 持久化目录，通常跨分支共享 |
| **产物缓存** | 编译好的二进制、打包好的前端、构建好的容器镜像 | 源码变化 | key 通常含 commit SHA 或分支 |

**误用代价**：把产物缓存当成依赖缓存用，会在源码没变时重新构建（缓存无效）；把依赖缓存按 commit SHA 做 key，会导致每个 commit 都重装一遍依赖（缓存永不复用）。

### 2.2 缓存键的设计

缓存键决定了缓存的复用边界。设计原则：**键要包含所有影响输出的输入，不包含任何不影响输出的东西。**

典型的键构成：

```
依赖缓存键 = hash(锁文件内容, 运行时版本, 操作系统标识)
产物缓存键 = hash(源码内容, 依赖缓存键, 构建脚本, 工具链版本)
```

举例（GitHub Actions）：

```yaml
- name: 恢复依赖缓存
  uses: actions/cache@v4
  with:
    path: ~/.npm
    key: npm-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
    restore-keys: |
      npm-${{ runner.os }}-

- name: 恢复产物缓存
  uses: actions/cache@v4
  with:
    path: dist
    key: dist-${{ runner.os }}-${{ hashFiles('dist/**') }}-${{ github.sha }}
    restore-keys: |
      dist-${{ runner.os }}-
```

**`restore-keys` 的作用是前缀降级匹配**：即使精确键没命中，也尝试用前缀找到「最近的一个」缓存。这在没有锁文件变化的日常开发场景里能显著提升命中率。

### 2.3 缓存的失效陷阱

**陷阱一：缓存键算得太宽。**

```yaml
# ❌ 键里没有源码，所有分支共享同一个缓存
key: build-${{ runner.os }}-${{ github.sha }}
```

如果 `sha` 在键里，每次都是新键，缓存永远写不中。GitHub Actions 的 `cache` action 对同一 key 只写一次（先写者胜），所以同 key 并发时不会冲突，但后写者拿不到自己那份。

**陷阱二：缓存键算得太窄。**

```yaml
# ❌ 每个 commit 都是新键，依赖缓存完全失效
key: npm-${{ hashFiles('**/package-lock.json') }}-${{ github.sha }}
```

依赖缓存的键里带 `sha` 等于没缓存。依赖缓存的键应该只包含锁文件和运行时标识。

**陷阱三：缓存被污染后无法自愈。** 一旦某次构建把错误产物写进了缓存，后续所有命中该缓存的构建都拿到错误产物。防御手段：

- 产物缓存用**精确键**（含 commit SHA），污染只影响该 commit；
- 在缓存恢复后做一次**校验**（比如检查版本号、校验和、schema 版本），不通过就丢弃并重建。

**陷阱四：缓存大小超限被静默丢弃。** GitHub Actions 的仓库缓存有体积上限（免费版 10GB），超出后新的缓存条目会被淘汰而不是报错。所以"缓存时有时无"往往是体积问题。

### 2.4 容器镜像缓存与构建缓存的区别

容器场景有两层缓存，容易混淆：

| 缓存 | 存什么 | 键 | 工具 |
| --- | --- | --- | --- |
| **层缓存** | 镜像的 layer（tar） | 指令链 + 文件内容 | BuildKit `--cache-from/--cache-to` |
| **构建缓存** | 中间步骤的输出快照 | LLB 节点的输入摘要 | BuildKit cache backend |

详见站内《容器镜像与构建优化》一文。

### 2.5 缓存的度量

优化缓存前先测量，否则无法判断改动是否有效。需要跟踪的指标：

| 指标 | 定义 | 目标 |
| --- | --- | --- |
| 依赖安装耗时 | 缓存命中/未命中各多少 | 命中态 < 10s |
| 产物缓存命中率 | 命中次数 / 总次数 | > 70% |
| 总流水线时长 | 从触发到结束 | P50 < 10min |
| 缓存存储占用 | 仓库缓存总量 | 接近上限的 70% |

GitHub Actions 的 API 可以拉到每次 run 的耗时分布：

```bash
gh api "repos/$REPO/actions/runs?per_page=100" \
  --jq '.workflow_runs[] | {created_at, updated_at, conclusion, name}' \
  --jq 'map((.updated_at|fromdateiso8601) - (.created_at|fromdateiso8601)) | add / length'
```

## 三、测试分流：三条互斥的路

### 3.1 三种策略的对比

| 策略 | 机制 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- | --- |
| **矩阵测试** | 同一测试跑在多个环境（OS/版本/架构） | 覆盖广，语义简单 | 成本线性增长 | 跨平台库、SDK |
| **增量测试** | 只跑受改动影响的测试 | 最省时 | 依赖依赖图准确性 | 大型单体、测试套件大 |
| **变更检测** | 只在有相关改动时触发流水线 | 省掉整条流水线 | 漏判会漏测 | monorepo、文档站 |

### 3.2 矩阵测试的成本模型

矩阵的成本是**乘积**：

```
总成本 = 单环境耗时 × 环境数量
```

所以矩阵设计的第一原则是：**只矩阵化真正需要覆盖的维度**。

例：一个库要支持 Node 18/20/22 × Linux/macOS/Windows = 9 个组合。如果每个组合 3 分钟，就是 27 分钟 CI 分钟。这时候需要问：

- macOS 是否只在发布前跑？（→ 分级触发）
- Windows 是否可以用 Windows runner 但只跑核心子集？（→ 按环境分测试子集）
- Node 18 是否只在 release 分支跑？（→ 版本门控）

GitHub Actions 的 `strategy.matrix` 支持 `include`/`exclude`：

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        node: [18, 20, 22]
        os: [ubuntu-latest, windows-latest]
        include:
          - { node: 22, os: macos-latest, full: true }
        exclude:
          - { node: 18, os: macos-latest }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
      - run: npm ci
      - run: npm test
```

`fail-fast: false` 让所有组合都跑完再汇总失败，这样一次 CI 就能看到全部失败项，而不是修一个跑一次。

**注意 `include` 带来的隐式行为**：GitHub Actions 的 `matrix.include` 里未被 `exclude` 排除的项，会**扩展**矩阵而不是覆盖。也就是说 `include` 一个 `{node: 22, os: macos-latest, full: true}` 会新增一个组合（因为它与已有的 `node: 22, os: ubuntu-latest` 不完全匹配），而不是修改现有项。要覆盖现有组合，必须让 include 的键与原矩阵完全一致。

### 3.3 增量测试的依赖图

增量测试的核心是维护一张 **测试 → 源码文件** 的依赖图。主流实现：

| 工具 | 生态 | 机制 |
| --- | --- | --- |
| Bazel | 多语言 | 静态依赖图 + 沙盒 |
| Gradle | JVM | 任务图 + 输入输出声明 |
| nx | JS/TS monorepo | 项目图 + `affected` 命令 |
| Turborepo | JS/TS | 任务图 + 哈希缓存 |
| pytest `--lf` | Python | 上次失败的优先 |

Bazel 的思路最彻底：**构建系统本身就知道依赖关系**。每个 `test` 目标声明它依赖哪些源文件，缓存键 = 依赖内容的哈希。改了 `a.ts` 只有依赖 `a.ts` 的测试目标失效。

**代价**：Bazel 要求项目用它的规则描述构建，迁移成本高。对已经在用 Gradle/Maven 的项目，用「测试类/文件 → 源码目录」这种粗粒度映射也能拿到大部分收益。

### 3.4 变更检测（monorepo）

monorepo 的核心矛盾：**几十个包共用一条流水线，每次改动都要全量构建**。

变更检测的思路：在流水线开始时先算「哪些包受本次改动影响」，只跑相关包的测试。典型实现是 `paths` 过滤或 `nx affected`：

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # 需要完整历史才能算 diff

- run: npx nx affected --target=test --base=origin/main
```

**关键坑：`fetch-depth` 默认是 1（浅克隆）**，无法计算与 `main` 的差异。必须显式 `fetch-depth: 0` 或至少足够深。

**更激进的策略是按路径直接跳过整个流水线**：

```yaml
on:
  pull_request:
    paths-ignore:
      - '**/*.md'
      - 'docs/**'
```

但要**谨慎**：文档改动有时会影响构建（比如 README 被嵌入到产物里、文档站的 API 参考由代码生成）。误跳过会导致"改了没生效"的困惑。稳妥做法是保留一个轻量 job（lint + build 校验），而不是完全跳过。

### 3.5 测试分流的代价

分流不是免费的。每个分层策略都引入状态：

- **矩阵**：需要维护组合列表，组合爆炸风险；
- **增量**：依赖图不准确 = 漏测，需要保守策略（不确定时回退到全量）；
- **变更检测**：路径规则与实际依赖脱节时静默漏测。

**漏测比慢更危险**。所以设计上应该有一条「全量验证」通道：合并到主分支或打 tag 时，跑一次全量测试，作为发布前的最后闸门。

## 四、幂等性与重跑

### 4.1 幂等性的含义

CI 的幂等性指：**同一次构建重复执行，结果相同**。不幂等的典型表现：

- 每次构建产物哈希不同（不幂等的构建）；
- 重跑一次成功、一次失败（依赖外部状态）；
- 重跑后数据库里多了一行记录（测试没有回滚）。

### 4.2 破坏幂等的常见来源

| 来源 | 表现 | 修复 |
| --- | --- | --- |
| 外部可变输入 | 依赖了 `main` 分支最新代码 | 锁定 base SHA |
| 墙上时钟 | 产物含当前时间 | 固定时间戳 |
| 网络依赖 | 下载的依赖版本漂移 | 锁版本 + 校验和 |
| 并行写同一目录 | 结果不确定 | 隔离目录 |
| 未清理的环境 | 第二次跑继承了上次的产物 | 每次全新 workspace |

其中**"依赖了 main 分支最新代码"** 是最隐蔽的一种：如果流水线写的是 `git checkout main` 而不是 `git checkout ${{ github.event.pull_request.base.sha }}`，那么 base 分支在流水线运行期间被别人推进，构建结果就不可复现。

### 4.3 重试的正确语义

「失败就重试」是常见的错误实践。它掩盖真实问题，并且让流水线耗时不可预测。正确的做法是**区分失败类型**：

| 失败类型 | 是否重试 | 例子 |
| --- | --- | --- |
| 确定性失败 | ❌ 不重试 | 断言失败、编译错误、lint 失败 |
| 瞬时基础设施失败 | ✅ 重试 | 网络抖动、registry 超时、runner 抢占 |
| 已知 flaky | ✅ 重试但标记 | 需隔离到 quarantine 的用例 |

区分的第一手段是**看重试是否成功**：如果重试成功，它大概率是 flaky 或基础设施问题；如果重试仍失败，多半是确定性失败。这是最实用的分类依据——所以重试次数本身应该被记录下来。

自动重试的配置应该限制在**基础设施层**：

```yaml
- name: 拉取依赖
  run: npm ci
  # 由 action 自身处理网络重试，而不是包一层 retry 循环
```

在 `RUN` 里包一层 shell 重试循环（`until npm ci; do sleep 5; done`）会把「永久失败」变成「永远挂着」，直到作业超时——**超时比失败贵得多**，因为超时占用的 runner 时间是失败的好几倍。

### 4.4 超时

每个作业都应该设置超时。GitHub Actions 的 `timeout-minutes`：

```yaml
jobs:
  test:
    timeout-minutes: 15
```

没有超时的作业可能挂到平台默认上限（GitHub Actions 默认 360 分钟），在自建 runner 上则可能一直占用资源。

## 五、成本模型与工程清单

### 5.1 一次流水线的成本分解

把 25 分钟的流水线拆开：

```
总耗时 = 排队等待 + 环境准备 + 依赖安装 + 构建 + 测试 + 上传产物
         (不可控)      (可控)      (可缓存)   (可缓存)  (可分流)  (可缓存)
```

优化优先级应该按**可控性 × 收益**排序：

1. 依赖安装（可缓存，收益最大）；
2. 测试分流（可分流，收益次之）；
3. 环境准备（可用预置镜像或固定镜像消掉）；
4. 构建（可用缓存）；
5. 排队等待（通常不可控，但可以用 runner 分组缓解）。

### 5.2 环境准备的消除

一个常被忽略的耗时来源：每个 job 都要重新装一遍工具链（Node、Python、浏览器、Playwright 驱动）。

消除方式：

| 方式 | 做法 | 适用 |
| --- | --- | --- |
| 固定工具版本 | `actions/setup-node` 显式指定版本 | 所有项目 |
| 容器化 job | `container:` 指定镜像 | 依赖系统包的项目 |
| 预置缓存 | 缓存 `~/.cache/ms-playwright` 等 | 前端 E2E |
| 自建 runner 镜像 | 预装所有工具 | 自建 CI |

**E2E 测试的浏览器驱动尤其值得缓存**：Playwright 的浏览器二进制有几百 MB，每次 CI 重新下载是纯浪费。

### 5.3 流水线定义检查清单

| 检查项 | 判定 | 价值 |
| --- | --- | --- |
| 锁文件被提交 | `git ls-files '*lock*'` 有输出 | 依赖可复现 |
| CI 用 `npm ci` 而非 `npm install` | grep CI 配置 | 避免隐式升级 |
| 基础镜像用版本 tag 或 digest | grep Dockerfile | 基础层稳定 |
| 依赖缓存键不含 commit SHA | 检查 cache 配置 | 缓存真正命中 |
| 产物缓存键含 commit SHA | 检查 cache 配置 | 防止污染扩散 |
| 恢复缓存后有校验 | 检查 build 步骤 | 污染可自愈 |
| 每个 job 有 timeout | 检查 CI 配置 | 防止挂死 |
| 有全量测试通道 | 检查触发条件 | 防止漏测 |
| PR 与 main 的 base 固定 | 检查 checkout 步骤 | 构建可复现 |
| 缓存体积在限额内 | 查看仓库缓存用量 | 命中率稳定 |

### 5.4 分层流水线模板

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      affected: ${{ steps.filter.outputs.affected }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: filter
        run: |
          if [ "${{ github.event_name }}" = "push" ]; then
            echo "affected=true" >> $GITHUB_OUTPUT
          else
            echo "affected=$(npx nx print-affected --base=origin/main --select=projects)" >> $GITHUB_OUTPUT
          fi

  test:
    needs: changes
    if: needs.changes.outputs.affected != 'false'
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        node: [20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
          cache: npm          # 内置的 npm 缓存，键基于锁文件
      - run: npm ci
      - run: npm test

  full-test:
    if: github.ref == 'refs/heads/main'
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npm run test:all
```

要点：

- `concurrency` + `cancel-in-progress: true`：同一个 PR 的新 push 自动取消旧流水线，这是最直接的提速手段（很多团队忘了配）；
- `changes` job 输出 affected 列表，`test` 按需跑；
- `full-test` 只在 main 上跑，作为发布前的全量闸门；
- `fail-fast: false` 保证一次看到全部失败。

### 5.5 什么时候不要继续优化流水线

同镜像优化一样，流水线优化也有边际收益递减：

- **流水线 P50 已 < 5 分钟**：开发者不会因此攒提交，不需要再优化；
- **测试套件本身只有 50 个用例**：分流机制比测试本身还复杂；
- **团队只有 2 个人**：维护矩阵和缓存的收益低于成本。

**流水线的目标是缩短反馈循环，不是把 YAML 写得复杂。**

## 小结

1. **可复现有三个层级**：依赖可复现、产物可复现、环境可复现。锁文件只解决第一层；时间戳、随机数、绝对路径、文件顺序是第二层的常见障碍。
2. **锁文件的锁定粒度因生态而异**。Node 必须 `npm ci`；Python 只写直接依赖是不够的，要用能生成完整锁文件的工具。
3. **依赖缓存和产物缓存性质不同**。依赖缓存的键基于锁文件，产物缓存的键基于源码/commit SHA。混用会导致缓存永不命中或污染扩散。
4. **缓存键的黄金法则**：包含所有影响输出的输入，不包含任何不影响输出的东西。`restore-keys` 提供前缀降级，能提升命中率。
5. **测试分流有三条路**：矩阵（覆盖广、成本线性）、增量（最省时、依赖图要准）、变更检测（monorepo 必备、漏判会漏测）。**漏测比慢更危险**，所以必须保留全量通道。
6. **幂等性是流水线的核心属性**。锁定 base SHA、固定时间戳、隔离并行目录，是三个最有效的做法。
7. **重试要区分失败类型**。确定性失败不重试；重试本身是 flaky 分类的实用手段。绝不用 shell 重试循环把永久失败变成超时。
8. **超时是必须设置的**。超时的代价远高于失败。

## 参考资料

- GitHub Actions 官方文档：`actions/cache`、`actions/setup-node`、matrix 策略、`concurrency`
- npm 官方文档 `npm ci` 与 lock 文件语义
- Bazel 官方文档：增量构建与 action graph
- Nx 官方文档：`affected` 与项目图
- SLSA 规范：软件供应链 provenance 等级
