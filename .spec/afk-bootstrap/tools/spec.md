---
title: tools
desc: 接线工具——只解析定位、拼接文本、再解析断言
hue: 140
code:
  - tools/policy-wire.py#steps_of
related:
  - tools/ticket-wire.py
  - tools/ticket-writeback-wire.py
  - tools/add-search-duty.mjs
  - tools/add-ticket-duty.mjs
  - tools/replace-ticket-duty.mjs
---
# tools

把一段纪律**接进**已存在的文件里：workflow 的某一步、prompt 的某一段。

## raw source

树的锚（唯一一处）：`steps_of` 决定「哪个 job 的哪一步」——它错了，后面所有
定位都落在错的步骤上。其余工具按 related 归入本节点（覆盖网），不逐文件锚。

**这一类改动一轮一轮地漏，是本文档记录得最细的一处。** 给 `afk-policy.yml` 的 checkout
补两行，六轮全在同一个地方，每一轮的判据都比上一轮精细，每一轮都被下一个兄弟绕过：

| 判据 | 漏掉的 |
| --- | --- |
| `"fetch-depth" in text` | 注释里的键就算已配置 |
| `^\s*fetch-depth:\s*0\s*$` | 别的 job 的 checkout 替它回答 |
| 替换标量值 | 行内注释 `fetch-depth: 1  # fast` 匹配不到 |
| YAML 解析后按结构找 | 重命名步骤 → **重复插入键**，YAML 取后者，浅值胜出 |
| 整份替换 | 项目自有的 workflow 动不了，回退只提了一处缺口 |

前五版都在「编辑没发生」时打印了成功。

## 不变量

- **判据落在解析结果上，动作落在那一步自己的行范围上，改完再解析一次断言结果。**
- **绝不用 `yaml.safe_dump` 重写文件**：它把 `on:` 写成 `true:`（YAML 1.1），
  并把整份 workflow 的引号与块标量样式改掉。而 `yaml.safe_load` 读 `on:` 本来就得到
  `True`——所以"`on:` 还在吗"这个判据必须落在**文本**上，落在 parse 上会在未改动的文件上就失败。
- **缺失才加**：项目自有的步骤从不触碰。
- **退出码 3 是报告不是硬失败**：迁移无法知道操作员会不会满足它，而拒绝发布会把同一版里
  其他修复一起搁浅。
- **形状比较的归一化必须两侧都做**：只从脚手架侧削、不削候选侧，结果所有仓库都不匹配，
  升级什么都不做，而 manifest 照常推进。
