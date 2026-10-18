# 10. 语言无关的提示词不在任何清单上

日期：2026-10-18
状态：Accepted
影响版本：`scaffold/.sandcastle/merge-prompt.md`、`scaffold/.sandcastle/update-branch/prompt.md`（升级步骤 1.7.26 下发）；`tools/adapt-check-command.mjs`（新增）；`bootstrap-afk.sh`（改用它）

## 背景

scaffold 里每个提示词都写着 `npm run check`。其中五个有「一语言一版」的渲染
（`templates/implement.<lang>.md` 等），bootstrap 与 1.7.23–1.7.25 的每个升级步骤
都覆盖到了它们。

**`merge-prompt.md` 与 `update-branch/prompt.md` 没有渲染。** 这两个文件里没有一个字
和 Node 有关 —— 也正因为如此，它们从来不**需要**一语言一版；也正因如此，它们不在
任何清单上。两个文件都还写着 `npm run check`，而它们**全部的职责**就是
「解决冲突，然后验证」。

实测（2026-10-18，三个 python 消费仓 AI-Ops / health-flow / genesis-evidence）：
**各命中 2 处，正好是这两个文件**；五个有一语言一版的提示词全部正确。
`upgrade-afk.sh` 里 grep `merge-prompt` **零命中** —— 升级路径从来没碰过它们。

后果是活的，不是文档陈旧：python 仓里**解决合并冲突**与**更新分支**的 agent，
被明确要求执行一个不存在的命令，然后被要求「修好它报告的问题」。

## 决策

### 1. 一条规则、两个调用方

新增 `tools/adapt-check-command.mjs`，`bootstrap-afk.sh` 与 `upgrade-afk.sh` 都调它。

之前 bootstrap 里有一份**硬编码**的替换（只在它之后的项目生效），升级路径里
一份都没有。两个实现承载一条规则，正是 ADR 0008 反复发现的那个形状；
本记录是把该 ADR 应用到它自己的修复上。

### 2. 命令从 `language` 取，不从项目自己的提示词里猜

工具的判据是 `.afk-bootstrap.json` 的 `language` 字段，经
`templates/implement.<lang>.md` 解析。

**第一版不是这样。** 它从项目自己的 `.sandcastle/implement.md` 里读命令，理由是
「项目可能自己改过」。拿 AI-Ops 实测：那个文件被**大量手工定制**，
`before committing` 之后第一个反引号 token 是散文里的 `/diag/*` ——
它把 `/diag/*` 写进了两个提示词。

**散文上的启发式撑不过一个被人编辑过的提示词，而这两个文件恰恰都是人编辑的。**
退回模板是诚实的取舍：改过自己命令的项目拿到模板的命令，但那至少是一条**真命令**、
且一眼看得出需要改；从散文猜则拿到一条**像真的错的**命令。

### 3. 读不到就拒绝，不改

语言没记录、或没有对应模板时，工具 `exit 4` 且**一个字节都不写**。
猜一个会带着一本正经的表情把错命令写进两个提示词，而读它的 agent
没有任何办法知道那是猜的。

## 被否掉的替代形态

- **把这两个文件也做成一语言一版**（`merge-prompt.node.md` / `.python.md`）。
  这样最直接，也最符合这套脚手架既有的模式。它输了两次：
  这两个文件里**除了那一行**没有任何内容因语言而异，为一行命令复制整个文件，
  往后每一处措辞改动都要改两遍、且必然漂移；而且它们现在已经在三个仓里
  被项目手工改过，一语言一版会把那些改动卷入一次渲染替换。
  改一行、留一份，是更小的契约。

- **在 `upgrade-afk.sh` 里再写一份替换逻辑**（照 bootstrap 的样子）。
  这是最快的写法，也最省事。它输在**两个实现必然漂移** ——
  而漂移正是本记录要修的那个缺陷：bootstrap 有、升级路径没有，
  于是「新项目对、老项目错」持续了两个版本没人发现。

- **让工具走 `$TARGET` 而不是 `$WORK`。** 一行更短。它输在**绕开暂存-发布模型**：
  每个步骤都先写 staged copy，再经 `publish_file` 落到项目；直接改 `$TARGET`
  会让这一步没有备份、没有 changed 报告、且中断时留下半写状态。
  代价是这一步必须**按名字**把两个文件 stage 进 `$WORK`，因为它不像 bootstrap 那样
  整份复制 scaffold。

- **让工具在自己内部 `mkdir`/遍历。** 同上，会把「读不到就拒绝」这条
  变成了「静默什么都没做」。

## 后果

- 三个 python 消费仓 dry-run：每个**只**改这两个文件，`npm run check` 归零，
  命令落成各仓自己那串 `uv sync --extra dev && uv run pytest && uv run ruff check`
  （三仓一致，说明手工替换当年是一致的）。node 仓是 no-op。
- **代价**：项目的 `language` 从此是一条有下游依赖的元数据 ——
  它错，两个提示词就错。写错的可能性低（bootstrap 从 `--language` 写），
  但这是一条新的隐含耦合，记在这里。
- **仍未解决**：`bootstrap-afk.sh` 的 `LANGUAGE` 默认 `node`，**没有自动探测**。
  一个 python 仓漏传 `--language python` 会静默拿到整套 node 模板 ——
  这是本缺陷的另一个入口，本次**没有**修（改默认值会让现有 node 调用方行为变化，
  属于独立决定）。
- **仍未解决**：`upgrade-afk.sh` 里另有四个步骤用 `to_patch`-only 门控
  （`to_minor >= 7 && to_patch >= N`）。那个形状在下一个 minor 上会重新触发；
  实测它们在真仓上是幂等的，所以目前只是重复输出、不是重复写入。
  与本记录无关，但同属「清单会过期」这一类。

## 审查抓出的三处（都在第一版里）

**1. 与 1.4.0 术语表步骤打架 —— 会产生悬挂指针。**
这一步第一版无条件 `cp` 目标文件进 `$WORK`。但 1.4.0 的术语表步骤**已经**把
`update-branch/prompt.md` stage 过（`CONTEXT.md` → `GLOSSARY.md`）并登记发布；
我的 `cp` 把那份额外覆盖回原样，而同一次运行又把文档改名成 `GLOSSARY.md`。
结果提示词指向一个不存在的文件。实测：1.3 的 fixture 升级后，文档变成
`GLOSSARY.md`，提示词里仍写着 `CONTEXT.md`。改为 `[ -e "$WORK/$rel" ] || cp …`。

**2. `exit 4` 的处理是错的。** 第一版写了个「note 一下、继续」的分支。
但 `--dry-run` 在发布尾之前就 exit 了，所以那个分支在 dry-run 下是死代码、
在实跑下是**静默不写**——而版本号照样盖成 1.7.26，下一次运行走「already at 1.7.26」
提前退出、永不重试。按仓库自己的约定，被拒绝的迁移必须让项目保持原样。
改为**致命错误**：实跑会停下且不盖版本，修好 `language` 后能重跑。

**3. `bootstrap-afk.sh` 里一句注释描述了一条不存在的路径。** 它说工具
"is not an error either way"，暗示那里有 dry-run——bootstrap 根本没有 dry-run。
那句被删掉了，因为一句听起来合理的注释比没有注释更坏。

## 验证

- `bash test/smoke.sh python` 与 `bash test/smoke.sh node` 全绿。
- 三条负向对照**真跑过**（不是推理）：
  1. 让工具在语言未知时**猜** → smoke 报「an unknown language was given a guessed check command」，退出 1；
  2. 去掉 `NEW_FILES` 登记 → smoke 报「adapted … but never published it」，退出 1；
  3. 恢复**无条件**登记 → node 仓的 smoke 报「a node project's merge-prompt.md was overwritten by the scaffold copy」，退出 1。
- 第 3 条是本记录最重的一处：**修缺陷的步骤差点劫持项目的文件。**
  无条件登记时，node 项目这两个提示词会被 scaffold 的副本覆盖回去 ——
  而它们恰恰是最可能被人改过的文件。这条对照是写完第一版之后**靠跑才发现**的。
- 另两条对照（针对上面「审查抓出的三处」）：
  4. 把「不覆盖已 staged」改回无条件 `cp` → smoke 报
     「a pre-1.4 upgrade left the prompt naming CONTEXT.md after renaming the doc」，退出 1；
  5. 恢复无条件 `NEW_FILES` 登记 → node 的 smoke 报
     「the upgrade reverted a project's own edit to merge-prompt.md」，退出 1。
- **五条对照里，第 4、5 两条是审查提出、我实测复现后才补的** ——
  它们覆盖的是第一版**没有**任何断言的两件事：与更早步骤的暂存冲突、
  以及项目自有改动的保全。前三条覆盖的是「这一步有没有照它承诺的做」，
  后两条覆盖的是「这一步有没有破坏别人的东西」。
