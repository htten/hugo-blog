---
title: "开发者命令行工具设计：交互、配置与插件体系"
description: "命令行工具不是把参数解析完就完事。本文从子命令与 flag 布局、帮助系统、退出码语义、配置优先级、插件发现与版本协商六个方面，拆解如何设计一个让人愿意天天用的 CLI，并给出可直接落地的工程做法与验收清单。"
date: 2026-11-22
categories: ["开发者工具"]
tags: ["CLI", "工具设计", "插件", "配置", "退出码"]
---

## 引言：CLI 难用的根因不在解析器

写 CLI 的人常犯一个错误：把"命令行工具"等同于"参数解析器"。于是拼出一个 `flag` 包绑上几个变量，参数能收下，任务就算完成了。

真实用户抱怨的从来不是解析失败，而是这些事：

- 我不知道这个工具有哪些子命令，只能先跑一次 `--help` 再照着抄；
- 我不知道某个开关叫什么名字，只能把 `--verbose` 猜一遍；
- 我把它放进 CI 脚本，失败了却看不出是"用法错了"还是"服务端挂了"；
- 我配了配置文件，环境变量一设就把我的配置整个覆盖掉了；
- 我想在脚本里复用一段逻辑，工具却没有插件或子命令的扩展点；
- 工具升级后我原来的脚本突然行为变了，却没有任何提示。

本文把这些痛点归到六个可工程化的问题：**布局**（子命令与 flag 怎么排）、**可发现性**（帮助与补全）、**契约**（退出码与输出契约）、**配置**（多来源优先级）、**扩展**（插件体系）、**演进**（版本与兼容性）。每一条都给出可核对的依据、能跑的代码，以及验收方式。

全文区分三类陈述：**已确认**（有官方文档或规范支撑的事实）、**工程经验**（常见做法，具体数值随场景变化）、**待验证**（需要你在自己的项目上实测）。

本文与站内已有的 [LLM 应用可靠性工程](/posts/llm-application-reliability-engineering/) 是两件事：那篇讲的是运行时调用链路的可靠性，本文讲的是**面向人的命令行接口契约**。两者都涉及"失败语义"，但层次不同，不要混用结论。

## 一、命令布局：先决定动词，再决定名词

### 1.1 一个能自解释的命名约定

Cobra 官方 README 给出的设计模式是：

```
APPNAME VERB NOUN --ADJECTIVE
APPNAME COMMAND ARG --FLAG
```

**已确认**：Cobra 把这个模式写进了文档，它同时给了一套心智模型——**Command 是动作，Args 是事物，Flags 是修饰语**。这条模型的价值在于：它让"这个工具到底有哪些动词"变成一个可以在五分钟内枚举完的有限集合，而不是一堆扁平的长选项。

| 你的意图 | 差的设计 | 好���设计 | 原因 |
| --- | --- | --- | --- |
| 上传文件 | `--upload --file a.txt` | `app upload a.txt` | 上传是动作，文件名是事物 |
| 列出所有实例 | `--list-instances` | `app instance list` | 资源应成组，避免顶层 flag 爆炸 |
| 提高详细度 | `--verbose --very-verbose` | `-v` / `-vv` / `-vvv` | 同一维度用计数表达 |
| 临时改配置 | `--config-override x=y` | `--set x=y`（可重复） | 语义化、可组合 |

### 1.2 顶层不要堆超过十个子命令

**工程经验**：顶层子命令数量一旦超过十几个，用户就会开始"记不住命令名"，转而依赖 `--help` 或搜索引擎。可行的收敛方式有三种：

1. **资源分组**：`app resource action`，把同类操作收进一个命名空间；
2. **动词归并**：把 `create`/`add`/`new` 合成一个，把 `rm`/`delete`/`remove` 合成一个，其余用别名兜住旧名字；
3. **文档兜底**：提供可搜索的文档站点，并在 `--help` 末尾给出入口。

Cobra 提供了**命令别名**（alias）机制，正是为第 2 类收敛准备的：对外只留一个规范名，旧名作为别名继续可用，直到下一个大版本再废弃。

### 1.3 flag 的三种作用域：全局、本地、级联

**已确认**（Cobra User Guide）：

- **local flags**（`localCmd.Flags()`）只对定义它的那个命令生效；
- **persistent flags**（`rootCmd.PersistentFlags()`）对该命令及其所有子命令生效；
- `Command.TraverseChildren = true` 会让**父命令的 local flag 也被解析**，而不是只解析到第一个子命令为止。

这三种作用域对应三类真实需求，混用会让帮助文本自相矛盾：

```go
// 全局：所有子命令都关心
rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "配置文件路径")

// 本地：只有这个命令关心
listCmd.Flags().BoolVar(&all, "all", false, "包含已归档条目")

// 级联：父命令的本地开关对子命令同样有效
rootCmd.Flags().BoolVar(&verbose, "trace", false, "输出调用链")
rootCmd.TraverseChildren = true
```

**踩坑提醒**：如果一个 flag 既想全局可用又想就地定义，务必用 persistent，而不是在每个子命令里重复注册。重复注册的直接后果是 `--help` 输出里出现两份同名开关，用户无从判断哪个生效。

### 1.4 位置参数校验要显式声明

**已确认**（Cobra User Guide）：Cobra 内置了位置参数校验器 `NoArgs`、`ArbitraryArgs`、`MinimumNArgs`、`MaximumNArgs`、`ExactArgs`、`RangeArgs`、`OnlyValidArgs`、`NoDuplicateArgs`；`Args` 为 nil 时**默认是 `ArbitraryArgs`（即不校验）**；多个校验器可用 `MatchAll(...)` 组合；自定义校验器签名为 `func(cmd *cobra.Command, args []string) error`。

"默认不校验"这件事是很多 CLI 用起来"很宽松"的原因。工具作者必须自己声明契约：

```go
cmd.Args = cobra.MatchAll(
    cobra.ExactArgs(1),      // 必须且只能有一个位置参数
    cobra.OnlyValidArgs,     // 只能是枚举里的值
)
```

**工程经验**：如果参数个数本身有语义（子命令、对象、动词），把它写进 `Args` 校验器，比在 `Run` 里手写 `if len(args) != 1` 更好——因为校验器发生在进入业务逻辑之前，错误信息也统一由框架打印。

### 1.5 参数校验器的三个"必须"

| 要求 | 做法 | 收益 |
| --- | --- | --- |
| 必须 | `MarkFlagRequired` / `MarkPersistentFlagRequired` | 缺失时在参数解析阶段就报错，而不是执行到一半才失败 |
| 互斥 | `MarkFlagsMutuallyExclusive` | 防止用户同时传 `--output file` 和 `--output -` 这类自相矛盾 |
| 同组 | `MarkFlagsRequiredTogether` | 多参数组合要么都给要么都不给 |

**已确认**：这三个 API 在 Cobra User Guide 中有明确文档。

## 二、可发现性：帮助、补全与"猜错提示"

### 2.1 帮助文本是产品文档，不是 debug 输出

**已确认**（Cobra README）：Cobra 自动生成 help、识别 `-h`/`--help`、在 help 中对子命令分组、自动生成 bash/zsh/fish/powershell 补全脚本、自动生成 man page、支持自定义 help/usage。

"在 help 中对子命令分组"这条能力值得单独说。Cobra 通过 `AddGroup()` 定义分组，子命令用 `GroupID` 归属分组：

```go
rootCmd.AddGroup(
    &cobra.Group{ID: "build", Title: "构建相关"},
    &cobra.Group{ID: "ops",  Title: "运维相关"},
)
deployCmd.GroupID = "build"
```

分组后的 `--help` 会把几十个平铺的命令变成几个有语义的区块。这是**用排版解决可发现性**，比写一篇长 README 成本低得多。

### 2.2 命令名拼错时给出建议

**已确认**（Cobra User Guide）：Cobra 的未知命令建议基于 **Levenshtein 距离**，只有距离 **小于 2**（忽略大小写）时才会提示；可用 `DisableSuggestions = true` 关闭，用 `SuggestionsMinimumDistance = 1` 调整阈值，用 `SuggestFor` 显式指定某个命令的建议词（例如 `kubectl remove` 建议 `delete`）。

这个"距离 < 2"的默认值值得注意：它意味着 `server` 和 `serv` 能被纠正，但 `srv` 和 `web` 之间差得远就不会提示。**工程经验**：如果你的工具命令名很多，把 `SuggestionsMinimumDistance` 调到 3 会明显提升体验，代价是偶尔出现不相关建议。

### 2.3 shell 补全是最低成本的体验升级

**已确认**（Cobra README）：Cobra 自动生成 bash/zsh/fish/PowerShell 的补全脚本。Rust 侧 clap 同理，urfave/cli v3 README 明确写了 "dynamic shell completion for bash/zsh/fish/powershell"。

补全的实际价值远超想象——它把"记住命令结构"这件事从用户脑子里转移到了工具里。用户按 Tab 就能看到当前层级的所有子命令和可用 flag。

**工程经验**：补全脚本要能被用户 easy install。常见做法是提供 `app completion bash` 子命令，把脚本打印到 stdout，用户自行 `source`；不要试图替用户改 `~/.bashrc`。

### 2.4 hook 的执行顺序与一个必须知道的坑

**已确认**（Cobra User Guide）：Cobra 的执行钩子顺序为

```
PersistentPreRun → PreRun → Run → PostRun → PersistentPostRun
```

**但默认只会执行命令链中找到的第一个 persistent 钩子**。也就是说，如果 root 命令和子命令都定义了 `PersistentPreRun`，只有最靠近被执行命令的那个会跑。官方文档给出的解法是设置全局变量：

```go
cobra.EnableTraverseRunHooks = true
```

**工程经验**：这个开关应当在 `main` 里显式开启并写进注释。它属于"不开启就静默少跑一半逻辑"的类型，排查起来非常费时间。

## 三、输出与退出码：给脚本一个稳定契约

### 3.1 退出码是 CLI 最硬的对外接口

**已确认**（`sysexits.h(3head)`，Linux man-pages 6.20）：POSIX 风格的 BSD 退出码约定为——

| 宏 | 值 | 含义 |
| --- | --- | --- |
| `EX_OK` | 0 | successful termination |
| `EX_USAGE` | 64 | command line usage error |
| `EX_DATAERR` | 65 | data format error |
| `EX_NOINPUT` | 66 | cannot open input |
| `EX_NOUSER` | 67 | addressee unknown |
| `EX_NOHOST` | 68 | host name unknown |
| `EX_UNAVAILABLE` | 69 | service unavailable |
| `EX_SOFTWARE` | 70 | internal software error |
| `EX_OSERR` | 71 | system error |
| `EX_CANTCREAT` | 73 | can't create (user) output file |
| `EX_IOERR` | 74 | input/output error |
| `EX_TEMPFAIL` | 75 | temp failure; user is invited to retry |
| `EX_PROTOCOL` | 76 | remote error in protocol |
| `EX_NOPERM` | 77 | permission denied |
| `EX_CONFIG` | 78 | configuration error |

文档原文要点：

- 成功退出永远是 `0` / `EX_OK`（等价于 `<stdlib.h>` 的 `EXIT_SUCCESS`）；
- 错误码**从 `EX__BASE`（64）开始**，以减少与程序自身可能返回的退出码冲突；
- `EX_USAGE` 用于"wrong number of arguments, a bad flag, bad syntax in a parameter"；
- `EX_DATAERR` "should only be used for user's data and not system files"；
- `EX_NOPERM` "not intended for file system problems, which should use `EX_NOINPUT` or `EX_CANTCREAT`, but rather for higher level permissions"；
- CAVEATS 明确写道：**"The choice of an appropriate exit value is often ambiguous."**（退出码的合适取值往往并不唯一）；
- 历史：该文件来自 4.0BSD，为 deliverymail（后改名 sendmail(8)）引入；标准为 BSD。

### 3.2 用退出码分层，让脚本能区别对待失败

**工程经验**：把"用法错"和"环境错"混成退出码 1，是脚本无法自动处理故障的主要原因。推荐的三层划分：

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! output=$(app deploy --env prod 2>err.log); then
  rc=$?
  case "$rc" in
    64|65) echo "用法或数据有问题，脚本不重试" >&2; exit "$rc" ;;
    69|75) echo "服务暂时不可用，可稍后重试" >&2; exit 75 ;;
    70|71) echo "工具自身缺陷，请上报" >&2; exit "$rc" ;;
    *)     echo "未知失败" >&2; exit "$rc" ;;
  esac
fi
```

这张表可以直接翻成用户手册里的一节：**每类退出码意味着什么、脚本该不该重试**。

### 3.3 输出通道要分离

**工程经验**（与主流 Unix 工具一致）：

- **stdout**：命令的**数据输出**，供管道消费（`app list --json | jq`）；
- **stderr**：诊断信息、警告、进度、错误消息；
- **exit code**：给脚本的机器可读结论。

如果把日志打到 stdout，`app list | jq` 就会因为混进日志行而解析失败。这是 CLI 最常见的"能跑但没法用"的原因。

### 3.4 错误前缀可定制

**已确认**（Cobra User Guide）：`SetErrPrefix` 用于自定义错误前缀，默认是 `Error: `。多子命令的工具可以用它区分来源。

### 3.5 输出格式要支持机器可读模式

**工程经验**：任何可能被人放进脚本的工具，都应至少提供两种输出形态：

| 模式 | 用途 | 要求 |
| --- | --- | --- |
| 人类可读（默认） | 交互使用 | 有颜色、有对齐、有进度提示 |
| `--json` / `--format json` | 脚本消费 | 字段稳定、错误也用 JSON 输出到 stderr |

字段稳定性比字段丰富更重要：一旦发布就要能长期依赖，否则用户会写死字段名，工具再也无法演进。

## 四、配置：多来源优先级是核心

### 4.1 Viper 的优先级顺序（已确认）

**已确认**（Viper README）：Viper 合并配置源的优先级从高到低为：

```
explicit call to Set  >  flags  >  environment variables  >  config files
                      >  external key/value stores  >  defaults
```

同一份文档还给出了几个必须知道的细节：

- **"Viper configuration keys are case insensitive"**（键名大小写不敏感）；
- 支持 JSON / TOML / YAML / INI / envfile / Java Properties；
- `viper.FileLookupError` 用于区分"文件未找到"与"解析出错"（配合 `errors.As`）；
- `WriteConfig` 与 `SafeWriteConfig` 的区别是后者不会覆盖已有文件；
- `WatchConfig()` + `OnConfigChange(func(e fsnotify.Event))` 支持热重载，但**所有 config path 必须在调用 `WatchConfig` 之前定义好**；
- `ReadConfig(bytes.NewBuffer(...))` 读取内存内容前需要先 `SetConfigType`；
- `Set("host.port", 5899)` 支持嵌套键；`RegisterAlias("loud", "Verbose")` 支持别名；
- `SetEnvPrefix("spf")` + `BindEnv("id")` 会自动拼出大写前缀与键名；`AutomaticEnv()` 开启自动查找；
- **默认空环境变量被视为"未设置"**，除非开启 `AllowEmptyEnv`；
- **环境变量不做缓存**，每次访问都重新读取；
- `SetEnvKeyReplacer` / `EnvKeyReplacer` 用于 SCREAMING_SNAKE_CASE 与 kebab-case 之间的转换；
- 标准库 `flag` 包不能直接绑定，但可以通过 pflag 的 `AddGoFlagSet` 转换；
- 也可实现 `FlagValue` / `FlagValueSet` 接口，用 `BindFlagValue` / `BindFlagValues` 绑定；
- 远程 KV 支持 Etcd / Etcd3 / Consul / Firestore / NATS（`import _ "github.com/spf13/viper/remote"`），配合 `AddRemoteProvider` / `ReadRemoteConfig` / `WatchRemoteConfig`；
- crypt 加密可选，依赖 GPG keyring；
- **"Viper does not deep merge configuration values. Complex values that are overridden will be entirely replaced."**（Viper 不做深度合并，被覆盖的复杂值会被整体替换）；
- 嵌套键用 `.` 分隔；若同时存在与分隔键路径完全匹配的扁平键，则优先返回该扁平键（`datastore.metric.host` 优先于嵌套结构）；
- `Sub("cache.cache1")` 可提取子集；`Unmarshal` 默认使用 mapstructure tag；`KeyDelimiter("::")` 可改分隔符；
- `AllSettings()` 配合 `yaml.Marshal` 可导出全部配置。

### 4.2 "不深合并"是配置事故的高发点

上面那句原文值得单独强调。假设配置是：

```yaml
# ~/.config/app/config.yaml
database:
  host: db.internal
  port: 5432
  pool:
    size: 20
    timeout: 30s
```

而环境变量或 flag 给出了 `database.host=db.other`，在**不深合并**的语义下，整个 `database` 段会被替换，`pool` 配置随之丢失。用户只改了主机名，却连带丢了连接池参数。

**工程经验**：对含嵌套结构的配置，要么改用支持深合并的方案，要么在 CLI 层显式做"键级合并"（把默认值、文件值、环境变量值、flag 值按键逐个求值，而不是整段替换）。

### 4.3 flag 与配置文件的冲突

**已确认**（Cobra User Guide）：viper 绑定 flag 时的行为是——**"the variable will not be set to the value from config, when the --author flag is provided by user"**（用户显式提供了该 flag 时，变量取 flag 值而不是配置文件的值）。

这正是想要的语义：**显式输入 > 隐式默认值**。但它要求 flag 的默认值必须是零值，否则"用户没传"和"用户传了零值"无法区分。

**工程经验**：可重复参数用 `StringArrayVarP`（可重复）而不是 `StringSliceVarP`（逗号分隔或重复）——前者不会被 shell 的分词规则意外切开。**已确认**（Cobra User Guide）：`CountVarP` 可实现 `-v` / `-vv` / `-vvv` 的计数式 flag。

### 4.4 全局单例不是好主意

**已确认**（Viper README FAQ）：文档明确指出**全局实例一般不推荐**，最佳实践是 `viper.New()` 之后把实例传下去，因为全局实例未来可能被弃用（issue #1855）；同时强调 **Viper 并发读写不安全，需要自己加锁，否则会 panic**。

对 CLI 工具来说这条尤其实际：CLI 是**单进程、单线程**的典型场景，用全局实例"看起来没问题"；但一旦工具开始提供库形态（被别的程序 import），全局单例 + 并发访问就是崩溃源。

### 4.5 配置来源对照表

| 来源 | 优先级 | 典型用途 | 注意 |
| --- | --- | --- | --- |
| CLI flag | 最高（除显式 `Set`） | 一次性覆盖 | 显式传入应压过一切 |
| 环境变量 | 高 | 容器/CI 注入 | 空字符串默认视为未设置 |
| 配置文件 | 中 | 项目级、用户级 | 注意不深合并 |
| 远程 KV | 低 | 集群统一下发 | 需处理不可用 |
| 默认值 | 最低 | 内置缺省 | 应与 flag 默认值一致 |

## 五、插件体系：把扩展点设计出来

### 5.1 插件的四种形态

**工程经验**：CLI 插件按耦合度从低到高分四档：

| 形态 | 机制 | 优点 | 代价 |
| --- | --- | --- | --- |
| 子命令即插件 | 外部二进制注册为 `app-foo`，被 `app foo` 调度 | 进程隔离、崩溃不互相影响 | 需约定调用协议 |
| 配置驱动扩展 | 配置文件声明任务，工具执行 | 无需写代码 | 表达力有限 |
| 解释器内嵌 | 工具内嵌脚本引擎 | 扩展表达力强 | 沙箱与安全复杂 |
| 进程内注册 | 工具以库形式被 import，插件注册处理器 | 性能最好 | 版本耦合、ABI 风险 |

### 5.2 kubectl 插件模式：一个可直接借鉴的协议

**已确认**（Cobra User Guide）：Cobra 支持 kubectl 插件模式——可执行文件命名为 `kubectl-myplugin`，Cobra 会通过 `cobra.CommandDisplayNameAnnotation` 注解把显示名修正为 `kubectl myplugin`。

这个模式的精髓是**零注册表**：插件的可发现性完全由"文件名前缀约定 + PATH 搜索"决定。任何人把二进制放到 PATH 下就能用。

**工程经验**：如果你要给自己的 CLI 做插件体系，优先考虑这种"约定优于配置"的路线：

- 插件可执行文件名带固定前缀（如 `mytool-`）；
- 主程序在 PATH 中扫描匹配前缀的可执行文件；
- 用 `--help` 输出作为插件能力的说明书（约定第一行为一行摘要）；
- 用结构化输出（`--json`）作为契约面；
- 退出码沿用 §3.1 的分层约定。

代价是插件必须与主程序版本协同。**工程经验**：在 `mytool <plugin> --version` 里输出插件版本，主程序调用前先比对，版本不兼容时给出明确错误而不是奇怪行为。

### 5.3 插件与主程序的版本协商

| 机制 | 做法 | 适用 |
| --- | --- | --- |
| 版本区间声明 | 插件声明 `requires >= 1.4, < 2.0` | 通用，推荐 |
| 能力协商 | 主程序问插件"支持哪些能力"，插件返回列表 | 插件需要多版本兼容 |
| 协议版本号 | 插件输出格式带 `apiVersion` | 输出格式会演进时 |

**已确认**（Cobra README）：Cobra 支持 Active Help 框架，可与 shell 补全配合提供更丰富的上下文帮助；文档生成（docgen）支持输出 man page 与 Markdown。

### 5.4 urfave/cli v3 的对照视角

**已确认**（urfave/cli v3 README）：它的定位是 **declarative**、simple、fast；支持命令与子命令的 **alias 与前缀匹配**（prefix match support）；help 系统"flexible and permissive"；动态补全支持 bash/zsh/fish/powershell；**除 Go 标准库外无依赖**；输入类型支持简单类型、简单类型切片、time、duration；**支持复合短选项**（`-a` `-b` `-c` 可缩写为 `-abc`）；文档生成 man 与 Markdown（cli-docs 模块）；输入可来自环境变量、纯文本文件、结构化文件格式（cli-altsrc 模块）；build tag `urfave_cli_no_template` 可关闭 text/template 渲染，输出相同但 help 模板不可定制，文档并警告"if the default help printer is used with a custom template ... it panics"。

**"前缀匹配"与"复合短选项"这两点是可发现性的反向设计**：用户不需要记全名，记个开头就行。与 Cobra 的"拼错提示"是同一问题的两种解法。

## 六、演进：版本、兼容与 Git 属性

### 6.1 工具自身也要遵守仓库卫生

一个容易被忽略的点：CLI 工具的**安装与分发**同样受版本控制规则约束。**已确认**（`gitattributes(5)`，git.git master）：

- 每行格式为 `pattern attr1 attr2 ...`；
- 属性有四态：Set（只写名字）、Unset（前缀 `-`）、Set to a value（`name=value`）、Unspecified；
- **多模式匹配时后面的行覆盖前面的行，且是按属性逐个覆盖**；
- 模式匹配规则同 `.gitignore`，但**禁止负向模式**，且**匹配目录的模式不会递归匹配目录内路径**（要用 `path/**`）；
- 优先级：`$GIT_DIR/info/attributes`（最高）> 路径所在目录的 `.gitattributes` > 各级父目录（离得越远优先级越低）> global / system-wide 文件（最低）；
- `core.attributesFile` 默认 `$XDG_CONFIG_HOME/git/attributes`，否则 `$HOME/.config/git/attributes`；系统级为 `$(prefix)/etc/gitattributes`；
- 用 `!name` 可把属性覆盖为 Unspecified；
- `builtin_*` 是保留命名空间，用户自定义会被忽略并告警；
- 内置属性包括 `text`、`eol`、`working-tree-encoding`、`ident`、`filter`、`diff`、`merge`、`whitespace`、`export-ignore`、`export-subst`、`delta`、`encoding`；
- `text=auto` 时由 Git 自判文本/二进制；`eol` 只在 `text` 或 `text=auto` 下生效，指定 `eol` 会自动设 `text`；若 `text` 已设但两者都没设，Windows 默认 `eol=crlf`、其他平台 `eol=lf`；
- `filter` 驱动缺配置或非零退出**不是错误，而是 no-op passthrough**；只有 `filter.<driver>.required=true` 才声明为必须成功；`clean`/`smudge` 需满足幂等性要求；
- `diff` 设置后即使含 NUL 也视为文本；`-diff` 视为二进制；`diff.<name>.algorithm` 可选 `myers` / `patience` / `minimal` / `histogram`；
- `merge` 内置三种 driver：`text` / `binary` / `union`；
- 宏属性 `binary` 等价于 `[attr]binary -diff -merge -text`，**宏属性只能 Set**；自定义宏属性只能定义在**顶层** `.gitattributes`（子目录的会被忽略）；
- **Git 不跟随符号链接访问 `.gitattributes`**；工作树缺该文件时用 index 中的路径兜底。

### 6.2 把这些用于 CLI 工具的分发

| 场景 | 属性写法 | 效果 |
| --- | --- | --- |
| 统一换行符 | `* text=auto` | 跨平台协作不产生整文件 diff |
| 脚本强制 LF | `*.sh text eol=lf` | 避免 Windows 上脚本无法执行 |
| 二进制不转码 | `*.png -text` | 防止损坏 |
| 发布包排除测试文件 | `tests/ export-ignore` | `git archive` 产物更干净 |
| 版本号注入 | `version.txt export-subst` | 归档时展开 `$Format:%H$` |

**工程经验**：`export-subst` 对 CLI 工具特别有用——可以在构建产物里嵌入 commit hash，用户报障时直接 `app version` 就能定位到具体构建。

### 6.3 CLI 的版本与弃用策略

**工程经验**：一条可执行的弃用流程：

1. 新增行为用新 flag 承载，旧 flag 保留；
2. 旧 flag 被使用时打印 **warning 到 stderr**（不是 stdout，避免污染管道）；
3. 连续两个大版本后再移除，并在 CHANGELOG 与 `--help` 中标注；
4. 提供 `app migrate` 之类的辅助子命令，把旧写法翻译成新写法。

Cobra 的 `Version` 字段会自动加 `--version`，`SetVersionTemplate` 可自定义输出。**工程经验**：版本输出建议包含版本号、commit hash、构建时间、以及 Go/Rust 运行时版本——排查问题时这几项缺一不可。

## 七、端到端检查清单

### 7.1 设计评审门禁

| # | 检查项 | 通过标准 |
| --- | --- | --- |
| 1 | 顶层子命令数 | ≤ 12，超出则分组或归并 |
| 2 | 命名约定 | 全部符合「动作 + 事物 + 修饰语」 |
| 3 | flag 作用域 | 全局项一律 persistent，无重复注册 |
| 4 | 位置参数 | 显式声明 `Args` 校验器，不靠运行时判断 |
| 5 | 必填/互斥/成组 | 用框架 API 声明，不手写 if |
| 6 | 帮助文本 | 每个子命令有 Short，长描述不超 3 段 |
| 7 | 拼错提示 | 距离阈值 ≥ 2，默认不关闭 |
| 8 | shell 补全 | 提供 `completion` 子命令，四种 shell 均可 |
| 9 | 退出码 | 分层区分用法错 / 环境错 / 缺陷错 |
| 10 | 通道分离 | stdout 只有数据，诊断全走 stderr |
| 11 | 机器可读输出 | 有 `--json`，字段稳定 |
| 12 | 配置优先级 | 有明确文档化的覆盖顺序 |
| 13 | 嵌套配置 | 深合并或键级合并，避免整体替换 |
| 14 | 环境变量 | 空值行为明确，空格/大小写策略明确 |
| 15 | 配置热重载 | 所有路径在 WatchConfig 之前声明 |
| 16 | 插件发现 | 约定式，PATH 扫描，无中心注册表 |
| 17 | 插件版本 | 声明兼容区间，不兼容时明确报错 |
| 18 | 并发安全 | 若可作为库使用，不使用全局单例 |
| 19 | 版本输出 | 含版本号 + commit + 构建时间 |
| 20 | 弃用流程 | 有 warning、期限、迁移命令 |

### 7.2 三种演练

| 演练 | 做法 | 期望 |
| --- | --- | --- |
| 冷启动演练 | 找一位没用过该工具的同事，只给一句话任务 | 他能自己找到子命令并成功执行 |
| 脚本演练 | 把工具接进 CI，故意制造失败 | 退出码能被脚本区分并正确决策 |
| 升级演练 | 在旧版本脚本上跑新版本 | 无静默行为变化，有则必有 warning |

### 7.3 常见误区速查

| 误区 | 为什么错 | 正确做法 |
| --- | --- | --- |
| 所有失败都 exit 1 | 脚本无法区分重试与否 | 用退出码分层 |
| 日志打 stdout | 破坏管道消费 | 日志一律 stderr |
| flag 有业务默认值 | 无法区分"未传"与"传了默认值" | 默认值置零，另设 config 默认 |
| 顶层堆几十个命令 | 用户记不住 | 分组 + 别名 + 补全 |
| 配置整体替换 | 改一个字段丢一片 | 键级合并 |
| 库模式下用全局配置单例 | 并发下 panic | 显式实例 + 锁 |
| 插件走中心注册表 | 部署与离线场景失败 | 约定式 PATH 扫描 |
| 破坏性变更直接改语义 | 脚本静默失败 | 新 flag + warning + 期限 |

## 小结

CLI 的设计质量不体现在参数解析有多快，而体现在**用户是否需要猜**。把今天散落在各处的不确定收敛到六个问题上：

- **布局**：动词优先、flag 分作用域、参数契约显式化；
- **可发现性**：帮助分组、拼错提示、shell 补全；
- **契约**：退出码分层、stdout 只放数据、机器可读输出；
- **配置**：优先级文档化、避免整体替换、环境变量规则明确；
- **扩展**：约定式插件发现 + 版本协商；
- **演进**：版本可追溯、弃用有流程、仓库属性干净。

其中最容易做、收益又最大的是两件小事：**给每个子命令写好 `Short`**，以及**把退出码分层并在手册里列出来**。这两件事当天就能做完，而用户能立刻感觉到差别。

最后一条给下一个人：本文所有"已确认"结论都可以在对应的一手来源里复核——Cobra 的 User Guide、Viper 的 README、urfave/cli v3 的 README、clap 的 README、`sysexits.h(3head)`、`gitattributes(5)`。凡是我标为"工程经验"的部分，请按你自己的场景实测再采信。

## 参考资料

1. [Cobra README（spf13/cobra）](https://raw.githubusercontent.com/spf13/cobra/main/README.md)
2. [Cobra User Guide（spf13/cobra）](https://raw.githubusercontent.com/spf13/cobra/main/site/content/user_guide.md)
3. [Viper README（spf13/viper）](https://raw.githubusercontent.com/spf13/viper/master/README.md)
4. [urfave/cli v3 README](https://raw.githubusercontent.com/urfave/cli/main/README.md)
5. [clap README（clap-rs/clap）](https://raw.githubusercontent.com/clap-rs/clap/master/README.md)
6. [sysexits.h(3head) — Linux man-pages 6.20](https://manpages.debian.org/unstable/manpages-dev/sysexits.h.3head.en.html)
7. [gitattributes(5) — git.git 官方文档](https://raw.githubusercontent.com/git/git/master/Documentation/gitattributes.adoc)
