# afk-bootstrap

把「想法 → grill → PRD → issue → AFK 实现 → 人工 QA → 后台修复」这条软件开发工作流，一键装配进任意项目。

```
想法 → grill → PRD(父 issue) → native sub-issues → AFK/Sandcastle Docker
     → draft PR → 确定性 CI → 人工 QA → QA 反馈 issue → 后台 AFK 修复 → 合并
```

本仓库是**装配工具**，不是一个运行时。它把一个项目从"普通仓库"变成"能跑 AFK agent 的仓库"：
从仓库内版本化的 `scaffold/` 复制通用载荷，再按目标项目的语言生成差异件。
Auto-Test 是首个验证项目和普通消费者，不再承担模板发布职责。

服务器级 consensus 与 AFK 执行适配器的责任边界见
[`docs/GOVERNANCE-ADAPTER.md`](docs/GOVERNANCE-ADAPTER.md)。

> **这份 README 是给人看的。** 给智能体（Codex / Claude Code）看的版本是 [`AGENTS.md`](AGENTS.md)。
>
> **交付剧本**（agent 如何把新项目完整配置好、零手动步骤）在
> [`docs/DELIVERY-PLAYBOOK.md`](docs/DELIVERY-PLAYBOOK.md) —— 在**本工具仓库的会话**里
> 说"配置好 X 仓库"，agent 会照它全自动交付。

---

## 快速开始

```bash
# Node.js 项目
./bootstrap-afk.sh ~/Projects/某-node-仓库 --language node

# Python (uv) 项目
./bootstrap-afk.sh ~/Projects/genesis-evidence --language python --repo kilbertert/genesis-evidence
```

| 参数 | 默认 | 作用 |
|---|---|---|
| `<target>` | 必填 | 目标项目路径（git 仓库，处于默认分支） |
| `--language` | `node` | 工具链：`node` / `python`，决定 implement.md、PRD prompt、Dockerfile |
| `--repo` | 从 origin 推断 | 记录目标 GitHub 仓库名 |
| `--cron-hour` | `9` | architecture-review 的 UTC 小时。**同一台宿主机上的每个项目要给不同的小时**，理由见下 |
| `--no-build` | 构建 | 跳过 `docker build`（改文件时用，先看 diff） |

**它只生成文件，绝不提交、不推送。** 交付由宿主 runner 负责（branch → PR → CI → merge）。

### 为什么 `--cron-hour` 要逐项目分配

同一台宿主机上的所有项目解析到**同一个上游凭据文件**
（`~/cliproxyapi/settings.<x>.json`），因此共享同一个并发上限。一次
architecture-review 实测跑 **20–68 分钟**（不是几分钟），所以：

- 分钟级错开（例如 7 分钟偏移）**不能**把它们分开——重叠仍有 20–60 分钟；
  必须按小时错开。
- 若两个项目共用同一小时，它们会争同一个并发额度，然后以
  `429 concurrency reached, current: 6, limit: 5` 失败。

**升级已有项目时 `--cron-hour` 是必需的**（`upgrade-afk.sh --cron-hour`），
只有记录里已经有时才可省略。这不是形式：**把旧值照搬是不行的**——本机五个项目
原本都在 09:00，「保留」等于把碰撞原样复制一遍。哪些小时空闲是 **fleet 级信息**
（取决于谁和谁共用同一个凭据文件），而脚本只看得到单个项目，所以它**问**而不是猜。


分配的小时记录在 `.afk-bootstrap.json` 的 `cron_hour`，**下一个项目据此挑空闲的**。
它**故意不从项目名 hash 推导**：hash 会碰撞——本 fleet 五个 slug 里有两个落进同一
小时——而**静默碰撞正是这个字段要消除的缺陷**。默认值 `9` 只保证孤立项目能跑，不是
给同一凭据上第二个项目用的。

### 升级已装配的项目

`bootstrap-afk.sh` 见到 `.sandcastle/` 就拒绝，因此它只能新建。已有项目走升级脚本：

```bash
# 先看会改什么
./upgrade-afk.sh ~/Projects/某仓库 --dry-run
./upgrade-afk.sh ~/Projects/某仓库
```

它按版本逐步迁移，并把新版本号写进 `.afk-bootstrap.json`。**锚点式，不是模板重渲染**：
装配后的 Dockerfile 归项目所有（README 就让项目自己打开 Playwright 块），整体重渲染会
把它悄悄改回去。因此每一步只匹配上一个模板确实生成的那几行；锚点对不上就拒绝，绝不猜。
项目自己的散文（如 `docs/afk-workflow.md`）只报告不修改——那是项目的事实来源。

**拒绝即无副作用**：所有改动先写进暂存副本，全部步骤都成功才发布回项目。否则前一步
已改、后一步失败，就会留下「Dockerfile 已是新版、元数据还写着旧版」的半迁移状态。

**一个坑**：升级后必须先用新 Dockerfile 重建镜像，再改 `AFK_PROFILE` 变量。顺序反了，
旧镜像没有对应的 dispatch 分支，wrapper 直接 `exit 2`。

---

## 装配后项目长什么样

### 从本仓库 `scaffold/` 原样复制

- `.sandcastle/`：`main.ts`（单 issue runner）、`planner.ts`（planner 循环，`pnpm ralph`）、`profile.ts`、`policy-check.mjs`、`consensus-contract.json`、`run-with-retry.ts`、`retry-feedback.ts`、`run-with-extraction.ts`、`plan/implement/review/merge-prompt.md`、`implement-prd/`、`write-prd-pr/`、`implement/`、`write-pr/`、`review/`、`implement-pr/`、`update-branch/`、`architecture-review/`、`.env.example`、`.gitignore`
- `.github/workflows/`：`agent-implement-prd`、`agent-implement`、`agent-review`、`agent-implement-pr`、`agent-update-branch`、`agent-promote-queued`、`architecture-review`、`afk-policy`
- `docs/agents/`：官方 skills 所需的 GitHub tracker、triage labels、domain pointers

### 按语言生成

- `.sandcastle/implement.md` —— AFK 验证门禁：
  - node：`npm run check`
  - python：`uv sync --extra dev && uv run pytest && uv run ruff check`
- `.sandcastle/implement-prd/prompt.md` —— PRD 子 issue prompt（同一门禁）
- `.sandcastle/Dockerfile` —— 沙箱镜像（node 24 + claude-code/codex + AFK_PROFILE 分发；python 项目再加 python3 + uv）
- `package.json` —— 最小 runner manifest（`afk` + `ralph` 脚本、`tsx`、`@ai-hero/sandcastle`）；已存在则合并，否则新建并生成 `package-lock.json`
- `.afk-bootstrap.json` —— 记录 SemVer 模板版本、consensus 版本兼容窗口、语言和 GitHub 仓库名
- `AGENTS.md` / 已有 `AGENTS.override.md` / `CLAUDE.md` —— 追加短 managed block，不覆盖项目内容

---

## 一个真实例子：genesis-evidence

```
./bootstrap-afk.sh ~/Projects/genesis-evidence --language python --repo kilbertert/genesis-evidence
```

生成项目内 AFK 载荷 → 开 PR #70 → `quality` CI 通过 → squash 合并 → 本地 main 同步。
随后：`sandcastle:genesis-evidence` 镜像构建 ✅、`AFK_PROFILE=claude-stepfun` 变量设置 ✅、4 个 `agent:*` labels 创建 ✅。

```bash
cd ~/Projects/genesis-evidence
npm install                        # 首次：生成 node_modules
AFK_PROFILE=claude-stepfun pnpm afk -- <一个 open 的 issue 号>
```

---

## 两条执行路径（重要：不要误读为"背离上游"）

AFK 有**两条并行机制**，别混为一谈（早期会话曾误读并传播错误的"我们偏离上游"结论）：

1. **Planner `pnpm ralph`** —— `createSandbox({ branch, sandbox: docker() })` 建**每任务的 docker git worktree**（挂载到 `/home/agent/workspace`），`sandbox.close()` 自动清理；完成的任务汇总到一个 delivery branch，由宿主 push 并开 PR，不直推 `main`。

2. **Label-Action implement/review** —— 跑在 self-hosted runner，但分成三个目录：`controller/` 固定使用当前 `main` 的受信脚本与依赖，`candidate/` 只把 PR 分支挂进 `docker()`，`delivery/` 从验证过的 Git bundle 导入结果后才短时使用写 token 推送。三条 PR mutation workflow 只接受仓库所有者创建的同仓库 PR；不是每任务 docker worktree，也不在宿主执行 candidate 的 `npm ci` 或 `.sandcastle/*.ts`。

**真正差异是 hosted vs self-hosted**：hosted runner 每次全新 workspace，self-hosted 复用同一 `_work/`。受信 controller/candidate/delivery 分目录 checkout 和精确 head 校验让重复运行不再依赖遗留的本地 `main` 或任务分支状态。

---

## 模型供应商（服务器全局，新项目零新凭据）

模板只保留两个 profile，端点都是宿主上的一个 settings 文件，只读挂进沙箱：

| profile | 端点 | 宿主文件 |
|---|---|---|
| `claude` | Anthropic API | 宿主 shell 已导出的凭据 |
| `claude-stepfun` | StepFun 原生 Anthropic Messages API | `~/cliproxyapi/settings.stepfun.json` |

```bash
gh variable set AFK_PROFILE --repo <owner/name> --body claude-stepfun
```

默认模型由该 settings 文件里的 `ANTHROPIC_DEFAULT_*_MODEL` 决定。文件在别处时用
`AFK_STEPFUN_SETTINGS` 指过去。

**为什么是挂载而不是烤进镜像**：烤进去的密钥会留在镜像层里，任何能拉这个镜像的人
都能读出来；轮换密钥还必须记得 `--no-cache`，因为 secret 挂载不会让层缓存失效。
挂载把密钥留在宿主，轮换就是改一个文件。

**已退役**：`claude-ark`、`agentrouter`、`psydo`、`aliyun-deepseek`。前三个解析到
`cliproxyapi/` 下上游配额已耗尽的 settings 文件，选中必然失败；`aliyun-deepseek`
曾是唯一的 Codex-provider profile，退役它也让 AFK 不再需要 Codex agent 路径。

### 模型稳定性（挂起保护）

planner 每步有 wall-clock 上限（秒；0 = 不限制）：

```bash
AFK_RUN_TIMEOUT=3600     # implement / review 每步
AFK_MERGE_TIMEOUT=3600   # merger 一步
```

超时会把挂起的 agent 当作错误（BLOCKED）并继续，而不是让整个 planner 无限卡住。

单请求级的超时/重试（`AFK_REQUEST_TIMEOUT`）随 `aliyun-deepseek` 的 Codex
provider 一起退役了——那是它唯一的作用点。两个现存 profile 都走 Claude Code,
挂起由上面的 wall-clock 兜住。

---

## 前置条件与已知的坑

| 坑 | 说明 |
|---|---|
| pnpm 11 阻止 esbuild 构建脚本 | `pnpm afk` 会先自动跑 `pnpm install`，pnpm 11（`strictDepBuilds`）默认禁止未审核的 build script → `ERR_PNPM_IGNORED_BUILDS: esbuild`，agent 还没启动就退出。工具已生成 `pnpm-workspace.yaml`（`allowBuilds: esbuild: true`）根治，**别手改回 false** |
| 容器必须匹配项目工具链 | 镜像里缺项目依赖（如 Playwright、python/uv），agent 在容器内跑不了验证 → 误报 `<promise>BLOCKED</promise>`。`Dockerfile.node` 里有 playwright 的注释开关，需要时打开 |
| self-hosted runner 是仓库级的 | 个人账号无法跨仓库共享 runner（需 Organization）。每个要用 Actions 的仓库要么注册自己的 runner，要么本地跑 `pnpm afk` |
| Actions 创建 PR/链式触发需要 `AGENT_PAT` secret | 它只留在宿主 runner 的 delivery 步骤；缺失或权限失败会进入 `agent:blocked`，不会退回到无法触发下游 workflow 的 `GITHUB_TOKEN`。容器只接收 `AFK_AGENT_READ_TOKEN` |
| 首次要 `npm install` | 装配只生成 lockfile；本地跑 `pnpm afk` 前要 `npm install` |
| issue 号别填错 | `-- <号码>` 必须是一个 **open 的 issue**，不能是 PR 号（PR 和 issue 共用同一数字空间） |
| 本仓库提交受 git guard 约束 | 别直接在 `main` 提交；用任务 worktree + PR + CI |

---

## 设计原则（为什么要这样拆）

- **一个发布单元**：通用载荷、生成逻辑、文档和 smoke 都在本仓库，同一个 PR 一起验证。
- **复制，不链接**：目标仓库获得可审查的版本化副本，不依赖 Auto-Test 工作树、符号链接或 submodule。
- **只适配 4 处**：implement.md、PRD prompt、Dockerfile、package.json——语言相关的全部差异就这些。
- **宿主 runner 拥有交付**：AFK agent 在容器里只做「实现 → 检查 → 提交」，推分支/开 PR/合并永远是人或宿主 runner 的事。
- **受信控制面**：PR mutation 的 host 代码固定来自 `main`，candidate 只在 Docker 中运行；Git bundle 是 candidate 到干净 delivery checkout 的唯一提交交接面。
- **portable checker**：容器内执行 `node .sandcastle/policy-check.mjs commit`；宿主在每次 push 前执行 `... delivery`。它验证 SemVer 兼容、结构化例外、任务分支和 diff，不替代 Git hooks 或 GitHub Ruleset。
- **凭据只在服务器本地**：仓库里永远不放 API key；profile 桥只读宿主机文件。
