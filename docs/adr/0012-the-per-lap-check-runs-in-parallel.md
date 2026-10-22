# 12. 每圈检查跑并行 —— agent 每轮迭代都要付的那笔钱

日期：2026-10-19
状态：Accepted
影响版本：`templates/implement.python.md`（检查命令加 `-n auto`）；`scaffold/.sandcastle/sandbox-prepare.sh`（指引里补一行安装）；`upgrade-afk.sh`（1.7.28 步骤，并把归一化扩到两种命令拼写）

## 背景

AFK 的 implement 模板让 agent 在**每次提交前**跑：

```
uv sync --extra dev && uv run pytest && uv run ruff check
```

`uv run pytest` 是**串行**的。实测（AI-Ops，2026-10-22）：

| 跑法 | 耗时 |
|---|---|
| 串行 | **249.7 s** |
| `-n auto`（8 核） | **46.4 s** |
| `-n 4` | 72.5 s |

同样的测试，5.4 倍差距。而这是**每圈**都跑的命令 —— 一个 issue 修一次评审意见就一圈。

## 决策

模板里的 python 检查命令改成 `uv run pytest -n auto`。

## 被否掉的替代形态

- **把 `pytest-xdist` 写进 `pyproject.toml` 的 dev 依赖。** 最自然、也最容易被想到。
  它输在**改 `uv.lock`**：本机多个仓的 CD 拿 lock 的哈希与生产主机比对，加一个测试
  依赖会让部署拒绝运行，直到有人按人工流程更新主机环境。一个测试提速不该连带一次
  生产环境变更。

- **`--with pytest-xdist`（uv 的临时覆盖环境）。** 一行、不碰 lockfile，看起来完美。
  实测否决（ADR 0011 的同一课）：它会把整个进程换到 `~/.cache/uv/builds-v0/.tmp*/`，
  `sys.executable` 与 `purelib` 一并改道。health-flow 有测试恰好依赖 purelib，当场变红。

- **只改模板，不管沙箱。** 最短的 diff。它输在**会静默失败**：沙箱只 `uv sync`，
  不装 xdist，agent 拿到 `unrecognized arguments: -n`，然后最可能的行为是
  **把 `-n` 去掉**——收益归零，且没有任何东西报警。

- **只在 CI 里并行，本地/agent 保持串行。** 看起来更保守。它输在**搞错了谁在付钱**：
  CI 一个 PR 跑一次；agent 每圈跑一次、一个 issue 可能十几圈。串行真正贵的地方是后者。

## 后果

- agent 每圈省约 **203 秒**（249.7 → 46.4）。按一 issue 十圈算，约 **34 分钟**。
- **代价（说清楚）**：`-n auto` 在 8 核沙箱里会与其他进程争抢。实测 `-n 4`（留一半核
  给 agent）是 72.5s，仍比串行快 3.4 倍；选 `auto` 是因为收益差距够大，且争抢只会让它
  退化到 `-n 4` 附近的量级，不会比串行更差。
- **一处跨版本失效，已修**：1.7.27 那个 `cmp` 守卫用「归一化掉语言替换再比对」判断
  『项目有没有手改过』。它只认识**旧**的 python 命令拼写，于是升级到 1.7.28 的消费仓
  （文件里已是 `-n auto`）会被判成手改过、拒绝下发、且**不报错**。归一化现在同时认识
  两种拼写，smoke 里有一条专门的跨版本用例钉住它。
- **仍未做**：node 侧没有等价的并行开关检查。`npm run check` 的内容由各项目自己定，
  本记录不替它们决定。
