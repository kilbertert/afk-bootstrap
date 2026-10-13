# 6. 记录检查器：停止说不实的话，停止要求一件被禁止的事

日期：2026-10-14
状态：已采纳
影响版本：afk-bootstrap 1.7.22（`upgrade-afk.sh` 的 `1.7.21 -> 1.7.22` 步骤）

## 背景

`adr.check.mjs --all` 在四个消费仓上共报 14 条失败、全部退出码 1。逐条查过之后，
它们是**两类互不相同的缺陷**，而且**都不是"记录没写好"**。

### 缺陷一：报告说了不实的话（3/14）

`ALTERNATIVES_RE` 只认**标题**。AI-Ops 0006 第 15 行是：

```
- 被否掉的替代形态：(a) 由统一助手入口中介跳转——多一次往返换取客户端已知的信息；(b) 后端维护路由白名单——需要一份不在我们手里的权威路由清单；(c) 显式判别类型字段——见上。
```

那是正则要找的**原话**，带着三个被否掉的方案和各自理由——而检查器报的是
`no alternatives section … a record of what was chosen and not what was rejected`。

**一句关于该记录的不实陈述。** 这比漏报更坏：读的人被告知"缺一次称量"，而它就在
第 15 行；更坏的是，**照着这句话去"修"就会把已经写下的东西重写一遍或加一份重复的**。
AI-Ops 0006 / 0007 / 0010 三条都是这个形状。剩 11 条是**真的**没有称量。

检查器自己的注释还写着 *"Every spelling a record on this host already uses"* ——
词汇表是对的，**载体**是错的：它假设称量只能住在一个二级标题下。

### 缺陷二：门要求一件约定禁止的事（11/14）

`--all` 在"记录没有 alternatives 一节"时**判失败**。而约定写着：

> those records "are worth a pass when someone next touches the decision they
> describe; they are not worth a mechanical rewrite, and nobody should invent
> alternatives a record never weighed just to turn a check green."

于是变绿只有两条路：**编造**当年没被考虑过的方案（约定明文禁止），或者**删掉记录**。
一个只有不诚实出口的门，执行的正好是它所保护的那条规则的反面。

而约定**自己**也自相矛盾：`## Checking` 的模式表把 `--all` 写成
`# gate: every record in the repo`，紧接着的一段却说 *"Gating every record on every
change would mean a back catalogue has to be backfilled before this rule can be
adopted at all"*。一处说它是门，一处说不该这样判。

## 决定

**1. 载体不再限定为标题。** 一行以被否词汇**开头**的列表项或加粗引导语，同样算数
（`INLINE_ALTERNATIVES_RE`）。要求它落在**行首**是关键：这个检查存在的理由是"一条
从未称量过的记录"，而"alternative"一词出现在句子中间不是一次称量。实测该模式下
假阳性为 0（三个仓库的对照）。

**2. `--all` 的失败收紧到"修好它不需要记忆"的那些。** 新开一个 `advisory` 档，
**由模式决定**，不只由发现决定：

| | `--base`（判本次改动触碰的记录） | `--all`（扫全树） |
|---|---|---|
| alternatives 一节**缺失** | **失败** | 提示 |
| `Status:` 行缺失 | **失败** | **失败** |
| 文件名不合规 / 编号重复 | **失败** | **失败** |
| alternatives 标题**存在但为空或占位** | **失败** | **失败** |

`--base` 下新记录必然被触碰（`recordsUnderReview()` 取自 `git diff --name-status`），
所以**新记录照旧是硬失败**——作者就在键盘前，那正是约定说的"someone next touches
the decision they describe"。`--all` 上作者不在场，需要的那段记忆谁也不掌握。

**`Status:` 保持失败，这一条是刻意排除的。** 写它是**标注事实**、不是回忆：那几条
`trusted-pr-control-plane` 记录缺状态，而**每个仓库的 `.github/` 都能证明控制面是否
落地**（三条仓 3 个 workflow 引用它），答案是 `grep` 一次被记录所描述的那段代码。
它的价值恰恰在于**值**：AI-Ops 0003 带着 `Status: Accepted`，而它上方的引用块写着
"本决策尚未实现"、0008 记录着偏离——按"有没有这一行"分支会被误导，按**它的取值**
分支不会。

**3. 顺带修掉一个悬空引用。** 检查器的注释与失败文案都称
`docs/agents/architecture-decisions.md §"Scope"` 拥有豁免清单 —— 该文件没有这个
小节（最近的是 `## When a record is owed`），而检查器**从不读它**。文案改成指向真实
小节，并写明"本检查不读那个文件"。**一个看起来像控制、实际没有所指的引用，比没有
这句话更坏。**

## 被否掉的方案

- **把 `ENFORCE` 改成只看 `--base`，让 `--all` 永不失败。** 一行改完，但它删掉了
  afk-bootstrap 自己的 ADR 门（`.github/workflows/ci.yml:38` 用 `--all`），并且
  `test/smoke.sh` 里有一条**明确的断言**："the exit code is what makes `--all` a gate
  rather than a report"。那是在推翻一条已记录的决定，不是修一个缺陷。

- **给老记录加一个 `ADR-PRE-CONVENTION:` 豁免行。** 一条一行，人写明理由。但这要求
  人工逐条确认，而**判据是可算的**——"修好它需不需要记忆"由模式决定，不由记录决定。
  为一件工具能自己算出的事引入人工标注，是把机器的活派给人。

- **把 `Status:` 也降级成提示。** 我一度这么做，然后**推翻了**：理由见上，它是事实
  不是回忆，而且 AI-Ops 0003 恰好证明了这一行的**取值**不可替代。

- **把 11 条"真空缺"的记录补上 alternatives。** 那正是约定禁止的编造——当年的作者
  不在，写出来的不会是"被否掉的方案"，只会是"现在看起来该被否掉的方案"。

## 后果

- **四个仓库的 `--all` 从 9/4/2/4 条失败降到 1/2/1/1 条**，剩下的**全部**是缺
  `Status:`（可证的事实），内联误报归零。

- **`--base` 的门一点没放松**，而它才是消费仓 CI 用的那个（四个 `afk-policy.yml`）。
  `--all` 只用于 afk-bootstrap 自己的 CI，那里 5 条记录全部合规。

- **约定文档同步改写**，把矛盾那处删掉：模式表不再把 `--all` 称作"every record"的门，
  `### The sweep` 一节写清为什么那些条目是 advisory、以及两种模式为何不同。

## 顺带修掉的第三个缺陷：1.7.12 那次无条件覆盖

查上面那条迁移步骤时撞出来的：**1.7.12 步**（`:2914`）的门是 `to_patch -ge 12`，
**在之后的每一次升级上都为真**，所以它会对一个已经在 1.7.21 的项目再跑一遍——
而它那一行 `cp "$S/scaffold/$REL" "$WORK/$REL"` 是**无条件**的，于是**项目改过的
`adr.check.mjs` 会被直接覆盖**，在任何后续步骤能看见它之前。

实测：一个改过的 checker 走完 `1.7.21 -> 1.7.22` 后与模板**逐字节相同**，而 1.7.22
那一步随后报「already reads more than a heading」——对一份**刚刚被那一行毁掉编辑**的
文件。那句注释写的是 *"a project that never had this file"*，**代码没有这么说**。

四个在用仓库都带着未修改的副本，所以它**在生产上一次也没咬到**——它只在"项目改过
自己的检查器"时开火，而那个场景正是周围这套机制存在的理由。已加 `if [ ! -e "$TARGET/$REL" ]`
并补了正反两条断言。

## 验证

`test/smoke.sh` 新增两块，共 **7 条负向对照**真跑过、全部变红：

| 注入 | 结果 |
| --- | --- |
| 内联载体识别去掉 | 内联记录被误报 |
| `advisory` 恒为 `fail`（`--all` 不降级） | `--all` 又对 back catalogue 变红 |
| `advisory` 恒为 `advisory`（`--base` 也不拦） | `--base` 放过被触碰的记录 |
| 1.7.12 的 `if` 改回无条件 `cp` | `an upgrade destroyed a project's own edit to its checker` |

以及未注入时的正例：内联记录通过、空标题在**两种模式**都失败、缺 `Status:` 在
**两种模式**都失败、未改的 checker 仍被 restage、改过的不被覆盖。
