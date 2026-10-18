# 7. 验证按风险成形，全量门禁只跑一次

日期：2026-10-17
状态：已采纳
影响版本：afk-bootstrap 1.7.23（`upgrade-afk.sh` 的 `1.7.22 -> 1.7.23` 步骤）

## 背景

反馈是「agent 写一大堆测试，80% 耗时在测试上」。**实测否定了前半句**，并把成因指向另一处。

五个活跃仓库（2026-09-01 起的 churn / 文件占比）：

| 仓库 | 测试行占比 | 测试文件占比 |
|---|---|---|
| health-flow | 40.4% | 6.0% |
| AI-Ops | 26.6% | 32.8% |
| genesis-evidence | 21.7% | 7.3% |
| hypit | 14.5% | — |
| qumall-ui | 0.0% | — |

没有一个接近 80%，而且**全仓库不存在任何覆盖率阈值**：`vitest.config`、`pyproject.toml`、
CI workflow 里没有 `fail_under`，`policy-check.mjs` 也不读覆盖率。

真正的耗时是一个**循环**，不是测试量。`Use red-green-refactor where applicable:
1. RED / 2. GREEN / 3. REPEAT until the issue is done / 4. REFACTOR` 直接坐在
`Before committing, run <gate>` 之上，而那个 gate 是 typecheck + **全量 suite** + build。
所以 agent 读到的指令是「跑完所有东西，然后再来一轮」。实测（本机真跑）：

| | 耗时 |
|---|---|
| AI-Ops 全量 `uv run pytest`（1805 个测试文件） | **299.62 s** |
| AI-Ops 单文件 | **2.91 s** |
| 倍数 | **≈103×** |
| health-flow 单文件 | 1.69 s |
| Auto-Test `vitest related <file>` | 1.73 s |

`Auto-Test/.sandcastle/logs/issue-92..99.log` 显示该 gate 每个 issue 被调用 **4 次以上**。
一个 issue 因此在反复重跑它已经跑过的 suite —— 这才是「80% 花在测试上」的来源。
**写测试不是成本，重复才是。**

服务器策略从未要求 blanket TDD：`Acceptance And System-Test Evidence` 原文是
**"Test scope is risk-based"**。仪式是 prompt 承载的，所以修在 prompt。

## 决定

**重写承载循环的那一个区块：保留「测试是最便宜的 oracle 时先用测试」，把全量门禁从「每一轮」降为「收尾一次」。**

- 三个 live prompt 被改：`implement-prompt.md`（planner.ts）、`implement/prompt.md`
  （打标签的单 issue 路径，implement.ts）、`implement-prd/prompt.md`（implement-prd.ts）。
- **门禁自身的字节不动**：每个项目选的验证命令——包括 python 项目手工套用的 `uv` 替换——
  原样保留。步骤只在其上方的区块里说话。
- `templates/` 侧同样改（`prompt.node.md`/`prompt.python.md`），新项目直接得到新文本。
- `templates/CODING_STANDARDS.md`：把「Update tests alongside behavior changes; keep the
  suite green.」改成按目的表述——回归测试是老行为仍然成立的**持久记录**（这条被强化），
  而全量 suite 是**交付前的门禁，不是每次编辑后转的圈**。
- 审查面 `scaffold/.sandcastle/review-prompt.md` 加 `## 0. You are the adversary, not the
  author`：反例是**跑出来的失败输出**，不是持有的顾虑；作者写的测试只证明作者的假设。

范围**故意窄**：`implement.md` 与 `implement-pr/prompt.md` 本来就只跑一次门禁，两个 review
prompt 是围绕一次编辑跑两次，都没有「圈」可去。

## 机制：锚点编辑，而不是 `cmp` 整文件 restage

1.7.19 与 1.7.22 两步都用 `cmp` 对 `references/*.1.7.NN` 快照、命中就 `cp` 覆盖。
**这个机制在四个消费仓上已经死了**：实测每个 live prompt 与 scaffold 差 9–25 行，
来自两个独立原因——(a) 手工套用的语言替换（`upgrade-afk.sh` 里**没有**任何替换逻辑）；
(b) 每个仓手写的项目专属验证段落（AI-Ops 那段点名自己的验证 skill、一次性数据根、
以及「绝不把设备 token 写进证据或提交」的凭据红线）。`cmp` 守卫在**每一个消费仓都会拒绝**，
于是这一步会在所有仓静默 no-op —— 正是 ADR 0003 记录的缺陷，向外一层。

而 `Use red-green-refactor` 区块本身，实测在四个仓 × 三个文件的**全部组合里字节相同**，
这才是锚点编辑在这里安全的原因。

## 被否掉的方案

- **整份照搬外部那份「从此不写测试、既有红灯不再是事故」的 doctrine。** 与
  `policy/afk-contract.json` 的 `non_exceptionable_invariants` 直接冲突：`deterministic-ci`
  在不可豁免清单里，红灯 = CI 红 = 合不了。照抄会自断门禁。其中「作者 ≠ Hacker」与
  「守门件不是 oracle」两条被采纳——那两条恰是本机的真短板（同一族模型、同一套 prompt，
  独立性弱）。

- **维持 blanket TDD，只把全量换成分片。** 治不到「REPEAT」这个结构：`3. REPEAT` 读起来就是
  「无限循环」，而它下面紧跟全量。实测 103× 的比值说明省下的是**重复次数**。

- **用 `cmp` restage 三个 prompt。** 见上，会在四个仓全部拒绝并静默跳过。

- **给 `implement.md` 与两个 review prompt 也插一段 cadence。** 它们本来就不循环，
  插进去是往不存在的缺陷上加文本——正是 ladder 禁止的过度建造。

- **改 `docs/agents/architecture-decisions.md` 之外的治理文档。** 策略本来就写着 risk-based，
  本次不动治理事实源（`~/Projects/server-development-consensus/`）。

## 后果

- 一个 issue 在循环里的门禁次数从 4+ 次全量降到 1 次。以 AI-Ops 计，单次省下约 5 分钟 × 3。
- **回归测试的地位被明确保留并强化**，不是被削弱：改动只停掉「为凑数字而造的测试」。
  三个仓的 `test_http_auth`/`test_faq`/`test_health_report` 这类真实行为测试一个没动。
- 手写的项目专属验证段落**原样存活**，这是新机制相对 `cmp` restage 的主要收益。
- 代价：`scoped 迭代`是否覆盖被改行为的依赖链，取决于仓库的测试组织；耦合重的仓会漏。
  回退路径是把该仓的 prompt 改回全量（工具对本就符合的文件 `exit 4`，不动）。
- 独立性只有「新上下文 + 对抗授权 + 产物是具体反例」，**没有模型差异**——本机所有 AFK
  项目共用一套模型路由，做不到「换个模型 = 独立」。这条写在这里，免得被读成更强的保证。

## 验证

`test/smoke.sh` 新增 1.7.23 段，fixture **注入真实仓携带的两处偏离**（语言替换 + 手写验证段落），
因为不含这两处的 fixture 会在每个真实仓 no-op 的情况下照样通过：

1. 三个 prompt 的 `Use red-green-refactor` 与 `RED: write one failing test` 计数为 **0**；
2. 新指引与 cadence 句各**恰好一次**（不是「至少一次」——本仓已两次栽在按次升级叠副本上）；
3. 项目的门禁命令**逐字未变**（python 仓仍是 `uv run pytest`，且树里**没有** `npm run check` 漏进来）；
4. 项目手写的验证段落与凭据红线**仍在**。

三条对照真跑过：

| 注入 | 结果 |
| --- | --- |
| 门控改成 `from_patch -lt 1`（该步等于不存在） | `implement-prompt.md (planner.ts): the red-green loop survives` |
| 把区块标题改写（工具认不出） | 改写保留、不插第二段 |
| 手工把指引复制成两份 | `guidance appears 2 times, not once` |

**一条诚实的负面结果**：去掉工具里的幂等 marker 检查（`if (lines.some(...MARK...)) process.exit(4)`）
**不会**让 smoke 变红——因为迁移后锚点已消失，第二次运行在能写任何东西之前就以 `exit 3` 退出。
所以那个 marker 是**纵深防御，不是被测对象**；真正抓住叠副本的是 `== 1` 计数断言。
该断言已用「手工注入重复」直接验过会 bite。把这条写下来，是因为一个从没被看它失败过的守卫，
没人知道它是否work。
