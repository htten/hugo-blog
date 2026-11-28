---
title: "容器镜像与构建优化：分层缓存、多阶段与 BuildKit"
description: "镜像构建慢、CI 跑得久、缓存永远不命中。本文从 OCI 镜像的分层与白障文件机制讲起，解释为什么 COPY 顺序决定了缓存命中率，再讲多阶段构建如何把编译产物与运行时分离，最后深入 BuildKit 的缓存键推导、LLB 图、并发控制与远程缓存，给出一套可落地的构建提速清单与常见反模式。"
date: 2026-11-25
categories: ["开发者工具"]
tags: ["容器", "镜像构建", "Docker", "BuildKit"]
---

## 引言：构建慢不是玄学，是缓存键算错了

容器镜像构建的痛点非常具体：

- 本地 30 秒的构建，CI 上要 5 分钟；
- 改了 3 行代码，CI 重新下载了 2GB 依赖；
- `docker build --cache-from` 传了参数，命中率始终是 0；
- 镜像 1.8GB，推到 registry 要 4 分钟，节点拉取还要 1 分半；
- 明明代码没变，每次构建产物却总是不同，缓存被整体作废。

这些现象大多可以归结为一句话：**缓存是否命中，取决于缓存键（cache key）算出来是否相同**。而缓存键是由 Dockerfile 里一连串指令的输入决定的，跟「你这次改了哪个文件」没有直接关系——它取决于**指令顺序**。

本文按这个逻辑展开：

1. **第一层**：OCI 镜像到底存了什么（layer / diff / manifest），为什么层是不可变且可复用的；
2. **第二层**：Dockerfile 的每条指令如何生成缓存键，为什么 `COPY . .` 放在前面会毁掉一切；
3. **第三层**：多阶段构建怎么用「丢弃前一阶段」换来小镜像；
4. **第四层**：BuildKit 把上面这些变成了什么（LLB 有向无环图、真正的并行、内容寻址的缓存键、gRPC 导出/导入缓存）；
5. **第五层**：一份工程清单——怎么测、怎么调、怎么排。

全文区分三类陈述：**已确认**（有 Docker/BuildKit 官方文档直接支撑）、**工程经验**（社区常见做法，随版本与场景变化）、**待验证**（需要你在自己的环境上测）。事实依据以 Docker 官方文档（Dockerfile reference、BuildKit 文档、OCI image-spec）为准。

## 一、OCI 镜像的真实数据结构

### 1.1 从 manifest 开始

一个现代 OCI 镜像由三部分组成：

```
manifest.json  →  指向 config + 一组 layer descriptor
config (JSON)  →  镜像配置：环境变量、ENTRYPOINT、Cmd、历史记录
layer (tar)    →  文件系统变更集（diff）
```

官方 `image-spec(1)` 把 layer 定义为 "filesystem changes"，也就是**文件系统变更集**而不是完整文件系统快照。

镜像的规范文件名是 `<algorithm>:<hex>`，其中 `<algorithm>` 是内容摘要算法的名称，`hex` 是该算法针对清单内容计算出的摘要。默认的 `sha256` 表示用 SHA-256 计算摘要。

这里有一个至关重要的推论：

> **推论：镜像 ID = manifest 内容的摘要。manifest 里包含每个 layer 的 digest，而 layer 的 digest 又是该层 tar 字节流的摘要。**

于是形成一条完整的哈希链：

```
layer1.tar  --sha256-->  digest1
layer2.tar  --sha256-->  digest2
config.json --sha256-->  configDigest
manifest.json 里写入 digest1, digest2, configDigest
manifest.json --sha256-->  imageID
```

这个链条解释了大量现象：

- **只要任意一层的字节变了，它的 digest 就变**，它之上所有 layer 的 digest 都会变（因为 manifest 内容变了）；
- **层的顺序有意义**，把 layer 顺序调换会得到完全不同的 image ID，即使总字节数一样；
- **「镜像 tag 相同不等于内容相同」**：tag 只是 manifest 的一个可变的指针，`myapp:latest` 随时可能指向不同 digest。

### 1.2 layer 是 diff，不是快照

每一层存的是「相对于上一层的文件系统变更」。这个语义带来两个直接后果。

**后果一：删除文件要额外一层。** 官方文档在讲 `RUN rm` 与 `.dockerignore` 时特别强调：文件在后续层被删除，最终镜像里确实看不到它，但**删除操作本身会占用空间**，因为那一层的 tar 里记录了 `whiteout` 条目。

这解释了一个常见困惑：

```dockerfile
# ❌ 这层里的 800MB 依赖依然留在镜像中
FROM python:3.12
RUN pip install --no-cache-dir torch
RUN rm -rf /usr/local/lib/python3.12/site-packages/torch
```

`rm` 只是新增一层 whiteout，torch 的字节还在第一层里。正确做法见第三章的多阶段构建。

**后果二：层数决定解压开销。** 每个 layer 都需要单独解压到 overlayfs 的 upperdir。层数多、解压总量大，容器启动就慢。这是 `docker history` 值得经常看的原因。

### 1.3 whiteout 文件机制

OverlayFS 用 `.wh.` 前缀表示「这个路径在低层存在，但被本层遮住」：

| 文件名 | 语义 |
| --- | --- |
| `.wh.<name>` | `<name>` 在低层存在，本层删除 |
| `.wh..wh..opq` | 本层开始处，该目录在低层的所有内容都被遮住（opaque 目录） |

Opaque 目录是 `COPY` 覆盖整个目录时的常见产物：

```dockerfile
FROM alpine:3.20
COPY ./src/ /app/
```

如果 `/app/` 在低层已存在，这次 COPY 会生成一个 opaque 目录，把低层 `/app/` 的全部内容遮住。低层那些字节**仍然占用镜像体积**，只是运行时看不见。

### 1.4 镜像大小与拉取速度

拉取镜像时，registry 不会逐层下载，它会检查本地已有层，只下载缺失的。但即使如此，第一次拉取 1.8GB 镜像的耗时是真实的网络成本。

这里有一个容易混淆的点：**「镜像大小」和「下载量」不是一回事**。如果两个镜像共享基底层，第二个镜像的增量下载会小很多。这正是为什么要用 `FROM alpine` 而不是一个完整发行版，以及为什么多阶段构建能把最终镜像从 1.8GB 降到 50MB。

## 二、缓存键：Dockerfile 每条指令的输入输出

### 2.1 官方定义的缓存规则

Docker 官方 Dockerfile reference 明确写道：

> "The cache for each RUN, COPY, ADD, etc. instruction is determined by:
> - the command the instruction runs
> - the file or folder the instruction is adding to the container
> - the contents of files the instruction is adding to the container
> - the combination of the file metadata (mtime, ownership, ...) of files the instruction is adding to the container"

对 `COPY` / `ADD`，官方文档用了一个更简洁的说法："For the ADD and COPY instructions, the cache check is performed against the file checksums, not mtime."

**关键点：文件内容（checksum），不是 mtime。** 这是一个好消息——CI 里 git checkout 会重置 mtime，但内容没变，缓存依然能命中。

### 2.2 缓存链：为什么顺序决定一切

Docker 的缓存是**链式**的。对于一个 Dockerfile：

```dockerfile
FROM node:20          # 步骤 0
COPY package.json .   # 步骤 1
RUN npm install       # 步骤 2
COPY . .              # 步骤 3
RUN npm run build     # 步骤 4
```

每一层的缓存键不是只由本步骤的输入决定，而是**「所有父步骤的缓存键」+「本步骤的输入」**。可以理解为一个递推：

```
key(0) = hash(基础镜像 manifest)
key(1) = hash(key(0), package.json 内容)
key(2) = hash(key(1), 命令文本)
key(3) = hash(key(2), 整个源码目录内容)   ← 这一步把前面全部"毒化"了
key(4) = hash(key(3), 命令文本)
```

于是：**步骤 3 的 `COPY . .` 复制了整个源码目录，包括 `src/`、`README.md`、`.git/`。这些文件里任何一个字节变了，步骤 3 的缓存键就变了，步骤 4 的父键也变了，`npm run build` 必然重跑。**

而步骤 2 的 `npm install` 其实**不需要重跑**（依赖没变），但它的缓存键虽然是 `hash(key(1), 命令文本)`，其**输出层**却会因为下游重建而被丢弃——Docker 的层是不可变的，一旦下游失效，上游的层仍可复用，但必须重新执行步骤 2 来**重新生成**那个层（除非 BuildKit 做了更细粒度的处理，见第四章）。

这就是「缓存明明命中了但构建还是慢」的原因：命中的是上游，重跑的是下游。

### 2.3 依赖缓存的标准解法

把「变化频率低的依赖」和「变化频率高的源码」分离：

```dockerfile
# ✅ 推荐：依赖先装，源码后拷
FROM node:20-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
```

这样源码变化只影响 `COPY . .` 及其之后的步骤，`npm ci` 依旧命中缓存。

**更好的做法：用 lock 文件 + 专门的依赖缓存。** `npm ci` 相比 `npm install` 严格按 lock 文件安装，行为可复现，这是官方推荐用于 CI 的方式。

### 2.4 .dockerignore：构建上下文的第一道门

`.dockerignore` 控制哪些文件进入构建上下文。它和缓存键计算是**两件相关但不同的事**：

- 缓存键：只算实际被 `COPY`/`ADD` 指令引用的文件的 checksum；
- 构建上下文：发给 daemon 的整个目录包，影响传输时间和 `.dockerignore` 的过滤效果。

一个典型的 `.dockerignore`：

```
.git
node_modules
dist
build
target
*.log
.env
.env.*
!.env.example
Dockerfile
.dockerignore
```

**注意 `.dockerignore` 排除 `Dockerfile` 本身的影响。** 官方文档说明：把 `Dockerfile` 和 `.dockerignore` 从上下文中移除是一种优化做法，因为它们不会改变构建结果；但如果 Dockerfile 里用了 `COPY Dockerfile .` 就会失败。

### 2.5 缓存失效的常见原因清单

按发生频率排序：

| 原因 | 判定方法 | 修复 |
| --- | --- | --- |
| `COPY . .` 位置太靠前 | 读 Dockerfile，对比每步缓存键来源 | 把依赖拷贝提前 |
| `.dockerignore` 缺失 | 构建上下文大小异常大 | 补 `.dockerignore` |
| 构建产物被 `COPY` 进上下文 | `docker build` 输出 transfer context 很大 | 排除 `dist/`、`node_modules/` |
| 基础镜像用了 `latest` | `docker history` 里 base 层哈希不稳定 | 固定 digest |
| `ARG` 变化导致下游全废 | 对比两次构建的 `RUN` 层 | 减少 `ARG` 使用范围 |
| 时间戳/随机值写进构建产物 | 层 hash 每次都变 | 用 `SOURCE_DATE_EPOCH` 归一化 |

### 2.6 归一化时间戳：可复现构建

Go 生态的 `SOURCE_DATE_EPOCH` 约定被广泛采用，官方 Dockerfile reference 在讨论可复现构建时提到它。典型用法：

```dockerfile
# syntax=docker/dockerfile:1
ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
```

构建时传入：

```bash
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) docker build \
  --build-arg SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) -t myapp .
```

效果是编译产物里的时间戳被固定，从而让「相同源码 + 相同依赖」产出**逐字节相同**的镜像层。这是镜像签名、SBOM 校验、灰度比对的基础。

## 三、多阶段构建：用丢弃换体积

### 3.1 多阶段的核心语义

`FROM X AS stage` 定义一个构建阶段。一个阶段的所有指令都会真正执行（产生中间层），但**只有最后一个阶段的产物会进入最终镜像**。前面阶段的层在最终镜像里完全不存在。

官方 Dockerfile reference：

> "Each stage in a multi-stage build begins with a FROM instruction, and can use any of the instructions available in the Dockerfile. ... Only the final stage is used in the resulting image; the rest are discarded."

「discarded」是字面意思——中间层不是被标记删除，而是**根本不会被组装进最终镜像**。所以多阶段构建同时解决两个问题：

1. **镜像体积**：编译工具链、devDependencies、源码全都不进最终镜像；
2. **攻击面**：最终镜像里没有 `gcc`、没有 shell 密码文件、没有源码。

### 3.2 经典四段式

```dockerfile
# syntax=docker/dockerfile:1

# ---------- 阶段 1：依赖 ----------
FROM node:20-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# ---------- 阶段 2：构建 ----------
FROM node:20-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build && npm prune --omit=dev

# ---------- 阶段 3：测试 ----------
FROM build AS test
RUN npm run test:unit

# ---------- 阶段 4：运行时 ----------
FROM node:20-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

要点：

- **`COPY --from=deps`** 从另一个阶段拷贝，而不是重新执行 `npm ci`——避免了重复下载；
- **测试阶段挂在 `build` 之上**，失败会中断整个构建，且不污染最终镜像；
- **运行时阶段用 `USER node`**（Node 官方镜像自带的非 root 用户），而不是 root；
- **`npm prune --omit=dev`** 在构建阶段就削掉 devDependencies，避免把 dev 依赖拷进运行时。

### 3.3 跨阶段复制文件的三种来源

`COPY --from` 的来源可以是：

| 来源 | 语法 | 用途 |
| --- | --- | --- |
| 命名阶段 | `--from=build` | 最常用 |
| 外部镜像 | `--from=nginx:latest` | 拷贝别人的成品 |
| 上下文（BuildKit） | `--from=/path/in/context` | 从构建上下文取文件 |

另外 `COPY --from` 也可以指向 **stage 上下文之外的 build stage 名称**，但要注意：当从外部镜像复制时，构建会额外拉取那个镜像。

### 3.4 什么时候不需要多阶段

多阶段不是免费的，它有两个成本：

1. **构建时间可能变长**：因为依赖在阶段间被拷贝，而不是复用同一层的文件系统；
2. **调试变难**：最终镜像里没有工具链，`docker run` 进去无法排查。

对纯脚本类镜像（一个 Python 文件 + 依赖），用单阶段 + 精简基础镜像往往更简单：

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
CMD ["python", "app.py"]
```

判断标准：**如果构建工具链显著大于产物，就用多阶段**（Go、Rust、Java、Node 构建）；**如果工具链本身就轻，收益有限**。

### 3.5 常见反模式

| 反模式 | 问题 | 修复 |
| --- | --- | --- |
| 单阶段装完编译再删 | 删除只加 whiteout，字节还在 | 多阶段 |
| `FROM python:latest` | 基础层不稳定，缓存失效 | 固定 `python:3.12.4-slim` 或 digest |
| `apt-get install` 后 `rm -rf /var/lib/apt/lists/*` 在同一层 | 有效（同一层内删除），但分两层就废 | 合并到一条 `RUN` |
| `ADD` 用于下载远程 URL | `ADD` 会解压 tar，但远程下载不可控 | 用 `RUN curl` + 校验和 |
| `COPY . .` 在最前面 | 源码变化废掉依赖层 | 依赖先走 |
| 以 root 运行 | 安全风险 | `USER` + 只读根文件系统 |

关于 `ADD` 与 `COPY` 的区别，官方文档说得很明确：`ADD` 支持本地 tar 自动解包和远程 URL 下载，`COPY` 不支持。**在需要下载的场景，优先 `RUN` + 显式校验和**，因为 `ADD` 不会校验下载内容的完整性。

## 四、BuildKit：把上面这些变成图

### 4.1 LLB：构建是一个有向无环图

BuildKit 的核心抽象是 **LLB（Low-Level Build）**——一个描述构建步骤的中间表示。每个步骤声明自己的**输入（deps）**和**输出（outputs）**，构建引擎据此形成 DAG。

官方 BuildKit 文档这样描述：

> "BuildKit is a ... container build engine ... It supports ... a DAG-based frontend..."

这带来三个直接后果：

1. **真正的并行**：没有任何依赖关系的两个步骤可以同时跑。传统 builder 只能串行执行 Dockerfile 里的每条 `RUN`；
2. **更好的缓存复用**：DAG 允许引擎在下游失效时，判断上游节点能否直接复用已有结果，而不是简单地级联失效；
3. **步骤之间不共享文件系统**：两个平行阶段不能"看到"彼此的修改，除非通过 `COPY --from` 显式传递。

第 3 点很重要，也是新手最容易困惑的地方：

```dockerfile
FROM alpine AS a
RUN echo hello > /tmp/f

FROM alpine AS b
RUN cat /tmp/f    # ❌ 找不到，a 和 b 是平行的
```

要传递必须显式：

```dockerfile
FROM alpine AS c
COPY --from=a /tmp/f /tmp/f
```

### 4.2 缓存键的真正来源：指令 + 依赖

BuildKit 的缓存键推导基于 LLB 节点的输入。对 `RUN` 节点：

```
cacheKey = hash(命令文本, 挂载的缓存, 输入快照的 digest, 输出元数据)
```

对 `COPY` 节点：

```
cacheKey = hash(源文件列表及其 digest, 权限, 目标路径)
```

**BuildKit 的关键改进是它缓存的是「步骤的输出结果」而非「层链」**。官方文档提到 BuildKit 支持 "cache mounts" 和更细粒度的缓存失效。

### 4.3 缓存挂载：把依赖装到层外

这是 BuildKit 最被低估的能力。`RUN --mount=type=cache` 把一个持久化目录挂进构建步骤，**该目录的内容不进入镜像层**：

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefer-offline

COPY . .
RUN npm run build
```

效果：

- `npm ci` 依然要执行（因为命令本身变了），但 npm 缓存目录 `/root/.npm` 被复用，**依赖从网络下载变成从本地缓存解压**；
- 缓存目录**不进入最终镜像**，镜像里不会残留几百 MB 的 tarball；
- 缓存可以跨构建复用（BuildKit 的本地 cache 或远程 registry 缓存）。

常用 mount target：

| target | 用途 |
| --- | --- |
| `/root/.npm` | npm 缓存 |
| `/root/.cache/pip` | pip 缓存 |
| `/root/.m2` | Maven 本地仓库 |
| `/root/.gradle` | Gradle 缓存 |
| `/go/pkg/mod` | Go module 缓存 |
| `~/.cargo/registry` | Cargo 缓存 |

### 4.4 secret 与 ssh mount：不要把密钥烤进镜像

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm ci

RUN --mount=type=ssh \
    git fetch --depth 1 git@github.com:org/private-repo
```

BuildKit 的 secret mount 让敏感内容在构建时以临时文件形式挂载，**只存在于该步骤的执行环境**，不出现在层历史、镜像配置和最终产物里。

官方文档强调这一点：mount 的内容「不会被打包进镜像」。

对比一下传统做法的问题：

```dockerfile
# ❌ 危险：ARG 会被历史记录下来
ARG NPM_TOKEN
RUN npm ci --registry=https://${NPM_TOKEN}@registry.npmjs.org/
```

`ARG` 的值可以通过 `docker history` 或镜像 config 看到，即使后面 `RUN rm` 也一样。官方文档明确警告不要用 `ARG` 传递 secret。

### 4.5 远程缓存：BuildKit 的 cache export/import

BuildKit 支持把构建缓存导出为外部制品：

```bash
# 导出到本地 registry
docker buildx build \
  --cache-to type=registry,ref=myregistry.com/myapp:buildcache \
  --cache-from type=registry,ref=myregistry.com/myapp:buildcache \
  -t myregistry.com/myapp:tag \
  --push .
```

官方文档列出的 cache backend 类型：

| type | 用途 | 说明 |
| --- | --- | --- |
| `registry` | 推送到 registry | 最通用，支持并发写入 |
| `gha` | GitHub Actions 缓存 | 需 `ACTIONS_CACHE_URL`/`ACTIONS_RUNTIME_TOKEN` |
| `local` | 本地目录 | 需要 `destructive` 才能真正复用 |
| `s3` / `azblob` / `gcs` | 对象存储 | 适合自建 CI |

**用 `gha` 的官方 GitHub Actions 示例**（取自 BuildKit 官方文档）：

```yaml
name: build
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ github.repository }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

注意 `mode=max`：**默认的 `min` 模式只导出最终镜像的层，`max` 模式导出所有中间层**。只用默认模式时，中间层缓存不会被保存，下次构建拿不到 `npm ci` 那层的缓存。

### 4.6 前端与求解器

BuildKit 把「Dockerfile → LLB」称为 frontend，把「选择执行顺序和并发」称为 solver。官方文档提到多个 frontend：

- `dockerfile.v0` — 默认 Dockerfile 前端；
- `gateway.v0` — 容器化前端（把 frontend 本身做成镜像运行）；
- 自定义前端（用 Go 写，实现 `Client` 接口）。

这解释了 `# syntax=` 指令的作用：

```dockerfile
# syntax=docker/dockerfile:1
```

它把 Dockerfile 交给指定版本的前端解析，**而不是用 daemon 内置的那个旧版本**。这是使用 `RUN --mount` 等新特性的前提——老 daemon 不认识 `--mount` 会直接报错。

### 4.7 开启 BuildKit 的三种方式

```bash
# 方式 1（推荐）：docker buildx build
docker buildx build -t myapp .

# 方式 2：环境变量
DOCKER_BUILDKIT=1 docker build -t myapp .

# 方式 3：daemon.json 持久化
# { "features": { "buildkit": true } }
```

`docker buildx build` 的一个重要差异：**默认不把结果加载进本地 docker 镜像库**（`--load` 或 `--push` 才会）。这在 CI 里是好事——避免把大镜像塞进 runner 的磁盘。

## 五、工程清单

### 5.1 诊断当前构建

```bash
# 看每一层的大小与创建命令
docker history --no-trunc myapp:latest

# 看构建上下文大小
docker build -t myapp . 2>&1 | grep -i "transferring context"

# 看某一层具体包含什么
docker save myapp:latest -o myapp.tar
tar -tvf myapp.tar | head -50

# 用 buildx 看详细执行计划
docker buildx build --progress=plain -t myapp .
```

### 5.2 缓存命中率排查

```bash
# 带上本地缓存构建，观察 "CACHED" 标记
DOCKER_BUILDKIT=1 docker build --progress=plain -t myapp . 2>&1 | grep -E "CACHED|DONE"
```

输出里 `CACHED` 表示该步骤命中了缓存，`DONE` 表示重新执行了。

### 5.3 一份 Dockerfile 模板

```dockerfile
# syntax=docker/dockerfile:1

# ---------- 构建阶段 ----------
FROM node:20-slim AS build
WORKDIR /app

# 依赖层：变化最少，放最前
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefer-offline

# 源码层：变化最多，放最后
COPY . .
RUN npm run build

# ---------- 运行时 ----------
FROM node:20-slim AS runtime
ENV NODE_ENV=production \
    NODE_OPTIONS=--max-old-space-size=768
WORKDIR /app

# 只拷真正需要的
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

USER node
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

### 5.4 CI 中的缓存配置

```yaml
- uses: docker/setup-buildx-action@v3
- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ${{ github.repository }}:${{ github.sha }}
    cache-from: type=gha,scope=build
    cache-to: type=gha,mode=max,scope=build
```

`scope` 参数让不同分支 / 不同 Dockerfile 共享同一个缓存命名空间时互不污染。

### 5.5 检查清单

| 项 | 检查方法 | 目标 |
| --- | --- | --- |
| 依赖拷贝在源码拷贝之前 | 读 Dockerfile | 源码变化不废依赖层 |
| 有 `.dockerignore` | `ls .dockerignore` | 上下文 < 几 MB |
| 基础镜像固定版本 | 不用 `latest` | 基础层缓存稳定 |
| 不用 `ADD` 下载远程文件 | grep Dockerfile | 改用 `RUN curl` + 校验和 |
| 不用 `ARG` 传密钥 | grep Dockerfile | 改用 `--mount=type=secret` |
| 非 root 运行 | 有 `USER` 行 | 安全基线 |
| 缓存挂载用在依赖安装 | `--mount=type=cache` | 依赖走本地缓存 |
| 远程缓存 `mode=max` | 检查 CI 配置 | 中间层可复用 |
| 构建产物可复现 | 两次构建 digest 一致 | 可签名、可比对 |

### 5.6 什么时候不要继续优化

镜像构建优化的边际收益递减。以下情况优先做正确性而非速度：

- 构建本身只需 30 秒，CI 总时长由测试决定 → 别动 Dockerfile；
- 依赖下载慢但应用启动慢 → 先优化应用启动；
- 镜像已经 < 100MB 且部署不频繁 → 收益不足以覆盖维护成本。

**优化的目标是让「改代码 → 拿到反馈」这个循环变短，不是让 Dockerfile 变炫。**

## 小结

1. **镜像是一串不可变的层，每层的身份是它字节流的摘要。** 这条哈希链决定了什么能被复用、什么必须重建。
2. **缓存键由「父步骤缓存键 + 本步骤输入」递推决定**，所以 `COPY . .` 的位置比它复制了什么更重要。依赖拷贝前置是收益最高的单点改动。
3. **多阶段构建用「丢弃中间层」换来更小的镜像和更小的攻击面**，代价是构建步骤增加和调试变难；工具链远大于产物时值得做。
4. **BuildKit 把线性 Dockerfile 变成 DAG**，因此支持真并行、步骤间不共享文件系统、缓存挂载、secret mount。`# syntax=docker/dockerfile:1` 是使用这些特性的前提。
5. **远程缓存必须用 `mode=max`** 才能保存中间层；默认 `min` 只导出最终层，等于没优化依赖安装。
6. **`ARG` 传密钥是泄露，`--mount=type=secret` 才是正解。**
7. **优化的目标是缩短反馈循环。** 30 秒的构建不值得优化。

## 参考资料

- Dockerfile reference — 官方对缓存、multi-stage、`ADD`/`COPY`、`ARG`/`RUN --mount` 的完整说明
- BuildKit — 构建引擎与 solver、cache backend、mount 类型的官方文档
- `docker/build-push-action` 与 `docker/setup-buildx-action` 的官方 README
- OCI Image Specification — manifest、descriptor、layer 的规范定义
