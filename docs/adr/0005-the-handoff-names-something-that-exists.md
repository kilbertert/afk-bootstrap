# 5. 回写要写「当时存在的东西」，并且承诺的事必须有人做

日期：2026-10-13
状态：已采纳
影响版本：afk-bootstrap 1.7.21（`upgrade-afk.sh` 的 `1.7.20 -> 1.7.21` 步骤）

## 背景

1.7.18 引入的回写段落是这么写的：

> write back to it: **the branch, the pull request**, and which acceptance criteria
> this change satisfies. You cannot post to a system this sandbox does not reach;
> record the text in the commit body under `Source ticket:` and the host runner or
> the human who owns that ticket posts it.

两个洞，都是 Devin Review 在四仓 PR 上报的、我复现后确认：

1. **它要 agent 写一个当时不存在的东西。** 提交发生在 `gh pr create` **之前**——
   单 issue 链路（`agent-implement.yml` 的 Open PR 步骤）与 planner 的
   `openDeliveryPr` 都是这个顺序。agent 手上没有 PR 号，只能编或者空着。
2. **它把 commit body 定成唯一载体。** `implement-pr` 允许「只回复、零提交」的成功
   路径，那条路上根本没有 commit 可写，回写静默不发生。

而且第二条还有一层：段落写「**the host runner** … posts it」——**当时没有任何一步在做
这件事**。这是最坏的一种：一个描述机制的句子，而机制不存在。

## 决定

**段落只要求 agent 写它知道的，并且把「host 会做的那半」真的做出来。**

新文本：记下工单标识与已满足的验收标准，写在 commit body 的 `Source ticket:` 下；
**不要写 PR**，因为提交时还没有；纯回复的 run 把同一行写进顶层 PR 评论（载体在
schema 里早就有：`topLevelComments`）。并删掉那句「the host runner posts it」。

**host 那半是真的实现，不是改措辞**：

- 新增 `.sandcastle/ticket-writeback.sh`：在 `gh pr create` 之后，把 PR 链接评论到
  这个 run 起始的那张 issue 上。issue 号来自 workflow 级的 `ISSUE_NUMBER`，**不从
  提交里猜**。
- `tools/ticket-writeback-wire.py` 把它接进 `agent-implement.yml`，位置在 **Open PR
  之后、Request automated review 之前**；同时给 Open PR 步骤补上 `pr_url` 输出
  （原来只输出 `pr_number`）。
- PRD 那条链路本来就在关子单时评论，但只给 commit SHA。改成同时给 PR 链接。

## 被否掉的方案

- **只改段落措辞，不做 host 那半。** 那样新句子「the host posts that link to the
  issue itself」依然是一句没有实现的承诺——**正是这次要修的那个缺陷**，只是换了个
  说法。要么做，要么别写。

- **让 agent 写完 commit 再补一次。** 提交后 amend 能把 PR 号补进去，但那要求 agent
  知道 host 之后才会创建的 PR，仍然做不到；而且改写了已被 review 的提交。

- **把 issue 号从提交里推断。** `Source ticket:` 是给**人**看的记录，用的是各系统
  自己的标识（禅道单号、Slack 链接）。拿它当「评论到哪张 issue」的输入，等于让一个
  面向外部的字段决定一个只对本仓库有意义的动作。起始 issue 由 workflow 的
  `ISSUE_NUMBER` 给出，是确定的。

- **让 `ticket-writeback.sh` 失败即整个 run 失败。** 评论发不出去不该让一次**已经
  成功**的交付（分支、PR 都在）变红，所以调用处是 `|| true`；记录仍在 workflow 日志里。

## 三个实现上的坑，都是实测出来的

1. **不能用 `yaml.safe_dump`。** 我第一版把解析后的文档整份 dump 回去，`on:` 变成了
   `true:`（YAML 1.1 把 `on` 读成布尔）。`test/smoke.sh` 的 workflow 断言当场拒了。
   改成**只解析定位、拼接文本、再解析断言**——和 `tools/ticket-wire.py` 一样。

2. **`yaml.safe_load` 读 `on:` 本来就读成 `True`。** 所以我第一版的断言
   「`safe_load(new).get(True) is None`」在**未改动的脚手架**上就失败——它检查的是
   PyYAML 的行为，不是这次编辑。判据必须落在**文本**上：`"\non:" in new_text`。

3. **`$WORK` 不 stage `docs/`。** 约定文档的重写步骤 `[ ! -e "$WORK/$REL" ]` 于是在
   每个项目上都读成「文件不存在」，**看起来成功、实际什么都没做**。是先 `cp` 进
   `$WORK` 再判。smoke 抓到了：断言在，文件却没变。

## 第四个坑：fixture 不能从 HEAD 取「改动前」的形状

smoke 的 fixture 原本用 `git -C "$S" show HEAD:<workflow>` 取 1.7.20 的 workflow。
**本机跑是绿的，CI 上第一次就红**：CI 检出的 PR **合并提交**里已经含这次改动，
于是「剥掉 write-back 步骤」那句话找不到可剥的东西。

更坏的是它红在断言上还是红在**静默通过**上，取决于顺序——`assert "ticket-writeback.sh"
not in text` 是我为了防这个而加的，它就是那次红的原因；**没有这句断言的话，fixture
会拿一份已改的 workflow 去「还原」1.7.20，而后面所有断言都会在一个从未处于该状态的
树上通过。** 这正是本仓 1.7.12 记录里那条「a reference that tracks HEAD anchors
nothing」的同一个形状，隔了五个版本又踩一次。

改为从 `references/agent-implement.1.7.20.yml` 取（步骤将来做 `cmp` 本来就要用同一份），
并在 fixture 里断言那份 reference **确实**不含 step、不含 `pr_url` —— reference 漂了
就立刻红，而不是让下游断言空转。

复现方式（本机可跑）：把工作树 `git init` 后提交，跑 `test/smoke.sh` —— 那就是 CI 的
条件。修之前该条件红，修之后绿。

## 验证

`test/smoke.sh` 新增 1.7.21 段：fixture 造出 1.7.20 状态（旧段落 + 未接线的 workflow
+ 未改写前的约定文档），升级后断言

- 5 条 prompt 里旧措辞**消失**、新措辞各出现一次、纯回复路径有载体；
- 约定文档被重写（这条是坑 3 的判据）；
- write-back 脚本存在、**owner 可执行**、workflow 里有这一步、且它在 `open_pr`
  **之后**、步骤确实拿到 `PR_URL`。

四条负向对照真跑过，全部变红：

| 注入 | 结果 |
| --- | --- |
| 关掉 1.7.21 门控 | 段落与 scaffold 不一致 |
| `replace-ticket-duty.mjs` 不做替换 | `write-back duty appears 2 times, not once` |
| 工具不做替换（只接 host） | 同上 |
| 不接 host 那一步 | `the write-back step was not added` |
