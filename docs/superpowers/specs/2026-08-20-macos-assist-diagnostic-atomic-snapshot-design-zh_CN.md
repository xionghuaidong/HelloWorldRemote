# macOS Assist 诊断原子快照设计

[English](2026-08-20-macos-assist-diagnostic-atomic-snapshot-design.md) | [简体中文](2026-08-20-macos-assist-diagnostic-atomic-snapshot-design-zh_CN.md)

## 1. 背景

macOS 无人值守权限控制器必须在一个 60 秒 hard deadline 内结束。权限启用失败且 `debug_level != 0` 时，当前 workflow step 必须打印现有固定 19 字段诊断摘要。原始 vendor 输出、凭据和远程连接数据不得出现在日志或 artifact 中。

当前实现要求 worker 在同一个 deadline 临近结束时完成 attempt 分类、结果聚合、摘要渲染和退出，再由 supervisor replay 捕获的输出。原生运行证明，这使诊断交付依赖剩余的调度和启动时间。增加 finalization 或 post-attempt reserve 只能改变时序，不能建立稳定的所有权边界。

本设计使用增量提交、由 supervisor 管理的诊断快照替代窗口末尾的集中报告生成。它取代基于 `ASSIST_ALLOW_POST_ATTEMPT_RESERVE_MILLISECONDS` 的未提交时序 reserve 候选方案。

## 2. 目标

- 保持现有成功输出：`ASSIST_STATE=enabled`。
- 保持现有 19 个诊断字段的名称、数量和含义不变。
- 仅在权限启用失败、`debug_level != 0`、清理已确认且存在有效 attempt 快照时打印这 19 个字段。
- 将被 deadline 中断的 attempt 表示为一次安全的 `timeout` attempt，当前响应字节数为 `0`。
- 将 worker 终止、descendant 清理、快照验证和日志提交全部包含在一个 60 秒 hard deadline 内。
- 使诊断可用性不再依赖最后的 worker 报告窗口。
- 保持所有失败为 fail-closed，并阻止后续正常 workflow step 继续执行。

## 3. 非目标

- 不更改 `.github/workflows/macos.yml` 的 step 顺序或 artifact 行为。
- 不更改 Windows workflow 或 helper 实现。
- 不增加新的外部可见诊断字段。
- 不在本诊断中记录原始 CLI stdout 或 stderr、UU Remote custom code、账户密码、device ID 或其他远程设备连接信息。
- 不保证在清理未确认、没有 attempt 启动、快照无效或外部 signal 中断操作时提供结构化诊断。
- 不为改善日志而让操作超过 60 秒。

## 4. Architecture

### 4.1 Absolute-deadline supervisor

Supervisor 是以下资源的唯一 owner：

- absolute deadline；
- worker process tree 和 process group；
- 私有诊断状态目录；
- 清理确认；
- 最终成功或诊断日志输出。

Supervisor 在启动 worker 之前创建私有状态目录，只向 worker 传递状态文件路径和 worker cutoff，并且绝不读取原始 CLI 响应文件。

### 4.2 Attempt worker

Worker 负责 bounded CLI 执行、严格响应分类和累计计算，不输出最终失败摘要。它在每次 attempt 开始前以及分类完成后原子提交诊断状态。

Worker 继续将原始 CLI 输出保存在自己的 mode-`0600` 临时文件中。分类后立即清空这些文件，并在清理成功时于返回前删除其私有临时树。

### 4.3 原子诊断状态

状态文件是严格的 ASCII tab 分隔 record：

```text
v1<TAB>generation<TAB>state<TAB>19 diagnostic values
```

每个已启动 attempt 的 `generation` 都是正十进制整数。`state` 只能为 `open` 或 `committed`。

19 个诊断值按顺序对应现有外部字段：

1. attempts
2. timeout count
3. CLI-nonzero count
4. empty count
5. invalid-UTF-8 count
6. invalid-JSON count
7. not-object count
8. success-missing count
9. success-wrong-type count
10. success-false count
11. enabled-missing count
12. enabled-wrong-type count
13. enabled-false count
14. enabled-true count
15. response-bytes minimum
16. response-bytes maximum
17. response-bytes final
18. final category
19. final CLI exit

`open` record 包含当前 attempt 之前最后一次 committed aggregate。第一次 attempt 可以包含内部 zero-attempt baseline，其 final category 和 exit 为 `unavailable`；该 baseline 永远不能对外打印。`committed` record 包含当前 attempt，并且必须满足所有外部 19 字段 invariant。

Worker 先将完整 record 写入同一目录下的 mode-`0600` 临时文件，验证后再在同一 filesystem 上原子替换状态文件。不接受任何不完整 record。

## 5. 状态转换

1. Supervisor 创建 mode-`0700` 状态目录，此时不存在可打印快照。
2. 第 N 次 attempt 调用 CLI 前，worker 以 generation N 和 `open` 状态原子写入上一次 committed aggregate。
3. Worker 运行 bounded CLI、读取安全 status、严格分类响应并清空原始响应。
4. Worker 计算新的 aggregate，并以 generation N 和 `committed` 状态原子替换 record。
5. 下一次 attempt 使用 generation N+1 重复该转换。
6. Worker 返回成功前，必须先提交已接受的 `enabled-true` 结果。

Generation 必须严格加一。重复、跳过、减小、非十进制或不匹配的 generation 都会使状态无效，并强制 generic-only 失败。

## 6. Deadline 与 finalization

Supervisor 在 `T0 + 60s` 建立一个 monotonic deadline。

- 正常 worker 活动可以持续到 `T0 + 58s`。
- `T0 + 58s` 时，supervisor 开始 bounded cleanup。
- TERM 最多获得 500ms。
- KILL 最多获得 500ms。
- 使用诊断状态前，supervisor 必须确认 owned PID 和 process group 均不存在。
- Cleanup 必须在 `T0 + 59s` 前完成。
- 最后一秒只保留给快照验证、状态删除和固定输出；这些操作必须在 `T0 + 60s` 前完成。

Worker 的 attempt timeout 为 `min(3000ms, 距 cleanup 开始的剩余时间)`。不设置 worker-report reserve，也不设置 post-attempt reserve。由于 cleanup 和输出都必须位于 hard deadline 内，supervisor 拥有一个固定的一秒 finalization phase。若 worker 无法完成 attempt，已经提交的 `open` 状态会在清理后提供安全的 timeout projection。

## 7. 最终结果规则

### 7.1 成功

只有以下条件全部满足时，supervisor 才能打印 `ASSIST_STATE=enabled`：

- worker 在 deadline 前成功返回；
- 最终状态是有效的 `committed` record；
- final category 为 `enabled-true`；
- 已确认 owned descendant 不存在；
- 已成功删除 worker 和状态私有文件。

### 7.2 Committed failure

最终状态为有效 `committed`、清理已确认且 `debug_level` 为 `1`、`2` 或 `3` 时，supervisor 从该状态打印不变的 19 个字段，随后由 caller 输出现有 generic failure。

`debug_level=0` 时不打印结构化诊断，只保留 generic failure。

### 7.3 Deadline 时存在 open attempt

清理确认后，supervisor 验证 `open` baseline，并合成一次 timeout attempt：

- attempts 和 timeout count 各增加一；
- response-bytes final 设为 `0`；
- 在 response-bytes minimum 和 maximum 计算中包含 `0`；
- final category 和 final CLI exit 设为 `timeout`；
- 其他 category count 保持不变。

合成后的 record 必须通过同一个 19 字段 validator，才能打印。

### 7.4 Generic-only failure

出现以下任何情况时，supervisor 都不打印结构化诊断：

- 清理或 owned-process absence 未确认；
- 没有 attempt 到达 `open`；
- 状态版本、generation、字段数量、数字、枚举或 aggregate 关系无效；
- 状态文件创建、原子替换、读取、验证或删除失败；
- HUP、INT 或 TERM 赢得现有 atomic interruption decision；
- 60 秒 deadline 没有留下足够时间验证并提交完整结果。

这些失败后，后续正常 workflow step 不继续执行。现有 hosted teardown 和已授权的 `always()` artifact 行为保持不变。

## 8. 安全与隐私

- 状态目录使用 mode `0700`；状态和临时文件使用 mode `0600`。
- 状态 record 只接受固定版本、固定 state enum、十进制整数以及现有安全 category/exit enum。
- Supervisor 绝不读取或复制原始 CLI stdout 或 stderr。
- 只有 worker 已停止且 owned cleanup 已确认后，才验证状态。
- 在向日志提交成功或结构化诊断之前，必须成功删除状态。
- 清理未确认和状态格式错误路径不发布结构化 status。
- 外部日志仍仅存在于当前 workflow step；不增加新的 artifact 字段。

## 9. 测试策略

### 9.1 Portable state-machine tests

测试调用真实 state writer 和 validator，并覆盖：

- 第一次 attempt 停留在 `open`；
- 一次 committed attempt 后跟一次 `open` attempt；
- committed failure；
- committed success；
- 非法版本、generation、state、字段、数值、枚举和 aggregate 关系；
- atomic-write failure；
- `debug_level=0` 抑制；
- hostile raw marker 不出现在 state、stdout 和 stderr 中。

### 9.2 Targeted native macOS gate

一个 native gate 只调用真实 supervisor、worker 和受控 fixture，不执行 host provisioning。它证明：

- CLI 或 classifier hang 在严格 cleanup 后产生合成 timeout 摘要；
- cleanup-unconfirmed mutation 只产生 generic-only failure；
- 正常失败产生精确 19 字段；
- enabled success 保持精确输出；
- 测试返回前，私有临时树为空且 owned PID/process group 不存在。

移除或绕过 `open` commit、atomic replacement、cleanup gate、snapshot validation 或 debug gate 的 causal mutation 必须失败。

### 9.3 Remote validation gate

本地验证和独立 review 通过后，remote action 仍需分别获得用户授权：

1. Push 并 dispatch 一次 targeted native gate。
2. 停止并报告其证据。
3. 再次获得明确授权后，运行一次完整 macOS workflow。

任何失败都会停止该序列。不自动 repair、rerun、push、dispatch 或 merge。

## 10. Migration 与范围

实现会移除未提交的 post-attempt timing-reserve 候选方案，并使用原子状态边界替代它。预期 tracked scope 仅限：

- `.github/workflows/apple.sh`；
- focused macOS assist harness 和 tests；
- governing English 与简体中文 design/plan counterpart。

本设计不授权修改 workflow YAML、Windows 实现、凭据处理、artifact schema 或无关 provisioning 行为。
