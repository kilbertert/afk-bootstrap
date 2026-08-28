# afk-bootstrap

把「想法 → PRD → issue → AFK 实现 → 人工 QA → 后台修复」这条软件开发工作流，一键装配进任意项目。

```
想法 → grill → PRD(父 issue) → native sub-issues → AFK/Sandcastle Docker
     → draft PR → 确定性 CI → 人工 QA → QA 反馈 issue → 后台 AFK 修复 → 合并
```

本仓库是**装配工具**，不是一个运行时。它把一个项目从"普通仓库"变成"能跑 AFK agent 的仓库"：
从已验证的基线仓库（`Auto-Test`，即 `mattpocock/course-video-manager` 的最小适配移植）复制可移植件，
再按目标项目的语言生成差异件。

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
| `--repo` | 从 origin 推断 | 写入 `to-prd-project` skill 的 GitHub 仓库名 |
| `--baseline` | `/home/claude/Projects/Auto-Test` | 可移植件的复制来源 |
| `--no-build` | 构建 | 跳过 `docker build`（改文件时用，先看 diff） |

**它只生成文件，绝不提交、不推送。** 交付由宿主 runner 负责（branch → PR → CI → merge）。

---

## 装配后项目长什么样

### 从基线原样复制（可移植、读服务器本地配置）

- `.sandcastle/`：`main.ts`（单 issue runner）、`planner.ts`（planner 循环，`pnpm ralph`）、`profile.ts`、`run-with-retry.ts`、`retry-feedback.ts`、`run-with-extraction.ts`、`plan/implement/review/merge-prompt.md`、`to-issues-prd/`、`implement-prd/`、`write-prd-pr/`、`implement/`、`write-pr/`、`review/`、`implement-pr/`、`update-branch/`、`architecture-review/`、`.env.example`、`.gitignore`
- `.claude/skills/`：`to-prd-project`、`to-issues-project`
- `.github/workflows/`：`agent-to-issues-prd`、`agent-implement-prd`、`agent-implement`、`agent-review`、`agent-implement-pr`、`agent-update-branch`、`agent-promote-queued`、`architecture-review`

### 按语言生成

- `.sandcastle/implement.md` —— AFK 验证门禁：
  - node：`npm run check`
  - python：`uv sync --extra dev && uv run pytest && uv run ruff check`
- `.sandcastle/implement-prd/prompt.md` —— PRD 子 issue prompt（同一门禁）
- `.sandcastle/Dockerfile` —— 沙箱镜像（node 24 + claude-code/codex + AFK_PROFILE 分发；python 项目再加 python3 + uv）
- `package.json` —— 最小 runner manifest（`afk` + `prd:to-issues` 脚本、`tsx`、`@ai-hero/sandcastle`）；已存在则合并，否则新建并生成 `package-lock.json`
- 顺带修一个字符串：`to-prd-project` skill 里的仓库名 → 你的仓库

---

## 一个真实例子：genesis-evidence

```
./bootstrap-afk.sh ~/Projects/genesis-evidence --language python --repo kilbertert/genesis-evidence
```

生成了 20 个文件 → 开 PR #70 → `quality` CI 通过 → squash 合并 → 本地 main 同步。
随后：`sandcastle:genesis-evidence` 镜像构建 ✅、`AFK_PROFILE=claude-ark` 变量设置 ✅、4 个 `agent:*` labels 创建 ✅。

```bash
cd ~/Projects/genesis-evidence
npm install                        # 首次：生成 node_modules
AFK_PROFILE=claude-ark pnpm afk -- <一个 open 的 issue 号>
```

---

## 两条执行路径（重要：不要误读为"背离上游"）

AFK 有**两条并行机制**，别混为一谈（早期会话曾误读并传播错误的"我们偏离上游"结论）：

1. **Planner 循环 `pnpm ralph`** —— 与上游 `main.ts` 机制**完全一致**：
   `createSandbox({ branch, sandbox: docker() })` 建**每任务的 docker git worktree**（挂载到 `/home/agent/workspace`），`sandbox.close()` 自动清理（等价上游 `await using`）。worktree 生命周期由 sandcastle 库负责，`.sandcastle/worktrees/` 已 gitignore。

2. **Label-Action implement/review** —— 跑在 **self-hosted runner 的持久 workspace**：`git checkout -b` + `docker()` 容器（做 profile/凭据注入）。这**不是**每任务 docker worktree。注：上游同路径用 `noSandbox()`（裸 runner 无容器）；我们用 `docker()` 是**有意的增强**（隔离 + profile 注入），不是抄错。

**真正差异是 hosted vs self-hosted**：hosted runner 每次全新 workspace，self-hosted 复用同一 `_work/` → `agent/*` 分支会累积。上游在 self-hosted 上同样如此——这不是我们独有缺陷。

---

## 模型供应商（服务器全局，新项目零新凭据）

`claude` / `claude-ark` / `psydo` / `aliyun-deepseek` 四个 profile 都在服务器本地，读服务器文件
（`/home/claude/cliproxyapi/settings.ark.json`、psydo key、aliyun CSV 等）。新项目只要选一个：

```bash
gh variable set AFK_PROFILE --repo <owner/name> --body claude-ark   # 或 psydo / aliyun-deepseek
```

默认模型：`claude-ark → glm-latest`，`psydo → gpt-5.6-sol`，`aliyun-deepseek → deepseek-v4-pro-0813`。
也可显式覆盖：`AFK_PROFILE=claude-ark AFK_MODEL=<model> pnpm afk -- <issue>`。

### 模型稳定性（慢 / 挂起保护）

部分供应商（尤其 aliyun-deepseek）在完整 session 下会慢或挂起 stall。已内置
双层保护，可调：

```bash
# 1) codex 单请求超时 / 重试（秒）
AFK_REQUEST_TIMEOUT=120 AFK_REQUEST_RETRIES=2

# 2) planner 每步 wall-clock 上限（秒；0 = 不限制）
AFK_RUN_TIMEOUT=3600     # implement / review 每步
AFK_MERGE_TIMEOUT=3600   # merger 一步
```

超时会把挂起的 agent 当作错误（BLOCKED）并继续，而不是让整个 planner 无限卡住。

---

## 前置条件与已知的坑

| 坑 | 说明 |
|---|---|
| pnpm 11 阻止 esbuild 构建脚本 | `pnpm afk` 会先自动跑 `pnpm install`，pnpm 11（`strictDepBuilds`）默认禁止未审核的 build script → `ERR_PNPM_IGNORED_BUILDS: esbuild`，agent 还没启动就退出。工具已生成 `pnpm-workspace.yaml`（`allowBuilds: esbuild: true`）根治，**别手改回 false** |
| 容器必须匹配项目工具链 | 镜像里缺项目依赖（如 Playwright、python/uv），agent 在容器内跑不了验证 → 误报 `<promise>BLOCKED</promise>`。`Dockerfile.node` 里有 playwright 的注释开关，需要时打开 |
| self-hosted runner 是仓库级的 | 个人账号无法跨仓库共享 runner（需 Organization）。每个要用 Actions 的仓库要么注册自己的 runner，要么本地跑 `pnpm afk` |
| 链式触发需要 `AGENT_PAT` secret | 没有它，一个子 issue 实现完不会自动触发下一个 |
| 首次要 `npm install` | 装配只生成 lockfile；本地跑 `pnpm afk` 前要 `npm install` |
| issue 号别填错 | `-- <号码>` 必须是一个 **open 的 issue**，不能是 PR 号（PR 和 issue 共用同一数字空间） |
| 本仓库提交受 git guard 约束 | 别直接在 `main` 提交；用任务分支 + fast-forward |

---

## 设计原则（为什么要这样拆）

- **复制，不重写**：可移植件从基线运行时复制，单一事实源，基线演进了新项目自动跟进。
- **只适配 4 处**：implement.md、PRD prompt、Dockerfile、package.json——语言相关的全部差异就这些。
- **宿主 runner 拥有交付**：AFK agent 在容器里只做「实现 → 检查 → 提交」，推分支/开 PR/合并永远是人或宿主 runner 的事。
- **凭据只在服务器本地**：仓库里永远不放 API key；profile 桥只读宿主机文件。
