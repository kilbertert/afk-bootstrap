---
title: templates
desc: 渲染源——按语言生成目标项目的 prompt 与文档
hue: 80
related:
  - templates/prompt.node.md
  - templates/prompt.python.md
  - templates/implement.node.md
  - templates/implement.python.md
  - templates/CLAUDE.md
  - templates/GLOSSARY.md
  - templates/CODING_STANDARDS.md
  - templates/AFK-MANAGED-BLOCK.md
  - templates/afk-workflow.md
  - templates/Dockerfile.node
  - templates/Dockerfile.python
  - templates/codex-config.toml.snippet
  - templates/package.json
  - templates/pnpm-workspace.yaml

---
# templates

按语言（node / python）渲染成目标项目 prompt 与文档的模板。

## raw source

**新项目的落点在 `templates/`。** 改 `scaffold/` 只对升级路径生效——
新 bootstrap 出来的项目走的是 `templates/`。两边都要改，否则新项目缺纪律、要等下次升级补。

## 不变量

- **Python 模板里同时有 `{` 字面量与 GitHub 表达式时，绝不能用 `str.format`**：
  `${{ … }}` 会被 format 变成 `${ … }`，生成的 workflow 里**每个表达式全废**，
  而 YAML 照样解析、断言照样过。唯一靠得住的判据是**逐字节**——把目标文件还原成上一版
  形态 → 跑一遍生成器 → 与脚手架 `diff` 为空。
- **生成器的输出就是脚手架本身**，别手工维护第二份：跑一遍生成器、把输出拷成脚手架，
  再用「还原 → 重新生成 → diff」证明两者一致。
- 管理块（`AFK-MANAGED-BLOCK.md`）是**注入**而非覆盖：目标项目已有的 CLAUDE.md/AGENTS.md 内容必须保留。
