# 8. 一条规则要下发到加载它的每条路径上——审查面那次漏了

日期：2026-10-18
状态：已采纳
影响版本：afk-bootstrap 1.7.24（`upgrade-afk.sh` 的 `1.7.23 -> 1.7.24` 步骤）

## 背景

1.7.23 把 `## 0. You are the adversary, not the author` 写进了
`scaffold/.sandcastle/review-prompt.md`，然后停在那里。**那个文件是 bootstrap 的源**
——`bootstrap-afk.sh` 把 scaffold 拷进新项目——所以这一节到了 1.7.23 之后创建的每个项目，
**一个 1.7.23 之前创建的项目都没到**。推广后立刻实测三个 live 消费仓：

| | adversary 章节 |
| --- | --- |
| `scaffold/`（新项目） | ✅ 1 |
| AI-Ops（已升级 1.7.23） | ❌ 0 |
| health-flow（已升级 1.7.23） | ❌ 0 |
| genesis-evidence（已升级 1.7.23） | ❌ 0 |

**这是 ADR 0003 记录的同一形状，第二次发生**：一条规则被交付到**作者想到的路径**
（scaffold），而不是**加载它的每条路径**。1.7.18 对回写纪律犯过同一个错，当时只覆盖了
5 条 live prompt 里的 2 条。

**而且没有任何东西失败。** 没有任何检查拿 scaffold 的文件与消费仓的副本对比——
`adr.check.mjs` 查记录形态，`repo-map.check.mjs` 查地图新鲜度，
`policy-check.mjs` 查的是提交/branch/凭据边界。三仓的 `Workflow policy` 在 1.7.23 全部绿。

**发现方式是偶然的**：Devin Review 在 health-flow 的 PR 上提了一条关于
`review-prompt.md` **另外一件事**的问题（那两次全量门禁是否也该压成一次）。追那条问题时
才对 `review-prompt.md` 做逐仓核对，于是发现这一节根本没下发。

## 决定

**1.7.24 用锚点编辑把这一节补到消费仓的 `.sandcastle/review-prompt.md`。**

- 锚点 = `## 1. Read the diff and look for anything dodgy`，实测三个消费仓**各恰好一次**。
- 工具：`tools/right-size-tests.mjs` 增加 `review` 模式（与原有的 `loop` 模式并存，
  用参数区分而不是另写一个文件——两者服务同一条纪律的交付）。
- **注入的字节与 scaffold 逐字节相同**，且 smoke 直接断言这一点：新 bootstrap 的项目
  与升级来的项目对同一条规则必须携带同样的文本，否则两边会对这条规则产生分歧。
- 只处理 `.sandcastle/review-prompt.md`。`.sandcastle/review/prompt.md`（两轴之后的修复者）
  在 scaffold 里**没有**这一节，是不同的 prompt、不同的职责，不补。

**为什么仍用锚点而不是 `cmp` 覆盖**：实测消费仓的 `review-prompt.md` 与 scaffold 各差
**17 行**（手工套用的 `uv run pytest` 替换 + 项目自己的门禁措辞），`cmp` 守卫会在每个仓拒绝，
这一步就在所有仓静默 no-op —— 与 1.7.23 面对的是同一个原因。

## 被否掉的替代形态

- **并进已开的三个 1.7.23 PR。** 那三个 PR 当时门禁已全绿、review threads 已清空；
  往里再加一次工具与 smoke 改动会让每个仓重跑全套验证，而「修工具」与「把修复下发到仓库」
  本就是两件事。修补丁版本正是这套机制的用法。

- **用 `cmp` 整体覆盖消费仓的 `review-prompt.md`。** 见上，会在每个仓拒绝并静默 no-op。

- **同时补 `.sandcastle/review/prompt.md`。** 它在 scaffold 里没有这一节；补它等于
  在同一个 PR 里顺手扩范围，而它服务的是不同的阶段（轴报告之后的修复者，不是首轮审查者）。

- **加一个「scaffold 与消费仓一致性」的机械检查。** 方向正确，但机械检查需要一份
  受管文件清单，而 scaffold 里有相当一部分文件是**有意**让项目改写的（prompt 措辞、
  语言替换、项目专属段落）。这个检查会大量误报，代价大于收益。真正的防线是
  ADR 0003 已经写下的纪律：交付前先 `grep -rn promptFile` 把加载点**点一遍**，
  而不是按记忆。本次的教训是这条纪律要从 implement prompt 扩到**所有**被交付的 prompt。

## 后果

- 三个消费仓的审查者第一次拿到「你没有写这个改动，你的工作是让它失败」这条授权。
  这是本机真短板的对策：implementer 与 reviewer 是同族模型、同一套 prompt，
  独立性只来自新上下文与这条授权，**不来自模型差异**。
- 本仓的交付机制没有变；变的是**下发的判据**——从「我改的哪几个文件」变成
  「哪些路径加载它」。smoke 现在有一条断言把「新项目与升级项目携带同样字节」钉住，
  但**没有**检查能让「漏了一条路径」自动变红；那仍然靠人按 ADR 0003 点一遍。
- 代价：`tools/right-size-tests.mjs` 现在有两个模式，读它的人要多看一层分支。
  接受了这个代价，因为两个模式服务同一条纪律，拆成两个文件会让「这条纪律覆盖哪些文件」
  这个问题的答案散在两个地方——正是本次缺陷的成因。
