# 3. 交付一条规则，要交付到加载它的每条路径上

日期：2026-10-13
状态：已采纳
影响版本：afk-bootstrap 1.7.19（`upgrade-afk.sh` 的 `1.7.18 -> 1.7.19` 步骤）

## 背景

1.7.18 引入了两条纪律：工单够格才开工（`ticket-check.mjs`），以及**把结论写回源单**
（`Source ticket:`）。它们落地当天的实测：

| promptFile | 谁加载 | 1.7.18 后 |
| --- | --- | --- |
| `.sandcastle/implement.md` | `main.ts`，本机 `npm run afk` | 有 |
| `.sandcastle/implement-prd/prompt.md` | `implement-prd.ts`，Actions 的 PRD | 有 |
| `.sandcastle/implement/prompt.md` | `implement.ts`，**Actions 的单 issue** | **无** |
| `.sandcastle/implement-prompt.md` | `planner.ts` | **无** |
| `.sandcastle/implement-pr/prompt.md` | `implement-pr.ts`，PR 反馈 | **无** |

`agent-implement.yml:290` 跑的是 `implement/implement.ts`——**单 issue 那条链路**，也就是
"打上 `agent:implement` 就开工"这个动作本身。它是唯一一条**从头到尾不问回写**的路径，
而它正是禅道场景里唯一会用到的入口。

同一个 1.7.13 步骤还有一个反向的漏：搜索纪律的插入器，它的**幂等判据搜的串在它自己插入
的段落里跨了行**——

```js
if (src.includes("search what this repository has already decided")) process.exit(4);
```

而段落是逐行插入的，"already" 在第一行末、"decided:" 在第二行首。这个判据**从未匹配过**，
`exit 4` 从未触发，于是**每次升级都再插一份**。四仓实测：三个被该步触碰的 prompt 各带
**四份**完全相同的段落。同一段守卫还被复制到了一个**它描述的句子在两处正文里都不存在**
的检查上（`architecture-decisions.md` 的 `## Before writing: search what is already there`
才是一行），那一处同样是空转的。

## 决定

**1.7.19 起，这两条纪律以「加载它的路径」为准逐条覆盖，而不是以作者想到的路径为准。**

- 插入器搬到 `tools/add-search-duty.mjs`：1.7.13 与 1.7.19 两步**共用一个文件**。判据换成
  **落在单行上**的 `do not spend a human's time on them.`（段落每行都是单行，任取一行都
  成立；取最后一行是因为它最不可能作为散文误撞）。同一趟里**把已堆叠的重复段收掉**：
  它比对的正是模板写过的那几句逐字文本，所以改过措辞的项目不会被碰。
- 回写纪律扩到全部 5 条 promptFile，锚点是各文件里**本来就结束在插入位置**的那一整行
  （`the planner loop handles delivery.` / `Do not close the issue yourself.` /
  `Resolution is the reviewer's job.`），四仓各实测**恰好命中一次**。
- 1.7.13 里那个空转的守卫指向真正的 section heading（`## Before writing: search what is
  already there`），让 `cmp` 回退不再是唯一在做事的判据。

## 被否掉的方案

- **只补 `.sandcastle/implement/prompt.md` 一条。** 那是最痛的一条，但 1.7.18 的教训正是
  「按想到的补」——补一条就会留下下一条，而两次升级之间没有任何东西会告诉你还差哪条。
  5 条 promptFile 是 `grep -rn promptFile <repo>/.sandcastle --include=*.ts` 能**点出来**的
  集合，用它做判据，而不是用记忆。

- **把插入器继续留在 1.7.13 步骤的 heredoc 里，另写一份给 1.7.19。** 两份就会漂：这正是
  1.7.12 的锚点失配与 1.7.13 的守卫空转的同一个形状。一份文件、一处判据、两步共用。

- **重复段只报告不删。** 逐字相同的四份不是项目写的，是这个工具写的；留着的代价是每个
  读 prompt 的模型都要多读三遍同一段。**但**：只在**逐行完全相同**时才收，项目改过的
  一字不动——收掉别人的文字是另一件事，本记录没有做它。

- **锚点未命中改判为致命错（`exit 1`），不让升级继续推进版本。** 这条是 Devin Review
  提的，理由是 `AGENTS.md` 写的「a step whose anchor does not match exits non-zero
  rather than guessing」。**实测否决**：`test/smoke.sh` 里 1.7.8 那个 fixture 会把
  `implement-prd/prompt.md` 造得**没有那个锚点**——1.7.11 才换成新的命令清单——于是
  1.7.13 步的 `exit 3` 变成 `exit 1`，一条**完全正当**的迁移被整棵拒绝。1.7.12 步对
  prompt 锚点未命中一直就是**警告并继续**（`say` 而非 `exit`），本步沿用同一口径：
  锚点是**措辞约定**，项目改写它是允许的，代价是那一处纪律没铺到；真正该拒绝的是
  锚点指向**结构**的步骤（Dockerfile 的 dispatch arm、workflow 的 job 序列）。

## 后果

- **新项目的落点是 `templates/`，升级路径落在 `scaffold/`。** 5 条 promptFile 里
  `.sandcastle/implement.md` 属于前者（`bootstrap-afk.sh:129` 从 `templates/implement.<lang>.md`
  渲染），其余四条属于后者。两边都要有这两条纪律——本步对两边都做了，smoke 的 fixture 也
  按**各自真实的来源**取文件（取错来源的 fixture 会测到不存在的插入）。

- **本步的判据是「恰好一次」，不是「至少一次」。** 被修的这个缺陷本身就是重复，`至少`
  口径在四个坏掉的仓库上全都会通过。

## 验证

`test/smoke.sh` 新增 1.7.19 段，fixture 从**当前 scaffold** 造出 1.7.18 状态（三条带四份
搜索段、两条没有搜索段、三条没有回写段），再断言升级后 5 条 promptFile **各有且仅有一份**
两条纪律，且插入的字节与 scaffold 一致。

两条负向对照都真跑过：

| 注入 | 结果 |
| --- | --- |
| 把 1.7.19 门控改成 `-ge 99`（等于该步不存在） | `implement-prompt.md (planner.ts): search duty appears 0 times, not once` |
| 关掉 `add-search-duty.mjs` 的去重分支 | `implement.md (main.ts): search duty appears 4 times, not once` |

以及 re-run 幂等：把升过级的树重新标回 1.7.18 再跑一次，5 条仍各一份。
