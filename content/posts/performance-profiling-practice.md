---
title: "性能剖析实战：火焰图、pprof、perf 与采样偏差"
description: "优化之前先测量。本文讲清 CPU 剖析、内存剖析、火焰图的读法与陷阱，重点剖析采样偏差这一最容易被忽略的问题——为什么你的火焰图和真实负载不符；再讲 perf、async-profiler、eBPF 三种剖析器的差异，火焰图与调用树的关系，最后给出一套从假设到验证的优化方法论与常见优化手段的真实收益预期。"
date: 2026-11-28
categories: ["开发者工具"]
tags: ["性能剖析", "火焰图", "pprof", "perf"]
---

## 引言：测不准的优化等于没优化

性能优化领域有句老话：**"Measure twice, cut once."** 但更常见的情况是——

- 凭直觉改了一堆代码，吞吐提升 3%，然后引入了一个 bug；
- 加了缓存，命中率 92%，但端到端延迟一点没变（瓶颈在别处）；
- 火焰图看着很热闹，top 函数占了 40%，但这个函数 99% 的时间在等 IO；
- 开发机上火焰图很好看，生产上完全不一样。

这些失败大多源于同一个根因：**剖析结果不忠实于真实负载**。而造成不忠实的最主要原因——**采样偏差**——恰恰是新手最容易忽略的。

本文按这个顺序展开：

1. **第一节**：剖析的三种类型与它们各自能回答什么问题；
2. **第二节**：采样偏差的机理与常见形态，以及如何规避；
3. **第三节**：火焰图怎么读——从"哪个函数宽"到"为什么宽"；
4. **第四节**：CPU 剖析之外——内存、分配、锁、off-CPU；
5. **第五节**：工具选型（pprof / perf / async-profiler / eBPF）与各自的适用边界；
6. **第六节**：优化方法论与各手段的真实收益预期。

全文区分三类陈述：**已确认**（有官方文档或工具规范直接支撑）、**工程经验**（社区常见做法，随版本与场景变化）、**待验证**（需要你在自己的环境上测）。

## 一、剖析的三个基本问题

在动手之前先明确：性能问题只有三种形态，每种需要不同的测量手段。

| 问题形态 | 症状 | 关键测量 | 典型工具 |
| --- | --- | --- | --- |
| **CPU-bound** | CPU 使用率高，吞吐上不去 | CPU 时间去向 | pprof、perf、async-profiler |
| **Memory-bound / GC** | 分配率高、GC 频繁、延迟抖动 | 分配热点、GC 暂停 | pprof (heap)、allocation profile |
| **Wait-bound / I/O** | CPU 很低但吞吐上不去 | 阻塞时间、off-CPU 时间 | eBPF off-CPU、async-profiler、block profiling |

**关键判断**：如果应用 CPU 使用率只有 20%，那 80% 的时间它不在计算——你优化 CPU 热点的收益上限就是 20%。**先判断问题形态，再选工具。**

Brendan Gregg 的表述很准确：**CPU 使用率低的时候，火焰图是无效的**，因为采样命中的绝大多数都是 idle。

### 1.1 三种剖析方式

| 方式 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| **采样（sampling）** | 定时中断，采集栈 | 开销低，可用于生产 | 有采样偏差 |
| **插桩（instrumentation）** | 代码里埋点 | 精确计数 | 改变行为，开销大 |
| **事件追踪（tracing）** | 硬件/内核事件 | 最精确 | 需要特殊权限/硬件 |

**采样是默认选择**，因为它的开销足够低（通常 1-5%），可以在生产环境短时开启。插桩适合测量「调用了多少次」这类计数问题。

### 1.2 CPU 时间的两种语义

CPU profiling 测的是"样本落在哪个栈上"，但有两种不同的解释：

**用户态 vs 内核态。** 一个 syscall 阻塞时，进程在内核态。默认的 CPU profiler（如 Go 的 pprof）只采用户态栈，所以你会看到"CPU 使用率 80% 但火焰图很空"——那 80% 可能大部分在内核（网络栈、文件系统）。

**on-CPU vs off-CPU。** 采样 CPU 只在进程**正在 CPU 上运行**时记录。如果进程大部分时间在等锁、等 IO、等网络，内核会把它挂起，**不会出现在 CPU 火焰图里**。这类问题要用 off-CPU profiling。

**这是最常见的诊断盲区**：服务延迟高，CPU 不高，CPU 火焰图"很干净"——因为瓶颈在等待。

## 二、采样偏差：最容易被忽略的陷阱

### 2.1 采样偏差的机理

采样剖析器的工作方式：设置一个定时器（典型 10ms / 100Hz），每次中断时记录当前调用栈。

这引入两类偏差：

**偏差一：概率偏差（probabilistic bias）。** 每次中断时，进程被中断的位置是随机的——但**不是均匀随机于所有代码位置**。如果一个函数里有大量调用点，中断更可能落在那里；如果某段代码是原子的、不含中断检查点，几乎永远采不到。

**偏差二：状态偏差（state bias / skid）。** 采样中断发生时，内核保存的栈可能比真实的中断位置"超前"或"滞后"几个指令——这叫 **skid**。表现是火焰图上出现的是"调用它的那一行"而不是"真正耗时的行"。虽然多数时候 skid 只有几条指令，但在超短函数密集的代码里会有可见误差。

### 2.2 采样偏差的经典形态

**形态一：热点函数的"隐藏成本"。**

```go
func process() {
    for i := 0; i < 1000; i++ {
        if data[i].Valid() {      // 极短函数
            handle(data[i])
        }
    }
}
```

`Valid()` 本身逻辑极短，但被调用 1000 次。中断落在 `Valid()` 内部的概率相对较高，而它内部的指令数很少——于是**每次采样里它只占 1 个栈帧**。但因为 `handle` 更短，采样命中 `handle` 的概率也高，最终火焰图里两者占比相近，**看不出 `Valid()` 被调用了 1000 次这个事实**。

这就是为什么火焰图必须配合**调用次数**信息看。解决方案：把"耗时占比"和"调用次数"两个维度分开——火焰图看耗时，`pprof` 的 `-list` 或 trace view 看调用次数。

**形态二：短命函数被系统性放大。** 如果一个函数是"热点"，中断在它执行期间发生的概率就高。**它占用的 CPU 越多，被采到的次数越多**——这部分是真实反映。但一个被执行 100 万次、每次 10ns 的函数，可能在火焰图里比一个执行 100 次、每次 1ms 的函数还宽，尽管总耗时后者是前者的 10 倍。

**火焰图展示的是"样本占比"，不是"总耗时贡献"**——这两者在调用次数差异巨大时会严重脱节。

**形态三：inlining 导致的消失。** 编译器把小函数内联进调用者，火焰图上就看不到它了。Go 的 pprof 会保留内联帧信息（`-lines` 粒度），Java 的 async-profiler 默认处理内联，C/C++ 的 perf 需要 `-g` 编译。

**形态四：只采样一个线程。** 默认的 CPU profiler 只采主线程或创建它的线程。**工作线程池里的忙线程可能完全不被采集**。Go 的 pprof 有 `runtime.SetThreadLabel` 和 goroutine profile 补充；Java 的 async-profiler 默认采所有线程。

### 2.3 生产采样的特殊问题

在生产环境采样还有两类特殊偏差：

**采样的时机偏差。** 如果只在业务高峰采样，你会得到"高峰期的火焰图"——这通常是对的，但如果你想优化的是"平均延迟"，高峰期的图可能误导。反过来只在低峰采样，会漏掉真正的问题。

**采样的安全边界。** 生产上开启 profiling 本身有风险：

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 敏感数据泄露 | 栈里可能含 SQL、URL、参数 | 采集前脱敏 / 限制访问 |
| 性能扰动 | profiler 线程抢占 | 用低频采样 + 限时 |
| 采集端故障 | profile 端点被压垮 | 限流 + 短时开启 |
| 磁盘写满 | profile 文件过大 | 限制大小 + 自动清理 |

## 三、火焰图怎么读

### 3.1 火焰图的语义

Brendan Gregg 的经典定义："a flame graph is a visualization of aggregated stack traces, with width proportional to the number of samples."

**宽度 = 样本数占比 = CPU 时间占比。** 高度只是调用栈深度，**没有量化含义**——不要把高度当成"耗时"。

### 3.2 颜色编码

标准火焰图用颜色区分语义：

| 颜色 | 含义 |
| --- | --- |
| **红** | CPU（on-CPU）占用 |
| **绿** | 等待（off-CPU）时间——阻塞、IO |
| **蓝** | 不可达代码（unreachable） |
| **紫/青** | 其他特殊类型（如 GC、kernel） |

**混色火焰图（mixed / differential flame graph）** 把 on-CPU 和 off-CPU 叠在一起，能同时看到"哪烧 CPU"和"哪在等"。off-CPU 的时间通常比 on-CPU 大一个数量级，所以纯 CPU 火焰图会显得"很空"。

### 3.3 读图的顺序：从宽到窄逐层下钻

**第一步：找最宽的栈底（bottom-up 视角）。** 火焰图的底部是 main/根，最上面是叶子。宽度最大的路径是主要消耗。

**第二步：区分"宽而浅"和"窄而深"。**

- **宽而浅**（一个巨大的矩形）：热点在一个大函数里，看它的内部逻辑；
- **窄而深**（一条细长的长塔）：调用链深但每层占比小，通常不是主要矛盾，除非深度本身是问题（递归、框架层层转发）。

**第三步：识别"宽的平台"（plateau）。** 一块突然变宽的横向区域，就是热点边界。这是从慢路径切到快路径的分界。

**第四步：找出"尖刺"（spike）。** 突然变窄的深塔，通常是低频但耗时长的操作——GC、序列化、大对象分配、锁等待。

**第五步：确认是 on-CPU 还是 off-CPU。** 全红 = 真在算；全绿/青色 = 在等。

### 3.4 典型模式及其含义

| 火焰图形态 | 常见原因 |
| --- | --- |
| 顶部一个大三角（逐渐变窄的塔） | 正常的自顶向下调用，成本随深度递减 |
| 中间突然出现一个宽平台 | 热点函数（解析、序列化、哈希、GC） |
| 一条深而窄的塔，底部突然变宽 | 深递归调用 |
| 大量相同宽度的横向小块 | 循环里的重复操作（通常是可优化的） |
| 底部有一大块绿色 | 程序在等 IO 而非计算 |
| 顶部有两个对称的宽块 | 两个 worker 线程的并行工作 |

### 3.5 差分火焰图：定位"改了什么"

**差分火焰图（differential flame graph）** 把两个版本（或两个时间段）的火焰图按帧做差，用颜色和宽度表示增量。

典型用法：**优化前 vs 优化后**，一眼看出哪个函数的占比上升或下降。这比人工对比两个 HTML 报告高效得多。

Brendan Gregg 的工具 `difffolded.pl` 就是做这个的，输入两份折叠栈（folded stacks）文件，输出差分图。

## 四、CPU 之外：内存、分配、锁与 off-CPU

### 4.1 内存剖析：区分 in-use 与 allocated

这是内存剖析里最容易搞错的一点：

| Profile 类型 | 统计什么 | 用途 |
| --- | --- | --- |
| **heap (in-use)** | 当前仍在内存中的对象 | 找内存泄漏、找占用大头 |
| **allocations (cumulative)** | 进程启动以来所有分配动作的累计 | 找 GC 压力来源、找分配热点 |

**典型误用**：用 `alloc_space` 去查内存泄漏。`alloc_space` 显示的是"累计分配了多少"，一个不断分配又立刻释放的对象会排在最前面，但它**根本不占内存**。查泄漏必须用 `inuse_space`。

**Go 的具体命令**：

```bash
# 内存占用 top（in-use）
go tool pprof -top -inuse_space http://localhost:6060/debug/pprof/heap

# 分配 top（cumulative）
go tool pprof -top -alloc_space http://localhost:6060/debug/pprof/heap

# 加上 GC 后仍未释放的部分（真正泄漏的信号）
go tool pprof -top -inuse_space http://localhost:6060/debug/pprof/heap?gc=1
```

最后一个参数 `gc=1` 强制跑一次 GC 再统计——**这是区分"内存占用高"和"内存泄漏"的关键**。跑完 GC 后还占着的，才是真泄漏。

### 4.2 分配剖析：不看 GC 就治不了 GC

GC 压力来自**分配速率**，不是内存占用。一个应用可以只用 100MB 内存，但每秒分配 1GB 对象，GC 就会持续工作。

典型的高分配源：

- **字符串拼接**（尤其循环里）；
- **装箱**（interface 转换导致的堆分配）；
- **闭包捕获**（逃逸分析失败的闭包）；
- **切片扩容**（append 未预分配容量，每次都重新分配）；
- **临时对象**（本可以栈上分配却逃逸到堆）。

Go 的逃逸分析诊断：

```bash
# 打印编译期逃逸分析决策
go build -gcflags='-m' ./pkg/...
# -m 打印决策，-m -m 更详细
```

输出里 `moved to heap: x` 表示这个变量被判定为逃逸，`escapes to heap` 说明原因（如 `x escapes to heap due to ...`。

**优化手段对比**：

| 手段 | 效果 | 代价 |
| --- | --- | --- |
| 预分配 slice 容量 | 消除扩容期的重复分配 | 需要预估大小 |
| 避免循环内字符串拼接 | 消除 O(n) 次分配 | 改用 builder / bytes.Buffer |
| `sync.Pool` 复用对象 | 消除高频临时对象的分配 | 需注意对象生命周期 |
| 调整 `GOGC` | 降低 GC 频率（换更多内存） | 内存占用上升 |

`GOGC=200` 意味着堆增长 100% 时触发 GC（默认 100），GC 频率减半，内存占用大约翻倍。**这是最简单粗暴但有效的 GC 调优**。

### 4.3 锁与竞争剖析

**Go 的 mutex/block profile**：

```bash
# 采样配置（代码里）
runtime.SetMutexProfileFraction(5)
runtime.SetBlockProfileRate(1000)   # 每 1000ns 采样一次阻塞
```

```bash
go tool pprof -top http://localhost:6060/debug/pprof/mutex
go tool pprof -top http://localhost:6060/debug/pprof/block
```

- **mutex profile**：竞争导致的等待（锁争用）；
- **block profile**：channel 阻塞、syscall 阻塞等。

**Java 的锁分析**：`jcmd <pid> Thread.print` 拿线程栈，或用 JFR（Java Flight Recorder）记录 `jdk.JavaMonitorEnter` 事件。

### 4.4 Off-CPU 剖析：等待型问题的正解

当 CPU 不高但延迟高，off-CPU 剖析是正确工具。做法是：

1. 采样时刻记录所有（或指定）线程的栈；
2. 记录"这个线程从上次被调度到这次被调度，阻塞了多久"；
3. 把阻塞时长按栈聚合成火焰图（宽度 = 阻塞时长）。

工具支持：

| 工具 | 平台 | 能力 |
| --- | --- | --- |
| **async-profiler** | JVM / Linux | `-e offcpu` 模式，同时输出 on-CPU 和 off-CPU |
| **Parca** | Linux（eBPF） | 持续 off-CPU 剖析，无需重启 |
| **bpftrace** | Linux | 手工编写 off-CPU 追踪脚本 |
| **runqlat** | Linux（BPF） | 运行队列延迟 |

Go 没有内置 off-CPU profiler，但 `block` profile 覆盖了大部分场景（channel 阻塞、锁等待、syscall）。

**典型发现**：off-CPU 火焰图上最宽的是 `net.Conn.Read`——说明瓶颈是等待对端响应，不是本地计算。这时候该做的是超时控制、连接池、熔断，而不是优化 CPU。

## 五、工具选型

### 5.1 pprof（Go）

Go 的剖析器，内置于运行时，无需额外依赖。

**采集方式**：

```go
import _ "net/http/pprof"   // 导入即注册 /debug/pprof/ 端点

// 或手动启动
go func() {
    http.ListenAndServe("localhost:6060", nil)
}()
```

**端点**：

| 路径 | 内容 |
| --- | --- |
| `/debug/pprof/profile?seconds=30` | CPU profile（30 秒） |
| `/debug/pprof/heap` | 堆 profile |
| `/debug/pprof/allocs` | 累计分配 profile |
| `/debug/pprof/goroutine?debug=2` | goroutine 栈 |
| `/debug/pprof/mutex` | 锁竞争 |
| `/debug/pprof/block` | 阻塞 |
| `/debug/pprof/trace` | 执行轨迹（trace） |

**CLI 用法**：

```bash
# 采集 + 分析一体
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# 保存后交互式分析
go tool pprof -http=:8080 cpu.pprof     # 打开 Web UI（推荐）
go tool pprof -http=:8080 cpu.pprof &

# 常用视图
go tool pprof -top -cum http://localhost:6060/debug/pprof/profile   # 按累计排序
go tool pprof -list='regexp\.Compile' http://localhost:6060/debug/pprof/heap  # 源码级
go tool pprof -traces http://localhost:6060/debug/pprof/profile     # 采样轨迹
```

**`-top` vs `-cum`** 是初学者最常问的：`-top` 按函数自身耗时排序，`-cum`（cumulative）按包含子调用的总耗时排序。**排查"谁在调用这个慢函数"用 `-cum`，排查"哪个函数自己最慢"用 `-top`。**

**pprof 的采样率**：Go 默认 100Hz（每 10ms 一次）。`runtime.SetCPUProfileRate` 可以调高，但会显著增加开销，且官方文档建议不超过 1000Hz。

**pprof 的 trace view** 很有用：它展示采样点的实际执行轨迹，能帮你验证"这个函数真的被调用了 N 次"以及"采样有没有集中在一个地方"。

### 5.2 perf（Linux）

Linux 内核性能分析工具，几乎所有发行版都自带（`linux-tools` 包）。

```bash
# 记录 30 秒的 CPU profile
perf record -F 99 -g --call-graph dwarf -p <PID> -- sleep 30

# 交互式查看
perf report

# 直接生成火焰图
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

**关键选项**：

| 选项 | 作用 | 注意 |
| --- | --- | --- |
| `-F 99` | 采样频率 99Hz | 避开 100Hz 附近的锁定效应 |
| `-g` | 采集调用栈 | 需要 frame pointer 或 DWARF |
| `--call-graph dwarf` | 用 DWARF 解栈 | 精确但开销高；`fp` 更快但需 `-fno-omit-frame-pointer` |
| `-p <PID>` | 附加到进程 | 不影响其他进程 |

**frame pointer 与 DWARF 的权衡**：`-g` 的 DWARF 模式最准确，能正确处理内联，但开销大（可能 10-30%）；frame pointer 模式开销小（1-3%），但要求编译时保留 frame pointer，且对内联支持差。

**perf 的独有能力**：

```bash
# 硬件计数器事件（需要 perf_event 权限）
perf list                       # 列出可用事件
perf stat -e cache-misses,cycles ./your_program

# 用硬件计数器算 IPC、缓存命中率
perf stat -e instructions,cycles,cache-references,cache-misses ./app
```

这是 pprof 做不到的——pprof 只有采样时间维度，perf 能测**硬件层面的效率指标**。

**perf 也有自己的偏差**：默认按 CPU 计，采到的是"在哪个 CPU 上运行的线程"，多线程程序需要 `-t` 或按线程过滤。

### 5.3 async-profiler（JVM）

基于 perf_events 的 JVM 性能剖析器，支持多种事件模式：

```bash
# CPU 火焰图
./profiler.sh -d 30 -f /tmp/flame.html <pid>

# 分配剖析
./profiler.sh -d 30 -e alloc -f /tmp/alloc.html <pid>

# 锁竞争
./profiler.sh -d 30 -e lock -f /tmp/lock.html <pid>

# off-CPU（wall clock）
./profiler.sh -d 30 -e wall -f /tmp/wall.html <pid>
```

**它的核心优势是「wall clock 模式」**：`-e wall` 采样 wall-clock 时间而不是 CPU 时间，能捕获 GC 停顿、阻塞、以及所有非 CPU 时间。这对 Java 服务的端到端延迟分析非常有用。

**JFR（Java Flight Recorder）** 是 JDK 自带的替代/补充方案：低开销、事件丰富、内置在生产版 JDK 中（JDK 11+ 免费）。缺点是事件分析需要额外的工具（JMC 或 jfr 命令行）。

### 5.4 eBPF 剖析器

Parca 等工具用 eBPF 做持续剖析，优势是**无需重启进程、无需修改启动参数**：

```bash
parca --source=localhost:7070
```

eBPF 方式还能拿到**内核栈**（当用户态栈不足以定位时很有用），并且可以在不改代码的前提下 profiling 任何进程。

**限制**：需要特权（`CAP_BPF`、`CAP_PERFMON`）、对内核版本有要求、符号化需要对应的调试符号。

### 5.5 工具选型速查

| 场景 | 推荐 | 理由 |
| --- | --- | --- |
| Go 服务 CPU | pprof | 内置、零依赖、集成最好 |
| Go 服务内存/GC | pprof heap + alloc | `gc=1` 参数区分泄漏 |
| Go 服务等待 | pprof block + goroutine | 无内置 off-CPU |
| Java 服务 CPU | async-profiler | 低开销、事件丰富 |
| Java 服务端到端延迟 | async-profiler `-e wall` 或 JFR | 能看到 GC 停顿 |
| C/C++ 服务 | perf | 内核级，支持硬件计数器 |
| 任意进程、无法改启动参数 | Parca (eBPF) | 零侵入 |
| 需要硬件效率指标 | perf stat | 缓存、IPC、分支预测 |

## 六、优化方法论与收益预期

### 6.1 从假设到验证的闭环

性能优化的正确循环：

```
1. 建立基线：定义 SLI（延迟 P99、吞吐、CPU、内存）
2. 提出假设："瓶颈在 X"
3. 用剖析数据验证假设（不是凭直觉）
4. 做最小改动
5. 重新测量，对比基线
6. 保留有效改动，回退无效改动
7. 记录结论
```

**关键纪律：一次只改一个变量。** 同时改五处然后测出 20% 提升，你不知道是哪一处有效，也无法在下次遇到问题时复用知识。

### 6.2 各优化手段的真实收益预期

| 手段 | 典型收益 | 适用条件 | 风险 |
| --- | --- | --- | --- |
| **换更快的算法** | 10x - 1000x | 复杂度可降（O(n²)→O(n log n)） | 实现复杂、可能引入 bug |
| **加索引 / 改查询计划** | 2x - 100x | 数据库有查询瓶颈 | 写放大、存储占用 |
| **消除 N+1 查询** | 2x - 50x | ORM 懒加载导致 | 需要批量接口支持 |
| **缓存** | 2x - 100x | 读多写少、重复计算 | 失效逻辑、缓存穿透、内存成本 |
| **批处理 / 向量化** | 2x - 10x | 逐条处理的循环 | 内存峰值、延迟变差 |
| **并行化** | 2x - N（核数） | 可并行、CPU-bound | 复杂度、竞态、上下文切换开销 |
| **减少分配 / 调优 GC** | 1.2x - 3x | 分配率高 | 内存占用上升 |
| **换更快的序列化格式** | 1.2x - 5x | JSON 是瓶颈 | 兼容性、调试难度 |
| **零拷贝 / 减少拷贝** | 1.1x - 2x | 数据搬运是瓶颈 | 实现复杂、平台相关 |
| **调大线程池 / 连接池** | 1.1x - 3x | 存在等待 | 上下文切换、上游压力 |

**注意最后一列——每种优化都有代价。** 尤其是"调大池子"这类看似无害的改动，可能把瓶颈从本地转移到上游（数据库、第三方 API）。

### 6.3 缓存是最容易出错的优化

缓存的经典问题：

| 问题 | 现象 | 解法 |
| --- | --- | --- |
| **缓存穿透** | 查不存在的 key，每次都打到 DB | 缓存空值（短 TTL）或布隆过滤器 |
| **缓存击穿** | 热点 key 过期瞬间，大量请求打到 DB | 互斥重建 / 逻辑过期 |
| **缓存雪崩** | 大量 key 同时过期 | TTL 加随机抖动 |
| **缓存与源不一致** | 读到旧数据 | TTL + 失效通知；强一致场景放弃缓存 |

**缓存穿透的解法值得展开**：最简单的是「查不到也缓存一个空值标记，TTL 短（如 60s）」。这会挡住绝大多数恶意/误用的不存在 key 的查询。布隆过滤器更进一步，能在缓存之前就判定「一定不存在」，但它有假阳性（判"不存在"时可能实际存在）——对于「本来就不该存在」的 key 这是可接受的。

**一个常见的性能陷阱：缓存放错了层。** 在应用进程内缓存（本地缓存）比在 Redis 里快得多，但多实例下每个实例各存一份，失效逻辑要处理所有实例。**本地缓存 + Redis 两级**是常见折中。

### 6.4 优化的正确顺序

```
1. 先测量，定位真正的瓶颈（不要猜）
2. 优先改算法和数据结构
3. 然后消除多余的工作（重复计算、重复 IO）
4. 再考虑并行化和缓存
5. 最后才是调参数（池大小、GC 参数、批大小）
```

**第 5 步是最容易被滥用的一步**：调参数见效快（5 分钟 vs 3 天），但它通常是在掩盖结构性问题。Brendan Gregg 的建议：把「调参数」留到最后，因为前面四步的效果是数量级的。

### 6.5 别忘了端到端视角

**局部优化不等于整体优化。** 一个常见的失败：

```
服务 A: 200ms → 180ms  (本地优化 10%)
服务 B: 800ms → 800ms  (没动)
端到端: 1000ms → 980ms  (只有 2%)
```

更有害的版本：

```
服务 A: 200ms → 20ms   (本地优化 10x！)
服务 B: 800ms → 790ms  (因为 A 变快，B 的连接池等待时间也变了)
端到端: 1000ms → 810ms
```

以及真正糟糕的情况：**优化让某个环节变慢，但因为它是瓶颈，整条链都变慢了。**

**所以每次优化后必须验证端到端的 SLI，而不是只看局部指标。**

### 6.6 工程清单

| 检查项 | 判定 | 说明 |
| --- | --- | --- |
| 有明确的基线 SLI | 有 P99/吞吐记录 | 没有基线就无法判断改善 |
| 先判断问题形态 | CPU/memory/wait | CPU 占用低时别优化 CPU |
| 采样在代表性负载下采集 | 采集时机说明 | 高峰/低峰/混合 |
| 采样时长足够 | CPU 剖析 ≥ 30s | 太短会漏掉长尾路径 |
| 火焰图与调用次数对照 | 看 `-cum` 和 trace view | 防采样偏差误判 |
| 内存问题用 inuse 而非 alloc | pprof 参数 | alloc_space 不能查泄漏 |
| GC 后统计验证泄漏 | `heap?gc=1` | 区分"占用高"和"泄漏" |
| 等待型问题用 off-CPU | 工具选择 | CPU 火焰图对等待无效 |
| 优化后验证端到端 SLI | 对比基线 | 局部优化可能无意义 |
| 一次只改一个变量 | 变更记录 | 保证结论可复用 |
| 记录优化结论 | 文档 | 形成组织知识 |
| 生产剖析有防护 | 脱敏/限时/限流 | 安全与稳定性 |

## 小结

1. **先判断问题形态**：CPU-bound、Memory-bound、Wait-bound 用不同工具。CPU 使用率低时，CPU 火焰图基本无效。
2. **采样偏差是最大的隐性陷阱**：火焰图的宽度是**样本占比**，不等于总耗时贡献；被调用百万次的短函数和被调用百次的长函数可能比例倒挂。必须配合调用次数（`-cum`、trace view）交叉验证。
3. **火焰图读图顺序**：找最宽路径 → 区分宽平台与深塔 → 识别尖刺 → 确认 on-CPU 还是 off-CPU。高度没有量化含义。
4. **内存问题用 `inuse_space` + `gc=1`**，`alloc_space` 只能用来找 GC 压力源，不能用来查泄漏。
5. **等待型问题必须用 off-CPU 剖析**，CPU 火焰图对此无效。async-profiler 的 `-e wall` 模式和 eBPF 剖析器都是解法。
6. **工具选型**：Go 用 pprof，Java 用 async-profiler 或 JFR，C/C++ 用 perf，需要硬件计数器只能用 perf stat，零侵入用 eBPF。
7. **优化顺序：算法 → 消除多余工作 → 并行/缓存 → 调参数。** 调参数见效快但通常掩盖结构性问题。
8. **缓存有四种经典故障**：穿透、击穿、雪崩、不一致，各有对应解法。
9. **优化后必须验证端到端 SLI。** 局部 10x 优化在 80% 时间花在别处的系统里，可能只有 2% 的端到端收益。
10. **一次只改一个变量，并记录结论。** 这是可复用的组织知识，也是唯一能保证优化有效的方法。

## 参考资料

- Brendan Gregg《Systems Performance》与《Performance Analysis Toolkit》，火焰图方法论原始出处
- Go 官方文档 `runtime/pprof` 与 `net/http/pprof`
- Go 官方博客《Go's pprof: Profile your Go programs》
- perf 官方用户指南（Linux 内核文档 `perf` 章节）
- async-profiler 官方文档：事件模式与 wall-clock 采样
- JEP 328：Java Flight Recorder 开放为通用特性
- Parca 官方文档：基于 eBPF 的持续剖析
