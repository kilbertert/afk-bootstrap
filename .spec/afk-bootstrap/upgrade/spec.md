---
title: upgrade
desc: 版本化迁移——bump 一次覆盖所有项目，锚点必须匹配真实形状
hue: 20
code:
  - upgrade-afk.sh
---
# upgrade

已装配项目的迁移。`TEMPLATE_VERSION` 是唯一版本源；**bump 是一次操作，覆盖所有项目**。

## raw source

**手工 `git mv` / `sed` 会让锚点永远匹配不上**——脚本自己的注释写着
*"a half-migrated file is worse than an unmigrated one"*。改约定只走：
改 `templates/` + `scaffold/` + `bootstrap-afk.sh` → 追加一个新版本步骤 → bump →
对项目跑 `upgrade-afk.sh <target>`。

## 不变量

- **锚点取「项目无关的那一行」**：五个仓库里同一条命令写法各异，锚在整行会让多数项目静默跳过。
  取那一行里跨仓库完全相同的最短子串，且**按行匹配**而非子串匹配。
- **门控只写 minor**：`to_patch -ge N` 读的是目标版本，模板升到下一个 minor 后它仍为真，
  老步骤会在**每次**升级上重跑。patch 不是"是否已包含该特性"的代理。
- **老步骤里的 `cp` 必须有 `[ ! -e "$TARGET/..." ]` 守卫**：无条件 `cp` 会在项目改动被
  后续步骤看见之前覆盖它，而且**永远测不出来**（覆盖后的文件看起来正是模板想要的）。
- **变更是白名单**：新步骤改了哪些路径，就要在 publish 段自己 `publish_file`；
  删除/改名要用 `publish_delete()`（先备份、登记、再删，回滚时恢复）。
- 变更报告的文件列表是**固定**的：新步骤改的文件不加进去就会被静默迁移。
