---
title: afk-bootstrap
desc: 把一个空仓库装配成能自主跑 AFK 工作流的项目——只装配，不替它决定业务
hue: 45
related:
  - README.md
  - TEMPLATE_VERSION
  - CLAUDE.md
  - AGENTS.md
  - acceptance.feature
  - qa-plan.md
---
# afk-bootstrap

装配器：给一个目标仓库装上 `.sandcastle/` 执行层、`.github/workflows/` 治理面、
`docs/agents/` 文档路由与模板渲染出的 prompt。

## raw source

**它装配的是流程，不是业务。** bootstrap 结束时目标仓库应该能自己跑实现循环，
而它装进去的每一条规则都必须是**可执行的**——一条"描述机制"的句子如果背后没有
一步在做那件事，比缺这句话更坏，因为读的人会以为它成立。

## expanded spec

四条执行路径，各有独立的失败模式：

- [[bootstrap]] —— 首次装配（`bootstrap-afk.sh`），只写缺失的东西。
- [[upgrade]] —— 已装配项目的版本化迁移（`upgrade-afk.sh` + `TEMPLATE_VERSION`）。
- [[scaffold]] —— 原样复制的制品与按语言生成的产物。
- [[templates]] —— 渲染源；新项目的落点在 `templates/`，**不是** `scaffold/`。
- [[tools]] —— 把一段纪律接进已存在文件的接线工具。
- [[tests]] —— 装配器自检；它的缺陷会复制到每个被装配的仓库。
- [[docs-and-records]] —— 装进目标项目的文档路由与决策记录机制。

## 不变量

- **项目自有文件只在「不存在」或「仍是模板发布的形状」时写。** 存在且被项目改过 → 不动 + 报告。
- **历史记录不改**：`CHANGELOG.md`、`validation.md` 的已执行记录、`qa-plan.md` 的
  "Execution results"（含 base SHA 与模板版本）——改它们等于篡改证据。
- 装配器自身的 `.spec/` **不是**被装配的约定：它记录 afk-bootstrap 这个仓库，
  不随 `scaffold/` 进入任何目标项目。
