---
title: docs-and-records
desc: 装配进目标项目的文档路由与决策记录检查
hue: 100
related:
  - docs/GOVERNANCE-ADAPTER.md
  - docs/DELIVERY-PLAYBOOK.md
  - docs/adr
---
# docs-and-records

装进目标项目的文档路由与决策记录机制。afk-bootstrap **自己是 afk-bootstrap 项目**——
它采用自己发布的东西，`scaffold/.sandcastle/adr.check.mjs --all` 就是它自己的 CI 步骤。

## 不变量

- 决策记录检查器**判结构不判判断**：它不能判断一次改动是否值得记录，只检查记录
  读起来完不完整（有状态行、有替代方案、替代方案被真正称量过）。
- **AI 只能提议**：`adr.check.mjs` 的逃生口是提交体里的一行 `No-ADR: <理由>`——
  一句人要读的声明，不是静默。
- 空 `AFK_ADR_BASE` 是**失败**而不是降级为报告：一个误配置的 workflow 不能变成一个
  看起来通过的绿灯。
