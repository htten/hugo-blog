---
title: "Git 内部原理：对象模型、引用与并发控制"
description: "Git 不是版本控制系统里的玄学。本文拆开它的四层数据模型：不可变对象、内容寻址的哈希、树与提交的引用结构、可达性与 reflog 的生死规则，再讲清 pack 与 delta 的磁盘表示、index 的真实格式、以及 update-ref 事务、gc 剪枝与 worktree 这三处并发控制的边界，给出一份排查与设计清单。"
date: 2026-11-24
categories: ["开发者工具"]
tags: ["Git", "对象模型", "引用", "并发控制"]
---

## 引言：Git 的行为可以推演出来

用 Git 时，很多故障被当成「玄学」：

- `git commit` 之后 `git reflog` 里出现两条记录，`git push` 说 nothing to commit，但远端确实变了；
- 有人执行 `git gc` 之后，某个「之前还在」的 commit 突然 `fatal: bad object`；
- 同一台 CI 机器上两个 job 同时 push，一个成功一个失败，失败的那个报 `cannot lock ref`；
- `git gc` 和 `git push` 同时跑，仓库偶尔损坏。

这些现象看似无规律，其实全部可以从四个事实推演出来：

1. **对象不可变**。Git 存储的每个对象一旦创建就永不修改，内容变了就是新对象。
2. **对象由内容寻址**。对象的 ID 是它内容的哈希，所以「相同内容必然相同 ID」，反过来「相同 ID 必然相同内容」。
3. **引用是可达性的根**。对象本身不知道自己是死是活，活不活取决于能不能从某个 ref 或 reflog 顺着链走回来。
4. **写操作要拿锁**。凡是会修改共享状态的命令（更新 ref、gc、repack）都要通过锁文件或原子改名来避免并发撕裂。

本文按这个顺序展开：先讲对象模型（commit / tree / blob / tag 的字节级结构），再讲引用与可达性（谁决定生死），然后讲磁盘表示（pack、delta、index 格式），最后讲并发控制（锁、事务、gc 的竞态）以及一份排查清单。

全文区分三类陈述：**已确认**（有 Git 官方文档直接支撑）、**工程经验**（社区常见做法，随版本与场景变化）、**待验证**（需要你在自己的仓库上测）。本文的事实依据以 `git.git` 仓库 `master` 分支的官方文档（`gitdatamodel(7)`、`gitformat-pack(5)`、`gitformat-index(5)`、`gitformat-commit-graph(5)`、`gitrepository-layout(5)`、`git-refs(1)`、`git-update-ref(1)`、`git-gc(1)`、`git-repack(1)`、`git-worktree(1)`、`gitglossary(7)`）为准。

## 一、对象模型：四类对象，四种不可变载荷

### 1.1 一切都是对象

Git 的核心数据只有四类（`gitdatamodel(7)`）：**commit、tree、blob、tag**。每类对象都只有三个属性：

- **类型**（commit / tree / blob / tag）
- **大小**
- **内容**

`gitglossary(7)` 对 object 的定义是："The unit of storage in Git. It is uniquely identified by the SHA-1 of its contents. Consequently, an object cannot be changed."

这里有两个推论值得单独拎出来：

**推论一：Git 不存 diff，只存状态。** `gitglossary(7)` 在 "changeset" 一词上有一段著名的吐槽："BitKeeper/cvsps speak of a 'changeset' with Git. Since Git does not store changes, but states, it really does not make sense to use the term 'changesets' with Git."。commit 里只记录「这次提交之后每个文件是什么」，而不是「这次改了哪几行」；`git show` / `git diff` 显示的 diff 是**现算**出来的。

**推论二：内容相同必然对象相同。** 同一个文件内容在仓库里只会存一份 blob，无论它出现在多少个 commit 里。所以「提交 100 次改一行」并不会让仓库线性膨胀到 100 倍——每个 commit 只有几百字节，膨胀的是 commit 与 tree 本身。

### 1.2 blob：文件内容的快照

blob 的载荷就是文件字节本身，没有额外头部。一个 12 行的文件就是一个 12 行的 blob。Git 不关心它是文本还是二进制，也不关心它来自哪个路径——**路径信息在 tree 里，不在 blob 里**。这就是为什么同一个文件改名后，blob ID 不变而 tree ID 变。

### 1.3 tree：目录的快照

tree 是「一个目录的内容」的快照。它是一组条目，每条包含三样东西：**文件名、文件类型、对象 ID**。

官方文档给出的示例：

```
100644 blob 8728a858d9d21a8c78488c8b4e70e531b659141f README.md
040000 tree 89b1d2e0495f66d6929f4ff76ff1bb07fc41947d src
```

文件类型由权限位区分，一共有五种：

| 模式 | 类型 | 含义 |
| --- | --- | --- |
| `100644` | regular | 普通文件 |
| `100755` | executable | 可执行文件 |
| `120000` | symlink | 符号链接（blob 里存的是链接目标路径） |
| `040000` | tree | 子目录 |
| `160000` | gitlink | 子模块（指向另一个仓库的 commit） |

**要点：tree 里没有目录节点的概念。** 「目录」是通过 tree 对象本身的嵌套表达的：路径 `src/hello.py` 意味着根 tree 里有一个名为 `src` 的 tree 类型的条目，它的 ID 又指向另一个 tree 对象。

**要点：tree 是排序的、不可变的。** 对目录做一次修改，理论上要重建该目录的 tree 以及所有祖先目录的 tree。Git 在实现上做了缓存（index 的 cache tree 扩展，见第三章），但对象语义上就是「全量重建」。

### 1.4 commit：指向一棵树的外壳

commit 的载荷包含五部分：**顶层 tree 的 ID、parent commit 的 ID（零到多个）、作者与时间、提交者与时间、提交信息**。

官方示例：

```
tree 1b61de420a21a2f1aaef93e38ecd0e45e8bc9f0a
parent 4ccb6d7b8869a86aae2e84c56523f8705b50c647
author Maya <maya@example.com> 1759173425 -0400
committer Maya <maya@example.com> 1759173425 -0400

Add README
```

parent 的数量决定了 commit 的形状：

- **0 个 parent**：初始 commit（root commit）
- **1 个 parent**：普通提交
- **2 个及以上**：merge commit

注意 author 和 committer 是**两个独立字段**。`git commit --amend` 会保留 author（原作者与原作者时间），但 committer 会变成当前执行者和当前时间——这正是「谁在什么时候改的」与「谁在什么时候提交的」要分开的原因。

**要点：`git commit --amend` 产生的是全新 commit。** 官方文档写得很直接："`git commit --amend` creates a new commit with the same parents as the current commit."。新 commit 的内容哈希不同（committer 时间变了、message 可能变了），旧 commit 依然存在，只是可能不再被任何 ref 指向（见第二章的可达性）。

### 1.5 tag：指向任意对象的命名

tag object 的载荷包含：**被指向对象的 ID、该对象的类型、打 tag 的人与时间、tag 信息**。

```
object 750b4ead9c87ceb3ddb7a390e6c7074521797fb3
type commit
tag v1.0.0
tagger Maya <maya@example.com> 1759927359 -0400

Release version 1.0.0
```

这里必须区分两种「标签」，这是很多人踩坑的地方：

| 类型 | 存在形式 | 指向 | 能否被 `git tag -d` 直接删 |
| --- | --- | --- | --- |
| **annotated tag**（附注标签） | 独立的 tag 对象 | 可以指向 commit / tree / blob / tag | 先删对象引用再 `git tag -d` |
| **lightweight tag**（轻量标签） | 只是 `refs/tags/` 下一个普通 ref | 直接指向 commit | 是 |

判断方法：`git cat-file -t <tag>` 返回 `tag` 就是附注标签，返回 `commit` 就是轻量标签。

### 1.6 内容寻址与哈希

对象的 ID 是「类型 + 大小 + 内容」的哈希。传统仓库用 SHA-1，SHA-256 仓库用 SHA-256——`gitformat-pack(5)` 明确写了："In a repository using the traditional SHA-1, checksums and object IDs (object names) mentioned below are all computed using SHA-1. Similarly, in SHA-256 repositories, these values are computed using SHA-256."

**工程经验（重要）**：哈希只保证「内容相同必然 ID 相同」，**不保证「不同内容一定 ID 不同」**。理论上存在哈希碰撞，因此 Git 会用文件系统权限、只读位、以及 `fsck` 定期做完整性检查来兜底。这也是为什么裸仓库（bare repo）里的 `objects/` 目录通常建议只读。

## 二、引用与可达性：谁决定一个对象的生死

### 2.1 引用就是名字

`gitglossary(7)` 对 ref 的定义："A name that points to an object name or another ref (the latter is called a symbolic ref)."

引用命名空间是层级的，标准布局：

| 引用 | 含义 | 谁会改它 |
| --- | --- | --- |
| `refs/heads/<name>` | 本地分支 | `git commit`、`git branch`、`git reset`、`git merge` |
| `refs/tags/<name>` | 本地标签 | `git tag`（手动） |
| `refs/remotes/<remote>/<branch>` | 远程跟踪分支 | `git fetch`、`git pull` |
| `HEAD` | 当前检出位置 | `git checkout`、`git switch`、`git reset` |
| `ORIG_HEAD` | 某些危险操作前的备份 | `git merge`、`git reset` |
| 其他 `refs/` | `refs/stash`、`refs/bisect/*`、`refs/notes/*`、`refs/replace/*` | 各自命令 |

`gitglossary(7)` 还规定了一个细节：**ref 名要么以 `refs/` 开头，要么位于层级根部**，且根部的名字必须只含大写字母或下划线、并以 `_HEAD` 结尾或正好等于 `HEAD`。根层级还有一组「不规则 ref」，官方原文说这个列表 "is exhaustive and shall not be extended in the future"，包括 `AUTO_MERGE`、`BISECT_EXPECTED_REV`、`NOTES_MERGE_PARTIAL`、`NOTES_MERGE_REF`、`MERGE_AUTOSTASH`。

### 2.2 符号引用与解引用

**symref** 的格式是 `ref: refs/some/thing`。最典型的例子就是 `HEAD`：

```
$ cat .git/HEAD
ref: refs/heads/main
```

`gitglossary(7)` 对 **dereference** 的定义很精确："Referring to a symbolic ref: the action of accessing the reference pointed at by a symbolic ref. Recursive dereferencing involves repeating the aforementioned process on the resulting ref until a non-symbolic reference is found."

即：解引用是**递归**的，`HEAD → refs/heads/main → <commit OID>` 一路跟到底。对 tag 对象的解引用叫 **peel**，同样是递归的，直到得到指定类型或非 tag 类型。

**实践含义**：`git checkout` 一个分支时，Git 改的是 `HEAD` 这个 symref 的指向，不是移动分支本身。所以 `HEAD` 指向的分支名可以是任意合法分支名——这正是 `git switch -c` / `git checkout -b` 的实现方式。

### 2.3 可达性：对象的生死规则

这是整个模型里最重要的一节。`gitglossary(7)` 对 reachable 的定义：

> All of the ancestors of a given commit are said to be "reachable" from that commit. More generally, one object is reachable from another if we can reach the one from the other by a chain that follows tags to whatever they tag, commits to their parents or trees, and trees to the trees or blobs that they contain.

把规则翻译成可执行的算法：

```
从某个起点出发做深度优先遍历：
  tag    → 它标记的对象
  commit → 它的 parents（每个） + 它的 root tree
  tree   → 它的子 tree（每个） + 它的 blob（每个）
```

**起点是所有 ref 和 reflog。** `gitdatamodel(7)` 的原话是："An object is reachable if it is referred to by some reference or reflog"。

由此得到两个关键结论：

**结论一：可达对象永不删除，不可达对象可能被删除。** `gitdatamodel(7)` 明确说："Git may delete unreachable objects, but reachable objects are never deleted."

**结论二：amend 之后的旧 commit 通常还活着。** 因为它还在当前分支的 reflog 里，而 reflog 是可达性起点。这解释了为什么 `git reflog` 能把你「删掉」的 commit 捞回来——它从来没真正死过，只是不可达了。

### 2.4 dangling 与 unreachable 的区别

`gitglossary(7)` 区分了两个词：

- **unreachable object**：从任何 ref 或 reflog 都走不到
- **dangling object**：unreachable，**而且从其他 unreachable object 也走不到**

也就是说，dangling 是「彻底没人管」的对象。`git fsck --dangling` 报告的就是这一类。

### 2.5 reflog：本地版的「撤销历史」

`gitdatamodel(7)` 描述：每次 branch / remote-tracking branch / HEAD 的更新都会写一条 reflog。条目包含 **commit ID、时间戳、日志消息**。

```
750b4ea main@{2025-09-29 15:17:05 -0400}: commit: Add README
4ccb6d7 main@{2025-09-29 15:16:48 -0400}: commit (initial): Initial commit
```

**要点：reflog 只存在于本地仓库，不与远端共享。** 这是「同事拉不到我本地删掉的 commit」的根本原因，也是 `git push --force-with-lease` 存在的理由——远端没有你的 reflog，无法判断你的本地状态是否比远端新。

`gitglossary(7)` 对 reflog 的定义："A reflog shows the local 'history' of a ref. In other words, it can tell you what the 3rd last revision in this repository was."

## 三、磁盘表示：pack、delta 与 index

### 3.1 松散对象与 pack

新写入的对象是 **loose object**，放在 `objects/` 下按哈希前两位散列的 256 个子目录里（`gitrepository-layout(5)`："New objects are written into the 256 subdirectories of `objects/[0-9a-f][0-9a-f]/`"）。

但 Git 真正高效的方式是 **pack**：一个把所有对象压缩并存进单个文件的容器，外加一个索引文件。`gitformat-pack(5)` 的定义："A pack is a collection of objects, individually compressed, with delta compression applied, stored in a single file, with an associated index file."

**为什么要有 pack**：一是减少文件数量（几万个 loose object 就是几万个文件，inode 和目录项都吃不消）；二是 delta 压缩能显著减小体积；三是传输时一个文件比几万个文件高效得多。

### 3.2 pack 文件格式

`gitformat-pack(5)` 给出的结构：

```
4 字节签名 "PACK"
4 字节版本号（network byte order）—— Git 接受版本 2 或 3，但只生成版本 2
4 字节对象数量（network byte order）
若干对象条目
trailer：覆盖前面全部内容的 pack checksum
```

**对象条目有两种形态：**

| 形态 | 内容 |
| --- | --- |
| undeltified | n 字节的 type+length 头 + 压缩后的数据 |
| deltified | n 字节的 type+length 头 + （base 对象名 或 pack 内偏移）+ 压缩后的 delta 数据 |

对象类型编号：`OBJ_COMMIT(1)`、`OBJ_TREE(2)`、`OBJ_BLOB(3)`、`OBJ_TAG(4)`、`OBJ_OFS_DELTA(6)`、`OBJ_REF_DELTA(7)`；**类型 5 保留，类型 0 非法**。

**要点：packed object 没有 loose object 那样的 `"type size NUL"` 文件头前缀。** loose object 的磁盘文件就是一段文本头加 zlib 数据；而 pack 里的对象头是二进制变长编码。官方文档写道："the packed object format does not have the loose object format's 'type size NUL' prefix"，但计算对象 ID 时仍需要重建这个前缀——所以看到 pack 里「没有类型名」是正常的。

### 3.3 变长编码：size 与 offset

`gitformat-pack(5)` 对 n 字节 type+length 编码的描述：每字节用低 7 位承载数据，MSB=1 表示后面还有字节，MSB=0 的字节提供最后 7 位；**后面的值更重要**（little-endian 分块语义）。

关键区分：

- **size encoding**：未 delta 对象的 size 是**解压后**原始对象的大小；delta 对象的 size 是解压后的 delta 大小；base 对象名或偏移**不计入** size。
- **offset encoding**（仅 OFS_DELTA 使用）：编码 base 在同一个 pack 内的偏移。

**这是两个不同的东西**，混淆它们是读 pack 文件时最常见的错误。

### 3.4 delta 指令：copy 与 add

delta 数据是 RFC 1951 风格的指令流，每条指令首字节的高一位决定类型：

| 首字节形态 | 指令 | 语义 |
| --- | --- | --- |
| `1xxxxxxx` | copy from base | 复制 base 的一段区间到输出 |
| `0xxxxxxx` | add new data | 追加字面量数据，长度为首字节低 7 位（**必须非零**） |
| `00000000` | reserved | 保留 |

copy 指令后面跟着可选的 offset 字节（1-4 个）与可选的 size 字节（1-3 个），小端排列。首字节的低 7 位指示哪些字节存在（bit0 → offset1，bit1 → offset2，以此类推）。

**两个容易踩的细节：**

- **省略某个 offset 字节不会让后续字节前移。** 例如省略 offset2 时，offset3 仍然承载 bits 16-23。
- **最紧凑的 copy 指令只占 1 字节**（首字节 0x80），此时 offset 与 size 全部省略，默认值为 0。
- **size 为 0 会被自动当作 0x10000。** 这是 delta 格式的历史包袱。

### 3.5 ref-delta 与 ofs-delta

概念上只有 4 种对象类型，但 pack 内可以用 delta 表示来省空间，于是有了两种「伪类型」：

| 类型 | base 的表示方式 | 特点 |
| --- | --- | --- |
| **OBJ_REF_DELTA** | 直接编码 base 对象的**对象名**（哈希） | 可以指向 pack 外的对象（thin pack），但落盘的 pack 应自包含 |
| **OBJ_OFS_DELTA** | 编码 base 在**同一个 pack 内**的相对偏移 | 天然自包含，解包时可以顺序解引用 |

base 本身也可以是 delta（需要先转成 canonical form 再应用）。官方原文："Since the objects in a pack are stored in a way that is not necessarily the same order in which they were created, a delta can be applied to another delta."

### 3.6 pack 索引文件

version 1 的 `pack-*.idx` 结构：

```
256 个 4 字节整数（network byte order）—— 第 N 项记录「首个字节 ≤ N 的对象数」，即 fan-out 表
排序后的条目，每条 24 字节：4 字节 pack 内偏移 + object name
trailer：pack checksum 的副本 + idxfile 自身的 checksum
```

version 2 增加了对 >4 GiB pack 的支持，文件头用 4 字节 magic `'\377tOc'`。官方注释很坦诚："This is an unreasonable fanout[0] value."

### 3.7 cruft pack：为什么不可达对象不立即删

这是理解 `git gc` 行为的关键设计。`gitformat-pack(5)` 记录了完整的动机链：

1. `git repack -Ad` 会把旧 pack 里的不可达对象变成 loose object，等下次 gc 按过期规则 prune。
2. **不可达对象不能立即删除**，因为可能与正在推送的对象竞态。
3. **Git 必须把不可达对象存成 loose 才能跟踪 per-object mtime**。如果把它们写进一个大 pack，pack 的 mtime 会被整体刷新，导致内部的对象永远不过期。
4. 但大量 loose object 会导致 `.git/objects` 下目录项爆炸，可能引发 **inode 饥饿**，仓库性能下降；而且这些对象只能 zlib 压缩，**不能存 delta chain**。

**cruft pack** 是解法：`git repack --cruft` 把所有 loose 对象打进一个 pack，并把 per-object mtime 放进旁边的独立 `.mtimes` 文件。流程三步：

1. 枚举所有对象，把 **(a) 不在 kept-pack 中**且 **(b) mtime 在 grace period 内**的对象标为 traversal tip；
2. 从这些 tip 做可达性遍历并加入 pack；
3. 写出 pack 与 `.mtimes`。

`--cruft-expiration` 选项让新 cruft pack 直接省略已过期对象。

### 3.8 index 的真实格式

很多人以为 index 是个文本文件。它不是。`gitformat-index(5)` 描述的 index 是一个二进制文件：

```
12 字节头：
  4 字节签名 { 'D', 'I', 'R', 'C' }（dircache）
  4 字节版本号（当前支持 2、3、4）
  32 位 index entry 数量
排序后的 index entries
extensions
覆盖前面全部内容的 hash checksum
```

**单个 entry 的字段：**

| 字段 | 说明 |
| --- | --- |
| ctime 秒 / 纳秒 | stat(2) 元数据变化时间 |
| mtime 秒 / 纳秒 | stat(2) 数据变化时间 |
| dev / ino | stat(2) |
| mode | 见下方位布局 |
| uid / gid | stat(2) |
| file size | **stat(2) 的磁盘大小，截断为 32 位** |
| object name | 该文件内容对应的 blob ID |
| flags（16 位） | assume-valid、extended、**2 位 stage**、12 位 name length |
| path name | 相对顶层目录，无前导斜杠 |

**mode 位布局（高到低）**：16 位未用必须为 0；**4 位 object type**（二进制 `1000` = regular file、`1010` = symbolic link、`1110` = gitlink）；3 位未用必须为 0；**9 位 unix 权限（regular file 只有 0755 和 0644 有效；符号链接与 gitlink 该字段为 0）**。

**排序规则**："Index entries are sorted in ascending order on the name field, interpreted as a string of unsigned bytes (i.e. memcmp() order, no localization, no special casing of directory separator '/'). Entries with the same name are sorted by their stage field."

**版本 4 的前缀压缩**：路径名相对**前一条目**做压缩。条目开头先存一个变宽整数 N，再存一个 NUL 结尾的字符串 S；**从前一条目路径末尾去掉 N 字节并用 S 替换**就得到本条目的路径。版本 2/3 则用 1-8 个 NUL 字节把条目 padding 到 8 字节对齐。

**三个值得知道的扩展：**

| 扩展 | 签名 | 作用 |
| --- | --- | --- |
| Cache tree | `TREE` | 缓存「与既有 commit 完全相同的那部分区域」对应的 tree，commit 时只需算「新的」tree；路径更新时失效所有父目录节点，用 `entry_count = -1` 表示失效 |
| Resolve undo | `REUC` | 冲突解决时把被移除的高 stage 条目保存下来，以便 `git checkout -m` 重建冲突 |
| Split index | `link` | 大部分 entries 放在共享文件里，本扩展记录「要在共享 index 之上做的改动」，含 delete 位图与 replace 位图（ewah 编码） |

**stage 字段**是理解冲突的关键：stage 0 = 正常已暂存版本；stage 1/2/3 = 冲突时的 base / ours / theirs 三个版本。

### 3.9 commit-graph：加速遍历的旁路索引

`gitformat-commit-graph(5)` 描述的 commit-graph 文件存储：

- commit OID 列表
- **generation number**（拓扑层级）
- root tree OID
- commit date
- parents（用图内**位置引用**存储）
- 可选的 **Bloom filter**（该 commit 相对第一父提交改动的路径）

父提交用 32 位无符号整数「图内数组下标」表示，因此上限是 `(1 << 30) + (1 << 29) + (1 << 28) - 1`，约 18 亿个 commit。

文件头是 4 字节签名 `{'C','G','P','H'}` + 1 字节版本（目前只有版本 1）+ **1 字节 Hash Version**（1 = SHA-1，2 = SHA-256）。官方明确规定："If the hash type does not match the repository's hash algorithm, the commit-graph file should be ignored with a warning presented to the user."

generation number 的编码方式很特别：**前 4 字节的高 30 位存 generation number**，第 2 个 4 字节加上最低字节的最低 2 位存 commit 时间（拼出 33-34 位的时间戳）。

**工程经验**：`git commit-graph write --reachable` 可以在超大仓库上显著加快 `git log --graph` 与 `git rev-list`；但它是**补充表示**而不是权威数据——权威的 commit graph 是对象库里被分支 tip 引用的 commit 构成的 DAG（`gitglossary(7)` 定义）。

## 四、并发控制：锁、事务与竞态

### 4.1 为什么并发会坏

Git 的共享状态有三类，对应的并发问题也不同：

| 共享状态 | 并发写导致的问题 |
| --- | --- |
| **ref 文件**（`refs/heads/main` 等） | 两个进程同时更新同一个 ref → 后写覆盖先写（丢失更新），或读到半写状态 |
| **对象库**（`objects/`） | 两个进程同时写同一个对象 → 文件内容不完整 |
| **index 文件** | 两个进程同时改 index → 暂存区内容错乱 |

Git 的解法分两层：**锁文件（`.lock`）+ 原子改名**，以及**更高层的锁（packed-refs / gc 的互斥）**。

### 4.2 update-ref：CAS 与事务

`git-update-ref(1)` 是低层 ref 更新命令，它提供了两种并发安全手段。

**手段一：CAS（compare-and-swap）。**

```bash
git update-ref refs/heads/master <new-oid> <old-oid>
```

只有当当前值等于 `<old-oid>` 时才更新。官方文档规定：**40 个 "0" 或空字符串表示「该 ref 必须不存在」**。这让「创建分支」变成原子操作：

```bash
# 只有当 main 不存在时才创建，失败则报错
git update-ref refs/heads/main "$new" 0000000000000000000000000000000000000000
```

`git refs update <ref> <new-value> [<old-value>]` 是同一套语义的高层封装，并且额外支持「全零 new-value 删除分支」。

**手段二：事务。**

`git update-ref --stdin` 支持事务化批量更新，指令集包括：

```
update / create / delete / verify
symref-update / symref-create / symref-delete / symref-verify
option / start / prepare / commit / abort
```

`start` → `prepare` → `commit` → `abort` 是核心：prepare 之后所有修改已锁定待提交，commit 才真正生效，abort 则放弃。**这是实现「多 ref 原子更新」的关键机制**——比如同时移动 `refs/heads/main` 和 `refs/remotes/origin/main`，必须一次提交，不能一个成功一个失败。

官方还特别指出：**`--stdin` 有 `symref-*` 指令，所以普通 ref 与符号 ref 可以在同一个事务里提交**，而不带选项的命令行形式不支持把 symref 指向另一个 ref。

**`--batch-updates` 的语义要特别注意**：它允许个别更新因无效或错误输入而失败并只应用成功的更新，失败项以 `rejected SP <old-oid> SP <new-oid> SP <rejection-reason> LF` 格式报告。但**系统级错误（I/O 失败、内存问题）会导致整批全部失败**。也就是说它不是「全有或全无」，需要调用方自己检查 `rejected` 行。

### 4.3 git refs migrate 的并发限制

新的 `git refs` 子命令族里，`git refs migrate --ref-storage-format=<format>` 用于迁移 ref 存储格式。它的官方 WARNING 明确写了两条限制：

1. **无法迁移带 worktree 的仓库**；
2. **迁移期间无法阻止对仓库的并发写**，并发写会导致迁移后状态不一致，需要在更高层阻断写入。

另外，如果仓库注册了定期维护（scheduled maintenance），建议先 unregister。

**这条限制的价值在于它告诉我们：ref 存储格式的切换不是纯离线的后台操作，它需要一个写静默窗口。**

### 4.4 gc 的并发模型

`git-gc(1)` 是仓库的 housekeeping 入口，它做这些事：压缩文件修订、**删除先前 `git add` 产生的不可达对象**、打包 refs、修剪 reflog、rerere 元数据、陈旧工作树，还可能更新 commit-graph。

**保留策略。** 官方 NOTES 写得很清楚：**"git gc" tries very hard not to delete objects that are referenced anywhere in your repository**。除了当前分支和 tag 引用的对象，它还保留：

- **index 引用的对象**（暂存但未提交的内容）
- **remote-tracking 分支**
- **reflogs**（可能引用后来被 amend 或回退的分支里的 commit）
- **`refs/*` 命名空间下的一切**

但有个例外：**`git notes` 附的 note 不算保持对象存活**。

**竞态与缓解。** 官方原文承认："when 'git gc' runs concurrently with another process, there is a risk of it deleting an object that the other process is using but hasn't created a reference to. This may just cause the other process to fail or may corrupt the repository if the other process later adds a reference to the deleted object."

两个缓解特性：

1. **mtime 比 `--prune` 日期新的对象会被保留，连同从它们可达的一切**；
2. **大多数把对象加入数据库的操作会在对象已存在时更新其 mtime**，使上一条生效。

但官方紧接着承认：**"these features fall short of a complete solution, so users who run commands concurrently have to live with some risk of corruption (which seems to be low in practice)"**。

**结论：Git 在并发 gc 上给的是「降低风险」而不是「消除风险」。** 需要强保证的场景，应该在流程层面加锁（见 4.6）。

### 4.5 --prune=now 的风险

`git gc --prune=<date>` 默认修剪比 date 老的 loose 对象，**默认 2 周前**（受 `gc.pruneExpire` 控制）。而 `--prune=now` 不看年龄全部修剪，官方的警告是：

> increases the risk of corruption if another process is writing to the repository concurrently

也就是说 `git gc --prune=now` 在有并发写进程的仓库上是危险操作。**工程经验**：在 CI 或共享构建机上不要用 `--prune=now`；要立刻回收空间，用 `git gc` 默认策略即可。

### 4.6 repack 的并发考量

`git-repack(1)` 的 `-a` 选项把所有引用到的对象打进单个 pack；`-A` 与 `-a` 相同，但配合 `-d` 时**旧 pack 中的不可达对象会变成 loose 对象**，而不是留在旧 pack 里。官方强调：**不可达对象永不会被故意加入 pack**。

并发推送场景下的正确做法是 `--keep-pack=<pack-name>` / `-k`：**排除给定 pack 不重打包**（等价于给该 pack 加一个 `.keep` 文件）。官方原文：

> This means that we may duplicate objects, but this makes the option safe to use when there are concurrent pushes or fetches.

注意代价：**会产生重复对象，磁盘占用上升**。这是一个用空间换正确性的取舍。

### 4.7 worktree：共享与隔离

`git-worktree(1)` 允许一个仓库挂多个工作树：**共享除 per-worktree 文件（如 HEAD、index）之外的一切**。

```bash
git worktree add ../feature-branch feature-branch   # 新增工作树
git worktree list -v                                  # 查看详情
git worktree lock --reason "外接硬盘未挂载" <path>    # 防止被 prune
git worktree remove <path>                            # 移除
```

`git worktree list -v` 的输出包含：是否 bare、当前 checkout 的 revision、当前分支（无则 "detached HEAD"）、是否 "locked"、是否 "prunable"。

**`lock` 的用途很具体**：工作树放在便携设备或网络共享上、不是总挂着时，防止它的管理文件被 `prune` 掉，同时阻止它被移动或删除。

**并发视角**：worktree 让多个分支可以在同一台机器上并行开发且互不干扰工作区，但它们**共享同一个对象库和同一份 refs**——所以 ref 层面的竞争依然存在，worktree 并不能替代锁。

### 4.8 锁文件与原子改名

Git 写共享文件的标准套路是：**在目标路径旁创建 `<path>.lock` 临时文件，写入内容，然后 `rename()` 到目标路径**。

- `rename()` 在同一文件系统内是**原子**的：其他进程看到的要么是旧内容，要么是新内容，不会是半截文件。
- `.lock` 文件的存在本身是**互斥信号**：如果 `.lock` 已存在，说明有另一个进程正在写，第二个进程会失败并报 `cannot lock ref` / `Unable to create '...lock': File exists`。
- 因此「**Git 报 cannot lock ref**」的正确解读是：**不是 ref 坏了，是有另一个进程正在改它**。最常见的原因是同一仓库上并发跑两个 git 命令（CI 里两个 job 共用一个 clone、脚本里后台 git 与前台 git 撞车）。

## 五、工程清单

### 5.1 排查「对象丢了」的顺序

| 现象 | 先查什么 | 命令 |
| --- | --- | --- |
| commit 找不到了 | reflog 是否还有 | `git reflog --all` |
| 还在 reflog 但对象报错 | 对象库是否被 gc 剪掉 | `git fsck --lost-found` |
| 对象在但树不对 | 用 `git cat-file -p` 看真实内容 | `git cat-file -p <oid>` |
| 远端说没有 | reflog 是本地的 | `git reflog` 查不到远端 |
| tag 指向不对 | 是 annotated 还是 lightweight | `git cat-file -t <tag>` |

### 5.2 并发安全守则

1. **同一仓库目录不要并发跑 git 写命令**。CI 里用 `git clone` 而不是共享一个 `.git`。
2. **需要跨进程原子更新多个 ref 时用 `git update-ref --stdin` 事务**，不要连发多条 `git update-ref`。
3. **创建分支用 CAS 形式**（old 值填 40 个 0），避免「检查后创建」的竞态。
4. **不要在有并发写的仓库上用 `git gc --prune=now`**。
5. **需要立刻回收空间时用 `git repack -k` 排除正在被推送的 pack**，接受重复对象的代价。
6. **迁移 ref 存储格式需要写静默窗口**，并先 unregister 定期维护。

### 5.3 性能相关

| 手段 | 适用场景 | 命令 |
| --- | --- | --- |
| 重算 delta | 仓库 delta 质量差、体积虚胖 | `git gc --aggressive`（耗时，官方建议先做针对性 benchmark） |
| 写 commit-graph | 大仓库 `git log --graph` 慢 | `git commit-graph write --reachable` |
| 写 reachability bitmap | 大仓库对象搜索慢 | `git repack -b`（配合 `repack.writeBitmaps`） |
| 减少 index 体积 | index 很大、暂存区操作慢 | split index（`core.splitIndex`） |

**关于 `git gc --aggressive` 的官方提醒**："It's probably not worth it to use this option on a given repository without running tailored performance benchmarks on it."——先测量再上。

### 5.4 常见误区速查

| 误区 | 事实 |
| --- | --- |
| Git 存的是 diff | 存的是状态（tree），diff 是现算的 |
| amend 是「修改」旧 commit | 是创建新 commit，旧 commit 还在 reflog 里 |
| `git gc` 会删掉我 stash 的东西 | gc 保留 refs/* 与 reflog；但 `git notes` 的 note 不保活 |
| reflog 是共享的 | 只在本地仓库 |
| tag 都是附注标签 | 有 lightweight tag，`git cat-file -t` 可区分 |
| `git gc` 和 `git push` 同时跑没关系 | 官方承认存在损坏风险，只是「实践中较低」 |
| `--batch-updates` 是全有全无 | 个别失败会被跳过并报告；只有系统级错误才整批失败 |
| loose object 文件里能看到 "blob 12" | pack 里的对象没有 loose 的 `"type size NUL"` 文本头 |

## 小结

把 Git 的行为串起来只需要四句话：

1. **对象不可变、内容寻址**。commit / tree / blob / tag 四种载荷，ID 是内容的哈希。Git 存状态不存 diff，所以「改一行」很便宜，「改名」要重建整条目录链。
2. **引用决定生死**。ref 与 reflog 是可达性的起点，tag→commit→tree→blob 组成遍历图。可达对象永不删除，不可达对象等待被 prune。amend 之所以能撤销，正因为旧对象还挂在 reflog 上。
3. **磁盘表示是可替换的**。loose 对象换 pack、delta 压缩、cruft pack 收纳不可达对象、commit-graph 做旁路索引——这些都是性能优化，不改变语义。index 的二进制格式（stage、cache tree、split index）是理解暂存区与冲突的真正入口。
4. **并发靠锁与事务，但有边界**。CAS 让单 ref 更新原子化，`--stdin` 事务让多 ref 更新原子化；`.lock` 文件 + 原子改名保证文件不被写坏。但 gc 与并发写之间的风险 Git 官方明确承认无法完全消除——**要真正的保证，得在流程层加锁**。

## 参考资料

- [Git Data Model（gitdatamodel(7)）](https://git-scm.com/docs/gitdatamodel)
- [Git Object Format（gitformat-pack(5)）](https://git-scm.com/docs/gitformat-pack)
- [Git Index Format（gitformat-index(5)）](https://git-scm.com/docs/gitformat-index)
- [Git Commit Graph Format（gitformat-commit-graph(5)）](https://git-scm.com/docs/gitformat-commit-graph)
- [Git Repository Layout（gitrepository-layout(5)）](https://git-scm.com/docs/gitrepository-layout)
- [git-refs(1)](https://git-scm.com/docs/git-refs)
- [git-update-ref(1)](https://git-scm.com/docs/git-update-ref)
- [git-gc(1)](https://git-scm.com/docs/git-gc)
- [git-repack(1)](https://git-scm.com/docs/git-repack)
- [git-worktree(1)](https://git-scm.com/docs/git-worktree)
- [Git Glossary（gitglossary(7)）](https://git-scm.com/docs/gitglossary)
- [Pro Git 官方书籍（对象存储章节）](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
