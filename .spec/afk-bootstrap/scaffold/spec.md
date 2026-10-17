---
title: scaffold
desc: 原样复制进目标项目的制品——不是渲染源
hue: 60
related:
  - scaffold/.sandcastle/policy-check.mjs
  - scaffold/.sandcastle/adr.check.mjs
  - scaffold/.sandcastle/repo-map.mjs
  - scaffold/.sandcastle/repo-map.check.mjs
  - scaffold/.sandcastle/trusted-pr-delivery.sh
  - scaffold/.github/workflows/afk-policy.yml
  - scaffold/.github/workflows/architecture-review.yml
  - scaffold/.github/workflows/agent-implement-pr.yml
  - scaffold/.github/workflows/agent-implement-prd.yml
  - scaffold/.github/workflows/agent-implement.yml
  - scaffold/.github/workflows/agent-promote-queued.yml
  - scaffold/.github/workflows/agent-review.yml
  - scaffold/.github/workflows/agent-update-branch.yml
  - scaffold/.sandcastle/.env.example
  - scaffold/.sandcastle/.gitignore
  - scaffold/.sandcastle/architecture-review/architecture-review.ts
  - scaffold/.sandcastle/architecture-review/extraction.md
  - scaffold/.sandcastle/architecture-review/prompt.md
  - scaffold/.sandcastle/consensus-contract.json
  - scaffold/.sandcastle/implement-pr/extraction.md
  - scaffold/.sandcastle/implement-pr/implement-pr-output.ts
  - scaffold/.sandcastle/implement-pr/implement-pr.ts
  - scaffold/.sandcastle/implement-pr/prompt.md
  - scaffold/.sandcastle/implement-prd/implement-prd.ts
  - scaffold/.sandcastle/implement-prd/prompt.md
  - scaffold/.sandcastle/implement-prompt.md
  - scaffold/.sandcastle/implement/implement.ts
  - scaffold/.sandcastle/implement/prompt.md
  - scaffold/.sandcastle/main.ts
  - scaffold/.sandcastle/mcp-config.check.ts
  - scaffold/.sandcastle/mcp-config.ts
  - scaffold/.sandcastle/merge-prompt.md
  - scaffold/.sandcastle/plan-prompt.md
  - scaffold/.sandcastle/planner.ts
  - scaffold/.sandcastle/profile-network.check.ts
  - scaffold/.sandcastle/profile-network.ts
  - scaffold/.sandcastle/profile.ts
  - scaffold/.sandcastle/retry-feedback.ts
  - scaffold/.sandcastle/review-prompt.md
  - scaffold/.sandcastle/review/axis-prompt.md
  - scaffold/.sandcastle/review/extraction.md
  - scaffold/.sandcastle/review/parse-diff-lines.ts
  - scaffold/.sandcastle/review/prompt.md
  - scaffold/.sandcastle/review/review-output.ts
  - scaffold/.sandcastle/review/review.ts
  - scaffold/.sandcastle/run-with-extraction.ts
  - scaffold/.sandcastle/run-with-retry.ts
  - scaffold/.sandcastle/sandbox-prepare.check.ts
  - scaffold/.sandcastle/sandbox-prepare.sh
  - scaffold/.sandcastle/ticket-check.mjs
  - scaffold/.sandcastle/ticket-writeback.sh
  - scaffold/.sandcastle/update-branch/extraction.md
  - scaffold/.sandcastle/update-branch/prompt.md
  - scaffold/.sandcastle/update-branch/update-branch.ts
  - scaffold/.sandcastle/write-pr/prompt.md
  - scaffold/.sandcastle/write-pr/write-pr.ts
  - scaffold/.sandcastle/write-prd-pr/prompt.md
  - scaffold/.sandcastle/write-prd-pr/write-prd-pr.ts
  - scaffold/docs/adr/0001-native-planning-and-review-orchestration.md
  - scaffold/docs/adr/0002-trusted-pr-control-plane.md
  - scaffold/docs/agents/architecture-decisions.md
  - scaffold/docs/agents/domain.md
  - scaffold/docs/agents/issue-tracker.md
  - scaffold/docs/agents/ticket-contract.md
  - scaffold/docs/agents/triage-labels.md

---
# scaffold

**原样复制**进目标项目的文件。它们不是模板，不经过渲染。

## 为什么与 `templates/` 分开

`scaffold/` 与 `templates/` 是**同一件事的两个来源**，而新项目的落点常常在
`templates/`——`implement-prd/prompt.md` 由 `bootstrap-afk.sh` 从
`templates/prompt.<lang>.md` 渲染，scaffold 里那份**根本不是它的来源**
（它连 `policy-check.mjs commit` 这个锚点都没有）。

**改纪律要两边都改，且各自按各自的来源测**；只改一边时，新装配的项目缺纪律、
要等下次升级补。

## 不变量

- 这些文件里的**规则就是闸门实际执行的规则**——被覆盖比 prompt 被覆盖严重得多。
  迁移时策略与 ADR 检查器一致：项目副本不存在 → 安装；存在 → **不动** + 人工合并清单。
- 是**本版本首次引入**的文件不存在"上一版夹具"，于是"是旧版"与"是项目改的"在证据上
  不可分——按更保守的一侧处理（报告，不覆盖）。
