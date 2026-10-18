# 9. 另一条审查链路也拿到对抗授权——而照抄会让它执行做不到的事

日期：2026-10-18
状态：已采纳
影响版本：afk-bootstrap 1.7.25（`upgrade-afk.sh` 的 `1.7.24 -> 1.7.25` 步骤）

## 背景

1.7.24 把对抗授权交付到了 `.sandcastle/review-prompt.md`，并在 ADR 0008 里
**明确考虑、且正确地否掉**了 `.sandcastle/review/prompt.md`（两轴之后的修复者，职责不同）。
那段推理漏掉的是：**同一个目录里还有 `review/axis-prompt.md`，它是另一条链路上的首轮审查者**
——`review/review.ts:178` 为 `agent:review` 标签触发的两轴审查加载它，它自己的正文写着
`You are the **{{REVIEW_AXIS}}** reviewer`。

于是这条纪律到了一条审查链路，没到另一条。**这是本仓第四次交付 ADR 0003 记录的缺陷**
（1.7.18 丢了两条 implement prompt；1.7.23 只到 scaffold，消费仓 0 of 3；
1.7.24 的 ADR 本身漏掉同目录的第二个文件）。

**这次的新意**：「我们考虑并否掉了 X」这个动作让**整个目录**看起来已经检查过了。
一份写着取舍的记录，反而成了漏检的遮挡。

**发现方式**：Devin Review 在 health-flow 的一个消费仓 PR 上问「`agent:review` 那条路
为什么什么都没拿到」。不是任何机械检查发现的。

## 决定

**1.7.25 把对抗授权补到 `.sandcastle/review/axis-prompt.md`，但文本是重写的，不是照抄。**

这个 prompt **只读**——它的正文写着 `Do not edit files, commit, push, or reply to GitHub
comments`，输出是 JSON `findings` 数组。**但「只读」不等于「不能执行」**：`review.ts` 用的是
与其它链路相同的 `claudeProfile`，`onSandboxReady` 里跑 `bash .sandcastle/sandbox-prepare.sh`，
所以它**有 sandbox、能跑东西**，只是不许改、不许提交。

于是新文本的判据是**分两层**的：

- **能示范就示范**：`If you can reproduce a failure by running something — a test, a
  command, a snippet against the checkout — do that and report the output; a
  demonstrated failure beats a described one.`
- **不能示范时，描述必须精确到可被检查**：`"The input X reaches this branch, and the
  guard above it only covers Y" is a finding. "This looks fragile" is not — it names
  no input, so nobody can check it.`

**本 PR 的第一版把这条写错了**：它说 `You cannot run the code ... described rather than
demonstrated`。那是对 sandbox 的**未经验证的断言**，而且方向有害——它会劝阻审查者去
复现一个它**本来能复现**的失败。Devin Review 指出后核实属实，已改。

**照抄可写审查者那段仍然不对**（那句 `a failing output you ran` 假定它一定会跑），
但理由变了：不是"它不能跑"，而是"**它可能没法用跑的方式证明，那时判据必须退到
'点名具体输入'**"。两段都保留各自的形式。

**交付方式用 `cmp` 守卫的整文件覆盖**，与 1.7.24 的锚点编辑相反——因为两个文件恰好在这点上
不同：`review-prompt.md` 在每个消费仓都与 scaffold 差 17 行（手工语言替换 + 项目自己的门禁措辞），
而 `review/axis-prompt.md` 实测在三个仓**与 scaffold 逐字节相同**。
**`cmp` 守卫对没人改过的文件是对的，对所有人都改过的文件是错的。**

**幂等判据匹配的是正文里的一句话，不是标题。** 第一版判据是 `grep -qF "# YOUR JOB"`，
于是**只是在散文里提到这个标题**的项目（`Our checklist quotes # YOUR JOB from the planner
prompt`）就满足了它——升级报「already carries the adversary duty」、把旧审查文本留在原地、
**照样盖上 1.7.25**。实测复现。这正是**本步自己的失败模式（静默跳过）在它自己的守卫里重演**，
也是 1.7.24 的 review 模式犯过的同一个「子串 vs 结构」错误。改为匹配正文里的一句
（`so they encode the author's assumptions`），并且**项目真正的自有文本被保留**、只报告不覆盖。

## 被否掉的替代形态

- **照抄 `review-prompt.md` 的那一段。** 那句判据要求"finding 是你**跑出来**的失败输出"，
  而这个 prompt 的输出是 JSON `findings`、且它常需要在**不能实际复现**的情形下下判断
  （例如缺失的上游、生产数据）。照抄会把「跑出来」当成唯一合格形式，于是要么逼它
  为了满足字面而假装跑过，要么让真正有价值的、描述型的反例被自我否决。
  改写后的文本保留同一意图（对抗、反例、绿灯不是证据），但把判据写成两层。

- **断言这个审查者"不能执行"。** 本 PR 的第一版这么写了（`You cannot run the code`），
  核实后是错的：它与其它链路共用 `claudeProfile`，有 sandbox，`sandbox-prepare.sh` 会跑。
  禁止的只是编辑/提交/推送。这条假设若留着，会**劝阻审查者去复现一个它本来能复现的失败**
  ——比不写还坏，因为它披着"我只读所以只描述"的合理性外衣。

- **只补 scaffold，等下次有人升级自然拿到。** 那正是 1.7.23 的错（消费仓 0 of 3），
  也正是本步要修的。已存在的仓恰是**正在跑** AFK 的那些。

- **把两条审查链路的 prompt 合并成一个文件。** 它们的输出契约不同（散文 vs JSON `findings`）、
  权限不同（可写 vs 只读）、阶段不同（两轴对读 vs 单轮修复）。合并会让其中一条失去它的契约。

- **加一个机械检查，断言「每个审查者 prompt 都带对抗授权」。** 这条比 ADR 0008 里否掉的
  「scaffold ↔ 消费仓一致性」检查更可行（审查者集合小且稳定），但**判据不统一**：
  可写的审查者与只读的审查者要求不同的措辞，一个按字符串匹配的检查会把"改写得正确"判成失败。
  暂不做；如果第四次漏发之后还有第五次，应当重新评估这条，并把判据落在
  **角色**（这个 prompt 是不是审查者）而不是**文本**上。

## 验证过程中我自己犯的两个错，都记在这里

**一、断言了一个我没核实的能力。** 新文本第一版写 `You cannot run the code`——那是我对
sandbox 的**推断**，不是实测。核实后：`review.ts` 与其它链路共用 `claudeProfile`，
`onSandboxReady` 会跑 `sandbox.sh`，所以分析者**有 sandbox**，禁止的只是编辑/提交/推送。
这条若留下，会劝阻审查者去复现一个它**本来能复现**的失败——比不写更坏，因为它披着
「我只读所以只描述」的合理性外衣。

**二、我的负向对照第一版是空转的。** 那个对照要断言「只是提到标题时，这一步会**报告**而不是
静默跳过」。第一版在**第一次运行**上 `>/dev/null`，然后在**同一棵树上**再跑一次去 grep 报告
——而第一次已经盖上了 1.7.25，第二次走的是 "already at 1.7.25" 提前退出，**根本没进这一步**。
断言因此永远为真，看着像在测守卫，实际什么都没测。（修法：在同一次运行的输出上断言。）

**这两个错与它修的 bug 是同一个形状**：一个未经验证的假设（"它不能跑"）与一个空转的判据
（"测了个不会到达的路径"）。写在这里而不是删掉，因为它们比结论更容易被下一个人重复。

## 后果

- 两条审查链路现在都有对抗授权，且各按自己的能力措辞。
- **第四次同一缺陷，这让「按记录复核」这个防线本身显得不够**。ADR 0008 已经写下
  「『否掉了 X』应当读成『复核过 X』，而不是『检查过那个目录』」；本步说明这条还不够——
  本步的漏检恰恰发生在**同一个目录**内。留下的判据被收紧为：
  **按 `grep -rn promptFile` 点出来的每一个加载点，逐个判角色**，而不是按目录。
- 代价：仓库里现在有两段措辞相近、判据不同的对抗文本。这是刻意的——合并它们会让
  只读的那条背上做不到的标准。两段都写明了各自的理由，读者不会以为是复制粘贴遗留。
