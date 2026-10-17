---
title: bootstrap
desc: 首次装配——只写缺失的东西
hue: 30
code:
  - bootstrap-afk.sh
---
# bootstrap

把一个目标仓库装配成 AFK 项目：`--language node|python`、`--repo owner/name`、`--cron-hour`。

## raw source

**幂等是它的定义，不是它的性质。** 重跑不得覆盖项目改动：只写缺失的文件，
已存在且被项目改过的一律不动。

## 不变量

- `--repo` 必须是合法 `owner/name`；**非法输入不得写任何 scaffold 文件**（smoke 逐条断言）。
- `--cron-hour` 要**逐项目分配**：AFK 项目共享一份模型凭据，同一小时叠加会互相挤。
- 目标必须已有 git remote，否则提前退出（smoke 的 fixture 显式给了 remote）。
