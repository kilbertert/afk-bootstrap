# 14. 控制台显示的是工作，不是心跳 —— `verbose` 保留，只滤掉 thinking_tokens 帧

日期：2026-10-27
状态：Accepted
影响版本：`scaffold/.sandcastle/quiet-heartbeats.ts`（新增）；
`scaffold/.sandcastle/quiet-heartbeats.check.ts`（新增）；
`scaffold/.sandcastle/profile.ts`（`claudeProfile()` 里装过滤器）；
`scaffold/.github/workflows/afk-policy.yml`（CI 跑那条 check）；
`upgrade-afk.sh`（1.7.30 步骤）；`test/smoke.sh`（1.7.30 段，5 组断言）

## 背景

1.6.5 给三个 runner 加了 `logging: { type: "stdout", verbose: true }`，理由是
sandcastle 的类型化 `toolCall` 事件只认识四个工具（Bash、WebSearch、WebFetch、
Agent），Read / Edit / Write 以及每一个 `mcp__*` 调用**完全不可见**。当时的实测是
「日志里 70 次工具调用全是 Bash」，而那次会话其实也用了 Read 和 MCP。

`verbose` 的实现是 `process.stdout.write(line + "\n")`，**每一行原始 stdout 都照写**。
它没有区分「这行是工具调用」和「这行是别的东西」。

Claude Code 2.1.311 在模型思考期间会持续发这一类帧：

```
{"type":"system","subtype":"thinking_tokens","estimated_tokens":42,
 "estimated_tokens_delta":4,"session_id":"…","uuid":"…"}
```

2026-10-27 实测（本机中继 profile，一份真实的 implement 类 prompt）：

| 帧类型 | 条数 | 字节占比 |
|---|---|---|
| `system/thinking_tokens` | 227–342 | **58%** |
| `system/hook_response` | 4 | 18% |
| `system/init` | 1 | 11% |
| `assistant` | 2 | 7% |
| `result` | 1 | 3% |

也就是说 `verbose` 加进来的东西里，超过一半是心跳；真正的工具调用只有几行。
在 GitHub Actions 日志里，这等于整个可见的运行过程被心跳淹没——Auto-Test 的
PRD implement 步骤因此刷屏到无法阅读。

## 决定

**保留 `verbose`，在 sandcastle 的 verbose sink 上按帧类型过滤。**

1. 新增 `.sandcastle/quiet-heartbeats.ts`：包一层 `process.stdout.write`，丢弃
   **解析后** `type === "system" && subtype === "thinking_tokens"` 的行，其余原样写出。
2. 在 `claudeProfile()` 中调用一次。七个 runner 都通过这个函数拿到 `run()` 的参数，
   所以一处安装覆盖全部，将来加的 runner 自动继承。
3. 进程退出时打印 `[afk] dropped N thinking-token frame(s)`。

第 3 点不是装饰。帧名属于另一个产品：一旦 Claude Code 改名，过滤器会**静默失效**，
刷屏回来而没有任何东西变红。「drop 0」是唯一能区分「改名了」和「这轮确实没思考」的信号。

匹配用解析后的字段而不是子串，是因为 agent 可能在回答里引用这一行——本模块自己的
注释就是这种引用，一个被要求解释该过滤器的 agent 一定会打印它。用子串匹配会把它一起吃掉。

## 被否的方案

- **去掉 `verbose`。** 这是最短的修法，但它把 1.6.5 修的那个洞原样还回去：工具调用
  重新变成不可见。用「看不见工具调用」换「看不见心跳」，是拿一个诊断盲区换另一个。

- **在 CLI 侧关掉。** 实测两条路径都不行：
  `CLAUDE_CODE_DISABLE_THINKING=1` 仍发 232 帧，
  `CLAUDE_CODE_THINKING_DISPLAY_UPDATES=0` 仍发 342 帧。这两帧属于 stream-json 的
  契约——交互式客户端拿它当 spinner 用——CLI 没有理由省略，也就没有开关可关。

- **把 `logging` 换成 `{ type: "file" }`，只把摘要写进 Actions 日志。**
  那样 Actions 里连工具调用都没有了，问题只是从「太多」变成「太少」；而且
  `verbose` 在 file 模式下写的是同一个文件，过滤问题一点没变。

- **在 workflow 里用 `grep -v` 过滤 npm 输出。** 过滤器要放在真实运行的那一侧：
  workflow 里过滤会漏掉本地直跑 `tsx .sandcastle/implement-prd/implement-prd.ts`
  的路径，而那条路径正是排查时最常用的。

## 后果

- 每个 AFK 运行的可见行数约降一个数量级（344 → 12 行量级，实测同一条 prompt）。
- 过滤器是全局 stdout 补丁。它依赖 sandcastle **一次写一整行、带换行符**这一行为；
  没有换行的块不做判断——宁可漏掉一行心跳，也不拿半行去匹配而吃掉真实输出。
  这条行为写进了 check，sandcastle 若改变写入方式，会先红在这条断言上。
- 帧名 `thinking_tokens` 是外部契约，不由本仓决定。改名时过滤静默失效，
  退回到 1.7.29 的行为（刷屏但仍可用），退出行的 `dropped 0` 是发现它的入口。
- 升级步骤按 `1.7.29 -> 1.7.30` 补丁位门控，且**幂等**：重复执行不会装第二次。
  smoke 里用「同一 fixture 连升两次、断言 `quietThinkingHeartbeats();` 只出现一次」
  钉住这条，因为脚本按版本幂等在本仓是正常路径而不是边角情况（ADR 0013 已记过一次
  同类事故）。

## 追记 1.7.31 —— 首版违反了两条 writable-stream 契约

1.7.30 的首个消费 PR（Health-Flow #274）里，review 抓出了首版的两个缺陷。两个都不会
以「运行失败」的形式出现，这正是它们值得记下来的原因。

1. **被丢弃的写没有调用回调。** `write(chunk[, encoding][, callback])` 即使是同步完成的
   写也会调用回调。首版丢掉心跳行后直接 `return true`，于是任何 `await` 该回调的调用方
   永久挂起。stdout 是进程级的——这影响的是整个 runner 里的每一个写者，不只是 verbose
   sink。修法：按 `nextTick` 调度用户的回调。
2. **退出摘要走的是异步写。** `exit` 事件无法等待异步写刷新，而 Actions 通过管道捕获
   stdout。这个计数是本模块唯一的「帧名改了、过滤器已静默失效」的信号，在它最该出现的
   时刻却可能被丢弃。修法：用 `fs.writeSync` 直接写 fd。

**关于这两条的测试，记一件更重要的事：**为第 2 条写的行为断言是**假绿**。实测
`spawnSync` 管道下，异步写和同步写都能送达摘要——因为数据量小，在进程终止前就排空了。
一个对修复前后都通过的断言比没有断言更糟：它把缺陷认证成了正确。断言因此改成读源码，
钉住「退出摘要必须用同步写」这个真正让它安全的性质。两个变异（去掉回调、把 `writeSync`
换回 `write`）都实测会让 check 失败。

被否的补充方案：**只在消费仓修，不改模板。** 那会让每一个新脚手架和每一个消费者继续
拿到有缺陷的版本；1.7.31 的升级步骤因此识别「与 1.7.30 发布副本逐字节相同」的文件并
替换，手改过的文件只报告不覆盖。

## 追记 1.7.32 —— check 证明不了「运行真的用了它」

genesis-evidence 的升级 PR 里，review 抓到 1.7.31 剩下的两个问题，第二个比第一个重要：

3. **`writeSync` 写满管道会失败。** Node 的 stdout 在管道上是非阻塞的，读端没排空时
   同步写会 `EAGAIN`——而那正是「失败的那次运行」，是最需要诊断的时候。摘要改为回退到
   fd 2（stderr 是独立描述符），而不是被 `catch` 吞掉。
4. **check 从不验证接线。** 它直接调用模块，所以把 `claudeProfile()` 里的
   `quietThinkingHeartbeats()` 删掉，check 仍然全绿，而所有 runner 重新开始刷屏。
   这正是 `profile-network.check.ts` 存在的理由——「helper 正确、接线没了」——这一次
   是同一个形状。check 现在读 `profile.ts`，删掉或注释掉安装都会失败。

顺带修掉一个**测试自己制造的假象**：1.7.30 段的 fixture 用 perl 剥离安装时，把
`writeMcpConfig();` 后面的换行一起吃了，于是迁移忠实地在粘行的锚点后追加，看起来像是
迁移的 bug。实测定位后改的是 fixture，不是迁移——记下来是因为下一次看到「迁移把代码
粘在一起」时，先怀疑生成 fixture 的那条正则。

四个缺陷各有变异守卫，均实测：去掉 `nextTick`、`writeSync`→`write`、删掉 stderr 回退、
从 `profile.ts` 删/注释掉安装，都会让 `quiet-heartbeats.check.ts` 失败。

## 追记 1.7.33 —— 诊断信息不能污染被解析的流

health-flow 的升级 PR（第三次尝试）里，review 又抓到两条：

5. **摘要写进了 stdout。** `main.ts` 以 `console.log(JSON.stringify({…}))` 结束，
   那是这条命令的机器可读结果。任何追加到 stdout 的东西都排在它之后，于是
   `node .sandcastle/main.ts | jq` 在**一次成功的运行**上解析失败——为了一条没人要的
   诊断。摘要改为始终写 stderr。（1.7.32 的做法是「stdout 失败则回退 stderr」，方向对
   但位置错：问题不在它写失败，而在它根本不该在 stdout 上。）
6. **接线断言仍是文本匹配。** 文本只能说明调用写在哪，不能说明运行会到达它——把调用
   挪进一个没人调用的 helper，检查照样通过。现在同时断言：调用位于 `claudeProfile`
   的函数体内，且在任何提前 `return` 之前。

写第 5 条的测试时又踩了一次假绿：第一版用 `node -e 'JSON.parse(process.argv[1])'` 喂值，
`process.argv[1]` 在 `-e` 下不是那个值，解析自然失败——断言因与被测性质无关的原因变红，
和它本意要守的东西毫无关系。改成直接断言「stdout 恰好等于那句 JSON」。这是本轮第三次
「断言本身先要成立」的教训，写在这里是因为前两次（1.7.31 的异步写探针、1.7.32 的 fixture
换行）也都是同一个形状。

## 追记 1.7.34 —— 声明 check 的边界，而不是假装它没有边界

genesis-evidence 的 PR 上 review 指出：作用域断言仍然放过「`claudeProfile` 内部声明了
一个从不调用的嵌套函数，把安装放在里面」。

这条成立。彻底修它需要调用图，也就是真的执行那个函数，也就是 import
`@ai-hero/sandcastle`——而这个 check 存在的理由之一就是能在裸脚手架里跑（那里没有这个包）。
两个要求互相排斥。

决定：**保留源码断言，把边界写进 check 本身**，并在检测到嵌套无调用这一形状时打印一条
note。不失败，因为停下来修不了它；不沉默，因为沉默会让后来的读者把它当成已覆盖。

check 覆盖的形状（都实测失败）：模块作用域、另一个顶层函数、注释掉、重复安装、
排在提前 `return` 之后。它不覆盖：嵌套但未被调用的函数。这句话现在写在 check 里，
也写在这里。

这是本轮第五次「先确认断言真的在守它声称守的东西」。前四次都是修，这一次是承认。
两者的共同点是不让一个绿色的东西承担它没承担的责任。

## 追记 1.7.35 —— 「dropped 0」不是一个事实，是两个

AI-Ops 的 PR 上 review 指出：`claudeProfile` 在**校验 profile 之前**就装了钩子，而用
`logging: { type: "file" }` 的 runner 从不写 stdout。它们的摘要读起来和「一次没有思考的
控制台运行」完全一样——而恰好是这个区分，才是这条诊断存在的理由。

改成同时报告两个数：`dropped N of M console line(s)`。文件日志的 runner 打
`0 of 0`，控制台运行打 `0 of 8`，两者不再混淆。

写这条测试时又遇到一次宽松断言：第一版用 `of \d+ console line`，而「删掉
`observed += 1`」的变异照样通过——`\d+` 接受了那个永远为 0 的计数器。测试**知道**那个
数字，就必须断言那个数字。改成 `of 1 console line` 后变异立刻失败。

这是本轮第六次「先确认断言真的在守它声称守的东西」。前五次里四次是修，一次是承认。
