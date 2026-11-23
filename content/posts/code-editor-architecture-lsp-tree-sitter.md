---
title: "代码编辑器架构：LSP、Tree-sitter 与增量解析"
description: "现代编辑器的智能能力建立在两层协议之上：LSP 负责语义级能力与生命周期，Tree-sitter 负责增量语法解析。本文拆解两者的消息模型、能力协商、增量更新算法与工程权衡，给出可落地的编辑器内核设计与验收清单。"
date: 2026-11-23
categories: ["开发者工具"]
tags: ["编辑器", "LSP", "Tree-sitter", "增量解析", "AST"]
---

## 引言：编辑器的智能能力，不是靠一个大模型撑起来的

很多人第一次拆解现代编辑器（VS Code、Neovim、Zed）时会失望：所谓的"智能"，并没有一个统一的大脑在思考。它更像是一堆各自独立、互不信任的子系统，被一个擅长调度的主进程拼在一起。

你在编辑器里敲下一个字符，同时发生了这些事：

- 有人告诉你第 3 行有个类型错误；
- 有人告诉你第 3 行那个变量的类型是 `List[User]`；
- 有人把 `Us` 补全成 `UserService`；
- 有人重新计算了整份文件的高亮色块；
- 有人正在后台为整个工作区建立索引。

这些"有人"，可能来自不同进程、不同语言、不同实现。它们之间唯一的约定，就是两套协议：**LSP（Language Server Protocol）**管语义，**Tree-sitter** 管语法。

本文要回答四个问题：

- LSP 的消息模型到底长什么样？为什么它看起来像 HTTP？
- 能力协商（capabilities）为什么是整套设计的关键，而不是可选装饰？
- 增量解析的算法是什么？为什么"先改树再重解析"这个顺序不能颠倒？
- 一个编辑器内核该怎么把这些拼起来，才能在几百毫秒内给出反馈？

全文区分三类陈述：**已确认**（有官方规范或官方文档支撑的事实，可直接引用），**工程经验**（常见做法，具体数值随场景变化），**待验证**（需要你在自己的项目上实测）。

本文与站内已有的 [开发者命令行工具设计](/posts/cli-tool-design-engineering/) 属于同一个"开发者工具"大类，但层次不同：那篇讲**命令行接口契约**，本文讲**编辑器内部架构**。

## 一、LSP 的消息模型：把 JSON-RPC 装进类 HTTP 的帧

### 1.1 Base Protocol：两层结构

**已确认**（LSP 3.17 规范 Base Protocol 章节）：LSP 的消息在传输层之上还有一层自己的封装，由 **header** 和 **content** 两部分组成：

```
Content-Length: 123\r\n
Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{...}}
```

规则要点：

- header 与 content 之间用 `'\r\n'` 分隔，**header 结束后紧跟两个 `'\r\n'` 序列**，然后才是 content；
- header 的字段结构符合 HTTP 语义；
- 规范只支持两个 header 字段：`Content-Length`（必填，content 的字节长度）与 `Content-Type`（默认值 `application/vscode-jsonrpc; charset=utf-8`）；
- header 用 ASCII 编码；content 的编码由 `Content-Type` 指定的 charset 决定，默认 UTF-8；
- **目前只支持 utf-8**，收到其他编码应当报错返回。为了向后兼容，接收端建议把 `utf8` 也当作 `utf-8`。

为什么不用裸 JSON-RPC？因为流式传输需要解决"这一段 JSON 到哪里结束"的定界问题。复用 HTTP 的心智模型（长度前缀 + 空白行分隔）是最省认知成本的做法。实现上通常用 `\r\n\r\n` 作为 header/content 分界，用 `Content-Length` 找到 content 终点。

### 1.2 四种消息

**已确认**（LSP 3.17 规范消息接口定义）：

| 消息类型 | 必填字段 | 可选字段 | 语义 |
| --- | --- | --- | --- |
| `RequestMessage` | `id: integer\|string`、`method: string` | `params?: array\|object` | 有请求必有响应 |
| `ResponseMessage` | `id: integer\|string\|null` | `result?: LSPAny`、`error?: ResponseError` | 成功与失败二选一 |
| `NotificationMessage` | `method: string` | `params?: array\|object` | **处理完不得回响应** |
| `Message` | `jsonrpc: string` | — | 所有消息的公共父接口 |

一个容易踩的细节：`ResponseMessage` 的 `result` 是可选的，但规范明确要求——**成功但没有返回值时应把 `result` 设为 `null`**。不要省略字段，否则客户端在类型层面就要做"是缺了还是真的是 null"的区分。

另一个细节：`id` 的类型是 `integer | string | null`。`null` 出现在响应里，通常意味着"这是一个对服务器主动发出的通知的回复，但无法关联"——实践中这是错误路径。

### 1.3 错误码：整数契约

**已确认**（LSP 3.17 规范 `ErrorCodes`）：

| 错误码 | 名称 | 含义 |
| --- | --- | --- |
| -32700 | `ParseError` | JSON 解析失败 |
| -32600 | `InvalidRequest` | 请求结构非法 |
| -32601 | `MethodNotFound` | 方法不存在 |
| -32602 | `InvalidParams` | 参数非法 |
| -32603 | `InternalError` | 服务端内部错误 |
| -32002 | `ServerNotInitialized` | 在 initialize 之前收到请求 |
| -32001 | `UnknownErrorCode` | 未知错误 |
| -32803 | `RequestFailed` | 语法正确但执行失败 |
| -32802 | `ServerCancelled` | 服务端主动取消 |
| -32801 | `ContentModified` | 文档内容已被修改 |
| -32800 | `RequestCancelled` | 客户端取消 |

LSP 保留了 JSON-RPC 保留区（-32099 ~ -32000）与 LSP 自有保留区（-32899 ~ -32800）。注意 `RequestFailed (-32803)` 与 `InternalError (-32603)` 的区别：前者是"我理解了你的请求，但做不到"，后者是"我这边出问题了"。

### 1.4 `$/` 前缀：实现相关消息的处理规则

**已确认**：LSP 规定，以 `$/` 开头的方法名是**实现相关的**。规则是：

- 收到 `$/` 开头的 **notification**，客户端与服务端**都可以自由忽略**；
- 收到 `$/` 开头的 **request**，**必须回 `MethodNotFound (-32601)`**。

这条规则的价值在于：它把"我知道这个方法但我不想实现"和"我完全不知道这个方法"在协议层区分开，避免了自定义扩展方法在对方客户端上引发崩溃或静默挂起。

## 二、能力协商：整套设计的枢纽

### 2.1 initialize 是唯一入口

**已确认**（LSP 3.17 规范 `initialize` 请求）：

- initialize 是 client 发给 server 的**第一个请求**；
- 若在 initialize 之前收到**请求**，应回错误 `code: -32002`；
- 若在 initialize 之前收到**通知**，应**丢弃**（`exit` 通知除外）——这样即使没有 initialize，server 也能正常退出；
- **在 server 返回 `InitializeResult` 之前，client 不得再发任何请求或通知**；server 也不得发请求或通知，但 initialize 期间允许发 `window/showMessage`、`window/logMessage`、`telemetry/event` 通知以及 `window/showMessageRequest` 请求；
- 若 client 在 initialize params 里设置了 `workDoneToken`，server **只能**用那个 token 发 `$/progress`；
- **`The initialize request may only be sent once.`**

`InitializeParams` 的字段（已确认）：

```typescript
interface InitializeParams extends WorkDoneProgressParams {
    processId: integer | null;
    clientInfo?: { name: string; version?: string };
    locale?: string;
    rootPath?: string | null;   // @deprecated in favour of rootUri
    rootUri: DocumentUri | null; // @deprecated in favour of workspaceFolders
    initializationOptions?: LSPAny;
    capabilities: ClientCapabilities;
    trace?: TraceValue;
    workspaceFolders?: WorkspaceFolder[] | null;
}
```

两处值得注意的工程细节：

1. **`processId`**：父进程不存在时 server **应当自行退出**。这是防止孤儿语言服务器进程堆积的机制，配合客户端的 `--clientProcessId` 启动参数使用。
2. **`rootPath` 与 `rootUri` 的双重废弃**：规范原文写着 *"If both `rootPath` and `rootUri` are set `rootUri` wins."*，而 `rootUri` 自己又被标注为 `@deprecated in favour of workspaceFolders`。也就是说三代路径写法并存时优先级是 `workspaceFolders` > `rootUri` > `rootPath`。

### 2.2 能力协商的三条语义规则

**已确认**（规范 `ClientCapabilities` 章节原文）：

1. **未知属性应被忽略**（*"Servers receiving a `ClientCapabilities` object literal with unknown properties should ignore these properties."*）——这让协议可以平滑演进；
2. **缺失属性视为不具备该能力**（*"A missing property should be interpreted as an absence of the capability."*）；若缺失的属性本来还包含子属性，则**所有缺失的子属性都视为不具备对应子能力**；
3. **2.x 时代的能力对 client 仍是强制的**（*"Capabilities that existed in the 2.x version of the protocol are still mandatory for clients. Clients cannot opt out of providing them."*）——最典型的就是文本同步：即使 client 没声明 `textDocument.synchronization`，也**依然必须**发送 open / change / close 通知。

第 3 条是理解 LSP 设计哲学的钥匙：**能力协商是"下限之上的增量"，不是"清单之外的一律不做"**。新版本 client 可以依赖老 server 的既有行为，老 server 不需要为新特性做兼容分支。

### 2.3 server 能力是声明，不是承诺

**已确认**：server 在 `InitializeResult` 里声明自己支持哪些能力，client 据此决定"要不要问"。

规范举的例子：server 声明能处理 `textDocument/hover`，并不代表它一定能处理 `workspace/symbol`；client 声明能提供 about-to-save 通知，server 就可以在保存前预先算好格式化编辑。

**工程经验**：能力声明粒度太粗会让客户端"以为有、实际没有"，太细则会让协商报文膨胀。实用折中是——按**请求族**声明（hover / completion / definition / rename / codeAction / semanticTokens），族内不再细分；例外是那些**语义差异大**的能力，必须单独开关（比如 `textDocumentSync.change` 的全量与增量模式、`codeActionProvider.resolveProvider`）。

## 三、文档同步：增量更新的协议侧

### 3.1 三种同步形态

**已确认**（LSP 3.17 规范 Text Document Synchronization）：

- `didOpen` / `didChange` / `didClose` **对 client 是强制支持、不可选择退出**的；
- 同步包含**全量**与**增量**两种模式；
- **server 必须三者全实现，或者全不实现**——不允许只支持 didOpen 不支持 didChange；
- server 侧能力用 `textDocumentSync` 字段声明，类型是 `TextDocumentSyncKind | TextDocumentSyncOptions`。

`TextDocumentSyncKind` 的取值：

| 值 | 名称 | 语义 |
| --- | --- | --- |
| 0 | `None` | 不做同步 |
| 1 | `Full` | 始终发送全量内容 |
| 2 | `Incremental` | 打开时发全量，之后只发增量 |

`TextDocumentSyncOptions` 支持 `openClose?`、`change?`（**省略则默认 `TextDocumentSyncKind.None`**）、`willSave?`、`willSaveWaitUntil?`、`save?`。

注意 `change` 省略时默认是 `None` 而不是 `Full`——这是一个真实的坑：server 只声明 `textDocumentSync: { openClose: true }` 时，规范语义是**不做内容同步**，不是"做全量同步"。

### 3.2 增量变更事件的语义

**已确认**（LSP 3.17 规范 `textDocument/didChange`）：

- 改动前 client 必须先用 `textDocument/didOpen` 取得内容所有权；
- **请求前 client 必须确保文档状态已与服务端同步**，否则结果不可靠；
- `DidChangeTextDocumentParams` 中 `textDocument` 是 `VersionedTextDocumentIdentifier`，其**版本号指向应用了全部 `contentChanges` 之后的状态**；
- `TextDocumentContentChangeEvent` 有两种形态：带 `range: Range` + `text: string`（其中 `rangeLength?: uinteger` **已废弃，改用 range**），或只有 `text: string` 表示整篇新内容。

**最关键的一条**：**同一条 notification 内的多个 change 是顺序叠加的**。如果一条 `didChange` 里带 c1、c2 两个变更事件，那么 c1 把文档从 S 移动到 S'，c2 从 S' 移动到 S''。c1 基于 S 计算，c2 基于 S' 计算。

这与"c1、c2 都基于 S 计算"的直觉完全不同，而增量解析的增量更新算法恰好依赖这个语义——这是下一节 Tree-sitter 部分与 LSP 部分咬合的接口。

### 3.3 顺序：哪些请求可以换序

**已确认**（LSP 3.17 规范消息顺序章节）：响应通常应当与请求顺序大致一致；server 可以并行处理并乱序返回，**前提是不影响正确性**。

规范给的例子很有信息量：

- `textDocument/completion` 与 `textDocument/signatureHelp` **可以换序**——两者都是只读查询，互不影响；
- **`textDocument/definition` 与 `textDocument/rename` 不应换序**——rename 会执行编辑，进而影响 definition 的结果。

**工程经验**：这条规则可以直接落成代码。在编辑器内核里维护一个"会修改文档的请求"集合（rename / codeAction / formatting / refactor），这些请求必须串行且与文档版本绑定；其余只读请求（hover / completion / definition / references）可以并发，甚至可以在同一版本上并行。

## 四、Tree-sitter：增量语法解析

### 4.1 四个核心对象

**已确认**（Tree-sitter 官方文档 Getting Started）：Tree-sitter 的世界里有四个核心对象，在 C API 中分别是：

| 概念 | C 类型 | 职责 |
| --- | --- | --- |
| 语言 | `TSLanguage` | 不透明对象，定义如何解析某语言；由 Tree-sitter 生成的代码提供 |
| 解析器 | `TSParser` | 有状态对象，可指定 `TSLanguage` 并产出 `TSTree` |
| 语法树 | `TSTree` | 整个文件的语法树，包含 `TSNode` 实例；可编辑并产出新树 |
| 语法节点 | `TSNode` | 树中单个节点，记录起止位置及与父/兄弟/子节点的关系 |

各语言的语法定义存放在 `tree-sitter` / `tree-sitter-grammars` 这两个 GitHub 组织下的独立仓库里。

官方给的最小 JSON 示例（可运行）：

```c
#include <tree_sitter/api.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>

int main(void) {
  const char *source_code = "[1, 2, 3]";
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, tree_sitter_json());
  TSTree *tree = ts_parser_parse_string(parser, NULL, source_code, strlen(source_code));
  TSNode root_node = ts_tree_root_node(tree);
  TSNode array_node = ts_node_named_child(root_node, 0);
  TSNode number_node = ts_node_named_child(array_node, 0);
  char *string = ts_node_string(root_node);
  assert(strcmp(ts_node_type(root_node), "document") == 0);
  assert(strcmp(ts_node_type(array_node), "array") == 0);
  assert(strcmp(ts_node_type(number_node), "number") == 0);
  assert(ts_node_child_count(root_node) == 1);
  assert(ts_node_child_count(array_node) == 5);
  assert(ts_node_named_child_count(array_node) == 2);
  assert(ts_node_child_count(number_node) == 0);
  free(string);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}
```

编译命令（POSIX，官方文档给出）：

```bash
clang -I tree-sitter/lib/include test-json-parser.c \
  tree-sitter-json/src/parser.c tree-sitter/libtree-sitter.a -o test-json-parser
```

动态链接则改用 `-ltree-sitter`，并确保 `LD_LIBRARY_PATH` 能找到库。

### 4.2 concrete syntax tree 与 named/anonymous

**已确认**（Tree-sitter 官方文档 Basic Parsing）：Tree-sitter 产出的是 **concrete syntax tree**——它包含每一个 token，包括逗号、括号这些语法上并不承载语义的符号。这正是语法高亮所需要的形态：编辑器需要知道每一个字符属于哪个 token。

同时，Tree-sitter 区分 named 节点与 anonymous 节点，以支持 AST 式的语义分析。

拿官方例子说明。语法规则：

```javascript
if_statement: $ => seq("if", "(", $._expression, ")", $._statement);
```

`if_statement` 节点有 5 个子节点：

- `if`、`(`、`)` 是 **anonymous**——在语法里写成字符串字面量；
- 表达式与语句是 **named**——在语法里用 `$._name` 或 `$name` 显式命名。

对应的 C API：

```c
bool ts_node_is_named(TSNode);
TSNode ts_node_named_child(TSNode, uint32_t);
uint32_t ts_node_named_child_count(TSNode);
TSNode ts_node_next_named_sibling(TSNode);
TSNode ts_node_prev_named_sibling(TSNode);
```

**工程经验**：做语义分析（比如重命名一个符号、查找引用）时，一律走 `named` 系列 API；做高亮、括号匹配、缩进时，走完整的 `child` 系列 API。把这两类遍历混用，是 Tree-sitter 使用中最常见的一类 bug 来源。

### 4.3 位置：字节偏移与行列

**已确认**（Tree-sitter 官方文档 Basic Parsing）：

- 位置信息**同时以原始字节偏移与行列坐标存储**；
- **行列均为 0-based**；
- `row` = 该位置之前换行符的个数；
- `column` = 与行首之间的**字节数**（不是字符数）；
- `ts_node_start_byte` / `ts_node_end_byte`、`ts_node_start_point` / `ts_node_end_point`；
- **换行只按单个 `\n` 计数**（CRLF 文件里 `\r` 算作行内字符）。

```c
typedef struct { uint32_t row; uint32_t column; } TSPoint;
```

"column 是字节数"这一点在中文、日文、emoji 场景里必须注意：LSP 的 `Position` 用的是 **UTF-16 code unit** 偏移，而 Tree-sitter 用的是**字节**偏移。这两者之间需要一层转换，而转换本身就是增量解析里最容易出 bug 的地方。

### 4.4 增量解析：先编辑树，再带旧树重解析

**已确认**（Tree-sitter 官方文档 Advanced Parsing）：增量解析是**两步**，顺序不可颠倒。

第一步，向旧树描述一次编辑：

```c
typedef struct {
    uint32_t start_byte;
    uint32_t old_end_byte;
    uint32_t new_end_byte;
    TSPoint start_point;
    TSPoint old_end_point;
    TSPoint new_end_point;
} TSInputEdit;

void ts_tree_edit(TSTree *self, const TSInputEdit *edit);
```

第二步，把**编辑过的旧树**作为 `old_tree` 传给解析器：

```c
TSTree *ts_parser_parse_string(TSParser *self, const TSTree *old_tree,
                               const char *string, uint32_t length);
```

规范明确：**新树内部与旧树共享结构**。未被编辑波及的子树直接复用，不重新解析。这就是增量的全部收益来源。

还有一个容易漏掉的细节：**如果在树外保存了 `TSNode` 实例**（例如你在一个数据结构里缓存了"当前光标所在节点"），编辑之后必须用**同一个** `TSInputEdit` 调用：

```c
void ts_node_edit(TSNode *self, const TSInputEdit *edit);
```

来单独更新它缓存的位置。规范原文的限定是：只在"编辑前取过节点、编辑后想继续用同一实例"时才需要；**若从编辑后的树重新取节点则不需要**。

### 4.5 与 LSP 的咬合点

把 3.2 与 4.4 两节拼起来，增量链路就完整了：

```
client 输入一个字符
  → 生成一条 didChange notification（含 1 个或多个 TextDocumentContentChangeEvent）
  → server 按顺序应用这些 event，得到新的文本与新的文档版本
  → 把每个 event 的 range/length 翻译成 TSInputEdit（字节偏移 + 行列）
  → ts_tree_edit(旧树, edit)
  → ts_parser_parse_string(parser, 编辑过的旧树, 新文本, 新长度)
  → 得到新树
```

关键在于**同一条 notification 里的多个 change 是顺序叠加的**：每个 change 的 range 都是相对"前一个 change 应用之后"的状态。所以翻译成 `TSInputEdit` 时，**每个 edit 的 `old_end_byte` 都要基于前一个 edit 应用后的坐标来计算**。直接把 LSP 的 range 直接当作 TSInputEdit 是错的——两套坐标系不同（UTF-16 单元 vs 字节），叠加语义也不同。

### 4.6 树游标：遍历大量节点的最快方式

**已确认**（Tree-sitter 官方文档 Walking Trees）：当需要访问大量节点时，**树游标（tree cursor）是最快的方式**。

```c
TSTreeCursor ts_tree_cursor_new(TSNode);
bool ts_tree_cursor_goto_first_child(TSTreeCursor *self);
bool ts_tree_cursor_goto_next_sibling(TSTreeCursor *self);
bool ts_tree_cursor_goto_parent(TSTreeCursor *self);
TSNode ts_tree_cursor_current_node(const TSTreeCursor *self);
const char *ts_tree_cursor_current_field_name(const TSTreeCursor *self);
TSFieldId ts_tree_cursor_current_field_id(const TSTreeCursor *self);
```

三个 `goto_*` 在无法前进时返回 `false`，不会崩，但也不会自动结束遍历——必须由调用方根据返回值决定是否继续。

**关键限制**：传入的节点被视作**游标的根**，游标不能走出该节点。走到父节点或兄弟节点会恒返回 `false`。所以当你只关心一棵子树时，用那棵子树的根节点构造游标，遍历结束后不需要再手动回退。

## 五、Tree-sitter Queries：把匹配逻辑从代码里挪出来

Tree-sitter 的 Query 机制允许把"要匹配什么"用 S-expression 写出来，而不是写一段遍历代码。这是把规则交给用户的编辑器的关键——高亮规则、代码折叠边界、注释提取，都可以做成可热更新的查询文件。

### 5.1 模式语法

**已确认**（Tree-sitter 官方文档 Queries 章节）：

- 一个 query 由**一个或多个 pattern** 组成，每个 pattern 是一个 S-expression；
- 基本形态 `(node_type (child) ...)`。例如 `(binary_expression (number_literal) (number_literal))` 匹配"两个子节点都是数字字面量的二元表达式"；
- 子节点可以省略：`(binary_expression (string_literal))` 匹配"含至少一个字符串字面量子节点的二元表达式"。

四种修饰手段：

| 语法 | 含义 | 示例 |
| --- | --- | --- |
| `field: (child)` | 按字段名匹配 | `name: (identifier) @class_name` |
| `!field` | 父节点**缺少**该字段 | `(class_declaration name: (identifier) @n !type_parameters)` |
| `"literal"` | 匹配匿名节点 | `(binary_expression operator: "!=" right: (null))` |
| `_` / `(_)` | 任意节点 / 仅 named 节点 | `(_)` 只匹配 named |

两个特殊节点类型：

- **`(ERROR)`**：解析器遇到无法识别的文本时产生。它是一个可以被正常查询的节点类型，例如 `(ERROR) @error-node`。这是编辑器做"语法错误可视化"的基础。
- **`(MISSING)`**：解析器通过"插入缺失 token"完成恢复时产生的节点，**宽度为 0**。它在内部表示为实际终结节点的属性，而不是独立的节点类型。所以查询写法有 `(MISSING)`、`(MISSING identifier)`、`(MISSING ";")` 等变体。

**supertype** 机制允许按"父类型"匹配任意子类型：

```
(expression) @any-expression        ; 匹配任何表达式
(expression/binary_expression)      ; 限定为二元表达式子类型
(expression/"()")                   ; 匿名节点同理
```

### 5.2 captures、量词、alternation、anchor

**已确认**：

- **capture**：用 `@name` 写在节点之后。`(assignment_expression left: (identifier) @the-function-name right: (function))`；
- **量词**：`+`（一个或多个）、`*`（零个或多个）、`?`（可选）。例如 `(comment)+`、`(decorator)* @the-decorator`；
- **分组**：括号可以分组兄弟节点序列，如 `((number) ("," (number))*)`；
- **alternation**：`[...]` 列出备选，类似正则字符类，如 `[ (identifier) @function (member_expression property: (property_identifier) @method) ]`。

官方特意演示了 alternation 与量词组合的三种不同语义，这段很值得记住：

| 写法 | 结果 |
| --- | --- |
| `[(preproc_include) (comment)]+ @capture` | **一个 match，四个 capture** |
| `[(preproc_include)+ (comment)] @capture` | **两个 match**（分别 3 个和 1 个 capture） |
| `[(preproc_include) (comment)] @capture` | **四个 match，每个一个 capture** |

差别在于量词作用在 alternation 的哪一层：写 `A+` 是"连续匹配多个 A"，而 `[A B]+` 是"连续匹配多个 A 或 B"。

**anchor（`.`）** 有三种位置语义：

- 放在父 pattern 的**第一个**子节点前 → 只匹配父节点的第一个 named 子节点；
- 放在**最后一个**子节点后 → 只匹配最后一个 named 子节点；
- 放在**两个**子 pattern 之间 → 只匹配**紧邻**的兄弟节点。

例如 `a.b.c.d` 这种 anchor 写法，只匹配 a,b / b,c / c,d 三对相邻关系，不匹配 a,c 这样的跨位匹配。**anchor 约束忽略 anonymous 节点**。

两条边界规则：anchor **不能**出现在 group `(...)` 或 alternation `[...]` 的首末位置。

### 5.3 predicates 与 directives

**已确认**：谓词（predicates）以 `#` 开头、`?` 结尾；指令（directives）以 `#` 开头、`!` 结尾。

| 名称 | 作用 |
| --- | --- |
| `#eq?` / `#not-eq?` | 比较两个 capture 的文本，或 capture 与字面量 |
| `#any-eq?` / `#any-not-eq?` | 同上，但只要量词捕获的节点中**任一**满足即匹配 |
| `#match?` / `#not-match?` / `#any-match?` | 用正则匹配 capture 文本，如 `"^[A-Z][A-Z_]+"` |
| `#any-of?` | capture 文本等于列表中任一字符串 |
| `#is?` / `#is-not?` | 断言 capture 具备某属性 |
| `#set!` | 关联任意键值 |
| `#select-adjacent!` | 只保留与另一 capture 相邻的节点文本 |
| `#strip!` | 用正则从 capture 文本中删除内容 |

默认的量词 capture 只在**所有**被捕获节点都满足谓词时才匹配；加 `any-` 前缀则任一满足即匹配。官方示例：

```
((comment)+ @comment.empty (#any-eq? @comment.empty "//"))
```

**重要边界**：规范明确指出，predicates 与 directives **不由 C 库直接处理**，只是以结构化形式暴露给上层代码做过滤。也就是说，写 C 扩展时你必须自己实现谓词求值；Rust crate 与 WebAssembly binding 实现了其中一部分常用谓词。

### 5.4 Query API 与线程安全

**已确认**：

```c
TSQuery *ts_query_new(const TSLanguage *language, const char *source,
                       uint32_t source_len, uint32_t *error_offset,
                       TSQueryError *error_type);
```

`TSQueryError` 枚举：`TSQueryErrorNone = 0`、`TSQueryErrorSyntax`、`TSQueryErrorNodeType`、`TSQueryErrorField`、`TSQueryErrorCapture`。

线程安全方面：

- **`TSQuery` 不可变，可安全跨线程共享**；
- **`TSQueryCursor` 不应跨线程共享，但可复用于多次查询**。

```c
TSQueryCursor *ts_query_cursor_new(void);
void ts_query_cursor_exec(TSQueryCursor *self, const TSQuery *query, TSNode node);
bool ts_query_cursor_next_match(TSQueryCursor *self, TSQueryMatch *match);
```

`ts_query_cursor_next_match` 返回 `false` 表示没有更多匹配。匹配结构：

```c
typedef struct { TSNode node; uint32_t index; } TSQueryCapture;
typedef struct {
    uint32_t id;
    uint16_t pattern_index;
    uint16_t capture_count;
    const TSQueryCapture *captures;
} TSQueryMatch;
```

范围限制有两组，语义不同：

- `ts_query_cursor_set_byte_range` / `ts_query_cursor_set_point_range`：返回与范围**相交**的匹配（部分重叠也返回）；
- `ts_query_cursor_set_containing_byte_range` / `ts_query_cursor_set_containing_point_range`：只返回**所有 capture 都完全落在**范围内的匹配。

**注意**：范围参数的 end 值为 `0` 表示**无界**，所以 `(0, 0)` 匹配的是整棵树，而不是空范围。

## 六、语义高亮：增量友好的数值编码

语义高亮（semantic highlighting）比语法高亮更进一步：它知道这个标识符是类、是函数、是参数。LSP 3.16 起提供了 `textDocument/semanticTokens` 请求。

### 6.1 token 类型与修饰符

**已确认**（LSP 3.17 规范 `SemanticTokenTypes` / `SemanticTokenModifiers`）：一个语义 token 由**一个 token type 加 n 个 token modifier**组成。协议定义了一组标准值，但**允许 client 扩展并通过 capability 声明**。

`SemanticTokenTypes` 共 22 个（`decorator` 是 3.17.0 新增）：

```
namespace, type, class, enum, interface, struct, typeParameter, parameter,
variable, property, enumMember, event, function, method, macro, keyword,
modifier, comment, string, number, regexp, operator, decorator
```

`SemanticTokenModifiers` 共 10 个：

```
declaration, definition, readonly, static, deprecated, abstract, async,
modification, documentation, defaultLibrary
```

### 6.2 legend 与整数编码

**已确认**：capability 层的类型和修饰符用字符串表达，但实际编码用数字。server 用 legend 告诉 client 数字的含义：

```typescript
export interface SemanticTokensLegend {
    tokenTypes: string[];
    tokenModifiers: string[];
}
```

- **token type 按下标查表**：`tokenType` 值 `1` 表示 `tokenTypes[1]`；
- **token modifier 用位标志**：`tokenModifiers` 值 `3` 视为二进制 `0b00000011`，表示同时有 `tokenModifiers[0]` 与 `tokenModifiers[1]`；
- 规范要求 `tokenType < 65536`。

协议定义了 `relative` 格式（`TokenFormat.Relative = 'relative'`），理由是**编辑文件时大多数 token 相互之间保持稳定**，相对位置便于计算增量。

每个 token 用 **5 个整数**表示：

| 索引 | 字段 | 含义 |
| --- | --- | --- |
| `5*i` | `deltaLine` | 相对前一个 token 的行号 |
| `5*i+1` | `deltaStart` | 相对行首或同行前一个 token 起点的偏移 |
| `5*i+2` | `length` | token 长度 |
| `5*i+3` | `tokenType` | 查 `legend.tokenTypes` |
| `5*i+4` | `tokenModifiers` | 位标志，查 `legend.tokenModifiers` |

### 6.3 官方的完整编码示例

**已确认**（规范示例逐字核对）：假设一个文件里有 3 个 token，初始绝对位置是：

```typescript
{ line: 2, startChar:  5, length: 3, tokenType: "property", tokenModifiers: ["private", "static"] },
{ line: 2, startChar: 10, length: 4, tokenType: "type",       tokenModifiers: [] },
{ line: 5, startChar:  2, length: 7, tokenType: "class",      tokenModifiers: [] }
```

legend 为：

```typescript
{ tokenTypes: ['property', 'type', 'class'], tokenModifiers: ['private', 'static'] }
```

第一步，按 legend 把类型与修饰符整数化：

```typescript
{ line: 2, startChar:  5, length: 3, tokenType: 0, tokenModifiers: 3 },
{ line: 2, startChar: 10, length: 4, tokenType: 1, tokenModifiers: 0 },
{ line: 5, startChar:  2, length: 7, tokenType: 2, tokenModifiers: 0 }
```

第二步，转成相对位置（同行则相对前一个 token 起点，换行则相对行首）：

```typescript
{ deltaLine: 2, deltaStartChar: 5, length: 3, tokenType: 0, tokenModifiers: 3 },
{ deltaLine: 0, deltaStartChar: 5, length: 4, tokenType: 1, tokenModifiers: 0 },
{ deltaLine: 3, deltaStartChar: 2, length: 7, tokenType: 2, tokenModifiers: 0 }
```

第三步，扁平化成一个数组：

```typescript
// 1st token,  2nd token,  3rd token
[ 2,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0 ]
```

现在假设用户在文件开头敲了一个空行，token 的绝对行号整体后移一行。同样变换后得到：

```typescript
[ 3,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0 ]
```

**只有第一个数字变了**。这个差量可以用一条"文本编辑"来表达：

```typescript
{ start: 0, deleteCount: 1, data: [3] }
```

含义是"把数组第一个数字（`2`）替换成 `3`"。规范原文的类比是：*"This is comparable to the text document edits sent from the server to the client to modify the content of a file."*

### 6.4 语义 token 编辑的应用顺序

**已确认**：语义 token 编辑的行为**与文档 text edits 一致**：

- 若一条编辑描述含 n 个 edit，**全部 edit 都基于同一个状态 Sm**；
- 客户端**不得假设** edit 已排序；
- 推荐的简单算法是**先排序，再从数组尾部向前应用**。

这条规则同时出现在语义 token 编辑与文档编辑两处，是一条通用的编辑应用约定。

### 6.5 client 能力与降级

**已确认**：client 通过 `textDocument.semanticTokens` 声明能力，其中两项直接决定行为：

- `multilineTokenSupport`：是否支持跨行 token。**不支持时，若 token 长度越过行尾，就按行尾截断，不换行到下一行**；
- `overlappingTokenSupport`：token 是否允许相互重叠。

规范还给了一个提醒（值得原样记住，因为它是真实事故的高发点）：*"clients might not show semantic tokens or degrade some of the user experience if a range or full request is advertised by the client but not provided by the server."*——client 声明了 `requests.full` 与 `requests.range`，server 却只提供其中一个，就会出现小地图不渲染甚至完全不显示语义高亮的退化。

## 七、诊断：push 与 pull 两种模型

### 7.1 push 模型的所有权规则

**已确认**（LSP 3.17 规范 `textDocument/publishDiagnostics`）：

- 诊断**归 server 所有**，由 server 负责清除；
- 规范给出的 VS Code 约定：**单文件语言**（如 HTML）在文件关闭时清除诊断；**有项目系统的语言**（如 C#）在文件关闭时不清除，打开项目时全部重算或读缓存；
- 规范特别提醒：**open/close 是所有权事件**，不一定反映用户在界面上看得到什么；
- 文件变化时 server 负责重算并推送；**计算结果为空也必须推送空数组以清除旧诊断**；
- **新推送的诊断完全替换旧诊断，client 侧不做任何合并**。

最后两条是"诊断残留"类 bug 的根因：server 以为"没错误就不用发"，client 却保留了上一次的错误标记。

### 7.2 pull 模型：3.17 引入

**已确认**（LSP 3.17 规范 `textDocument/diagnostic`，since 3.17.0）：规范解释了为什么需要 pull 模型——push 模型允许 server 自行决定 workspace 级诊断的计算时机，但**server 无法优先计算用户正在输入或可见文件的诊断**；而从 `didOpen` / `didChange` 推断客户端 UI 状态会产生误判，因为这两个通知是**所有权转移通知**。

pull 模型把决定权交给 client：对哪些文档、何时计算诊断。

server 侧配置：

```typescript
export interface DiagnosticOptions extends WorkDoneProgressOptions {
    identifier?: string;
    interFileDependencies: boolean;
    workspaceDiagnostics: boolean;
}
```

`interFileDependencies` 值得注意，规范原话：*"Inter file dependencies are common for most programming languages and typically uncommon for linters."*——编程语言通常有跨文件依赖（改 A 文件会影响 B 文件的诊断集），而 lint 类工具通常没有。client 可以据此决定拉取策略。

## 八、补全与代码动作：两个高频交互

### 8.1 补全的增量触发

**已确认**（LSP 3.17 规范 `textDocument/completion`）：规范原文要求 *"for speed clients should be able to filter an already received completion list if the user continues typing. Servers can opt out of this using a `CompletionList` and mark it as `isIncomplete`."*

`CompletionTriggerKind` 的三个取值：

| 值 | 名称 | 触发方式 |
| --- | --- | --- |
| 1 | `Invoked` | 输入标识符、手动触发（如 Ctrl+Space）或 API 触发 |
| 2 | `TriggerCharacter` | 由注册时声明的 `triggerCharacters` 触发 |
| 3 | `TriggerForIncompleteCompletions` | **当前列表不完整时重新触发**（since 3.6.0） |

`CompletionContext` 里 `triggerCharacter` **仅在 `triggerKind === TriggerCharacter` 时才有值**。

响应类型是 `CompletionItem[] | CompletionList | null`；返回 `CompletionItem[]` 等价于 `{ isIncomplete: false, items }`。规范还支持分块返回：先 `CompletionItem[]` 或 `CompletionList`，后续 `CompletionItem[]`；若首块是 `CompletionList`，后续块会追加到它的 `items` 里。

**工程经验**：补全服务最容易出的问题是"每次击键都全量重算"。正确做法是区分 `Invoked` 与 `TriggerCharacter`：前者做全量计算，后者往往只是追加触发字符后的少量候选。

### 8.2 代码动作：命令归 server 管

**已确认**（LSP 3.17 规范 `textDocument/codeAction`）：code action 请求返回一组 `Command`，供 UI 展示。规范强调：*"To ensure that a server is useful in many clients the commands specified in a code actions should be handled by the server and not by the client"*——命令应当由 server 处理（配合 `workspace/executeCommand` 与 `ServerCapabilities.executeCommandProvider`）；若 client 支持随 code action 提供 edits，应优先用该模式。

`CodeActionKind` 的完整取值：

```
Empty                    = ''
QuickFix                 = 'quickfix'
Refactor                 = 'refactor'
RefactorExtract          = 'refactor.extract'
RefactorInline           = 'refactor.inline'
RefactorRewrite          = 'refactor.rewrite'
Source                   = 'source'
SourceOrganizeImports    = 'source.organizeImports'
SourceFixAll             = 'source.fixAll'   // since 3.17.0
```

`source.fixAll` 的官方定义里有一条安全边界值得单独记住：*"'Fix all' actions automatically fix errors that have a clear fix that do not require user input. They should not suppress errors or perform unsafe fixes such as generating new types or classes."*——**自动修复不应压制错误，也不应做生成新类型/新类这类不安全修复**。

since 3.16.0 起，client 可以通过 `codeAction.resolveSupport` 声明哪些属性允许延迟解析，让 server 把昂贵的属性（比如 `edit`）推迟到 `codeAction/resolve` 请求再计算。这是把"点开菜单才需要"的成本挪出主路径的标准做法。

## 九、把两套协议拼起来：一个编辑器内核的骨架

现在把前面八节拼成一条完整链路。这一节是**工程经验**，不是规范原文。

### 9.1 三层分工

| 层 | 负责 | 组件 |
| --- | --- | --- |
| 传输层 | 消息编解码、进程管理、连接复用 | LSP Base Protocol 帧、stdio/socket 管道 |
| 语义层 | 跨语言的能力（hover、补全、跳转、重命名、诊断） | Language Server 进程 |
| 语法层 | 单文件的语法结构与高亮 | Tree-sitter parser（常驻在编辑器进程内） |

**为什么要把 Tree-sitter 放在编辑器进程内而不是做成 language server**：Tree-sitter 的单次解析是微秒级的，同进程调用避免了跨进程往返；而且高亮必须覆盖所有文件，包括没有 language server 的语言。

### 9.2 事件驱动的更新链路

```
用户输入
  ├─> 立刻更新本地缓冲（不等 server）
  ├─> Tree-sitter: ts_tree_edit + ts_parser_parse（增量）
  │     └─> 重算高亮 / 折叠 / 语法错误标记
  ├─> 若开启了 semanticTokens 能力：向 server 请求语义 token 差量
  └─> 发 didChange notification 给所有相关 server
        └─> server 异步回 publishDiagnostics / completion / hover
```

关键设计点：**语法更新同步，语义更新异步**。用户按键时，光标高亮必须立即响应；而 hover 提示、类型信息可以晚几十毫秒。

### 9.3 版本号与失效

**已确认**的规范约束（来自 3.1、3.2、3.3 节）：

- 文档版本号指向**应用了全部 contentChanges 之后**的状态；
- 请求前 client 必须确保文档状态已与服务端同步；
- `textDocument/definition` 与 `textDocument/rename` 不应换序；
- server 检测到文档被非常规修改时可用 `ContentModified (-32801)` 报错。

**工程经验**：在编辑器侧维护一张 "请求 → 发起时的文档版本" 表，收到响应时若版本已变，直接丢弃结果（对只读查询）或触发重发（对用户显式触发的查询）。这比依赖 server 端检测更可靠，因为 server 可能不做版本检查。

### 9.4 取消与重启

**已确认**：

- 取消用 `$/cancelRequest` notification，带 `CancelParams { id }`；
- **被取消的请求仍必须返回响应，不能悬挂**；取消时建议错误码用 `RequestCancelled (-32800)`；
- client 发现 server 意外退出应尝试重启，但**不应无限重启**。规范举例：*"VS Code, for example, doesn't restart a server which has crashed 5 times in the last 180 seconds."*

**工程经验**：把"5 次 / 180 秒"这种阈值做成配置项，并配一个退避策略（指数退避 + 上限），同时在 UI 上给出明确提示——静默不重启会让用户以为功能坏了。

### 9.5 一个 server 一个工具

**已确认**：LSP 协议假设**一个 server 服务一个工具**，目前没有在协议层支持把同一个 server 共享给不同工具（需要额外的协议，如文档加锁）。

**工程经验**：如果你的编辑器支持多窗口 / 多工作区，不要试图让一个 language server 同时服务多个窗口——按"工作区 + 语言"拆分 server 进程，虽然进程数多，但隔离性和可调试性都更好。

## 十、清单：验收一个编辑器内核

### 10.1 协议层门禁（12 项）

| # | 检查项 | 依据 |
| --- | --- | --- |
| 1 | Base Protocol 帧解析正确处理 `\r\n\r\n` 与 `Content-Length` | LSP 3.17 Base Protocol |
| 2 | 非 utf-8 编码的 content 被拒绝并报错 | 同上 |
| 3 | 收到 `$/` request 时回 `MethodNotFound (-32601)` | 同上 |
| 4 | 收到 `$/` notification 时可安全忽略 | 同上 |
| 5 | notification 处理后不返回任何响应 | 同上 |
| 6 | 成功且无返回值时 `result` 设为 `null` 而非省略 | 同上 |
| 7 | initialize 之前收到请求回 `-32002` | LSP 3.17 initialize |
| 8 | initialize 响应前 client 不发其他请求 | 同上 |
| 9 | 未知 capability 属性被忽略、缺失属性视为无能力 | 同上 |
| 10 | 同步能力三事件要么全支持要么全不支持 | Text Document Sync |
| 11 | `textDocumentSync.change` 省略时按 `None` 而非 `Full` 处理 | 同上 |
| 12 | 被取消的请求仍返回 `RequestCancelled (-32800)` 响应 | Cancellation |

### 10.2 增量解析门禁（8 项）

| # | 检查项 | 依据 |
| --- | --- | --- |
| 1 | 每次编辑都调用 `ts_tree_edit`，再带旧树重解析 | Tree-sitter Advanced Parsing |
| 2 | 树外缓存的 `TSNode` 用同一 `TSInputEdit` 调 `ts_node_edit` | 同上 |
| 3 | 多 change 的 notification 按顺序叠加坐标换算 | LSP didChange |
| 4 | LSP 位置（UTF-16 单元）与 Tree-sitter 位置（字节）有显式转换层 | 两者坐标系不同 |
| 5 | 语义分析只走 named 系列 API | Tree-sitter Basic Parsing |
| 6 | 树游标不回溯到传入根节点之外 | Walking Trees |
| 7 | `ts_tree_copy` 用于跨线程共享同一棵树 | Advanced Parsing（`TSTree` 实例非线程安全） |
| 8 | `TSQuery` 可跨线程共享，`TSQueryCursor` 不跨线程 | Queries API |

### 10.3 性能门禁（6 项）

| # | 指标 | 建议 |
| --- | --- | --- |
| 1 | 单次击键到高亮更新的耗时 | p50 < 16ms，p99 < 50ms（工程经验） |
| 2 | 大文件（1 万行）增量解析耗时 | < 10ms（工程经验） |
| 3 | 语言服务器往返延迟 | 展示类查询可容忍 100ms，交互式补全 < 50ms |
| 4 | 语义 token 增量请求的响应体大小 | 仅为差量 |
| 5 | server 崩溃重启的退避上限 | 有限次 + 指数退避 |
| 6 | 诊断清空 | 空结果也必须推送空数组 |

### 10.4 常见误区速查（8 条）

| 误区 | 正确做法 |
| --- | --- |
| 把 LSP 当成"一次请求一次响应"的 RPC | 它是双向的，server 可以主动推诊断、进度、日志 |
| 假设 LSP 会自动重发失败请求 | 协议不定义重试语义，重试是应用层责任 |
| 把 Tree-sitter 的 column 当字符数 | 它是字节数 |
| 把 LSP 的 UTF-16 偏移直接当字节偏移用 | 必须显式转换 |
| 用 `ts_node_child` 做语义分析 | 语义分析用 named 系列 API |
| 诊断变空就不推送 | 必须推送空数组以清除旧诊断 |
| server 崩溃就无限重启 | 限次 + 退避 + 用户可见提示 |
| 只声明 `requests.full` 却只实现 range | 会导致小地图与语义高亮退化 |

## 小结

把两套协议摊开看，编辑器的架构其实相当克制：

**LSP 提供的是契约，不是实现。** 它的核心是一套消息模型（header + content 的类 HTTP 帧）、四种消息类型、一组整数错误码，以及一套"能力协商 + 未知即忽略 + 缺失即无能力"的演进规则。3.x 的能力全部可选，2.x 的能力全部强制——这条分界线让协议可以在不破坏老实现的前提下持续扩展。

**Tree-sitter 提供的是算法，不是语义。** 它把"语法"定义成可生成的解析表，把"树"定义成可增量编辑的数据结构。增量解析的关键只有一句话：**先编辑旧树，再带旧树重解析**；未受影响的子树直接复用。至于"这个标识符是什么含义"，那不是它的职责。

**中间那层是你自己的事。** 把语义查询走 LSP、把语法查询走 Tree-sitter，编辑器内核负责的其实是三件事：事件编排（谁在什么时机被触发）、版本与失效（结果回来时文档是否已经变了）、以及坐标系转换（LSP 的 UTF-16 单元与 Tree-sitter 的字节偏移）。这三件事做对了，剩下的都是协议细节；做错了，性能和正确性都会以一种很难排查的方式出问题。

## 参考资料

1. [Language Server Protocol 3.17 规范](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/specification.md) —— 协议全文，含 Base Protocol、错误码、能力协商、同步模型
2. [LSP 3.17 `initialize` 请求](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/general/initialize.md) —— 生命周期与 InitializeParams 字段
3. [LSP 3.17 `textDocument/semanticTokens`](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/semanticTokens.md) —— token 编码与增量编辑规则
4. [LSP 3.17 `textDocument/publishDiagnostics` 与 pull 模型](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/pullDiagnostics.md) —— 诊断所有权与跨文件依赖
5. [Tree-sitter 官方文档：Getting Started](https://tree-sitter.github.io/tree-sitter/using-parsers/1-getting-started.html) —— 核心对象与可运行的 C 示例
6. [Tree-sitter 官方文档：Basic Parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html) —— 节点遍历、named/anonymous、位置语义
7. [Tree-sitter 官方文档：Advanced Parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html) —— 增量解析、多语言区间、树复制
8. [Tree-sitter 官方文档：Walking Trees](https://tree-sitter.github.io/tree-sitter/using-parsers/4-walking-trees.html) —— 树游标
9. [Tree-sitter 官方文档：Queries](https://tree-sitter.github.io/tree-sitter/using-parsers/queries/index.html) —— 查询语法、captures、predicates 与 Query API
