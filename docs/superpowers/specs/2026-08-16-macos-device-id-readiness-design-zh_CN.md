# macOS 设备 ID Readiness 对齐设计

[English](2026-08-16-macos-device-id-readiness-design.md) | [简体中文](2026-08-16-macos-device-id-readiness-design-zh_CN.md)

## 1. 背景

Windows workflow 将 UU Remote 启动与设备 ID readiness 委托给单一 helper route：`launch-and-wait-device`。该 helper 仅在 GameViewer 未运行时启动它，负责一个 60 秒 deadline，将每次 CLI 尝试限制在剩余 deadline 内，以 500 毫秒间隔轮询，并在无法取得通过验证的设备 ID 时 fail closed。

macOS workflow 目前在 YAML 中维护独立的 120 次轮询，并通过 `gtimeout 60s` 启动长期运行的 UU Remote 应用。因此，即使后续 workflow 阶段仍需要该应用，它也可能在 timeout 到期时被终止。YAML loop 还将 deadline、进程、diagnostics 和输出职责拆分在 workflow 与 `apple.sh` 之间。

真实 macOS 运行已证明设备 ID parser 和 diagnostic 测试通过，但 production launch 阶段仍可能耗尽全部 readiness 尝试而无法取得 ID。本设计让 macOS 对齐既有 Windows 的职责归属与生命周期模型，不推测性增加 restart 行为，也不改变公开设备 ID 日志契约。

## 2. 目标

- 让 `apple.sh` 成为 macOS UU Remote 启动与设备 ID readiness 的唯一 owner。
- 使用单一 60 秒整体 readiness deadline 和 500 毫秒轮询间隔，与 Windows 保持一致。
- 让每个 `assist id` subprocess 均受剩余整体预算约束，并确定性终止和回收 hung child。
- 仅在 UU Remote 未运行时启动它，不自动 restart 既有进程。
- 让长期运行的 UU Remote 应用在 readiness deadline 之后继续存活。
- 保持已批准的设备 ID、wait result、secret handling 与 diagnostic 日志契约。
- 为进程生命周期、deadline 行为、输出验证、cleanup 和 non-leakage 增加 executable regression。
- 先在 feature branch 上通过真实 macOS workflow 验证，再在 `main` 上验证。

## 3. 非目标

- 不修改稳定的 Windows 实现。
- 不引入自动 restart、relaunch 或 recovery loop。
- 不改变已接受的设备 ID 格式或既有 strict JSON 与 legacy single-line parser。
- 不改变 `WAIT_CONNECTIONS DEVICE_ID=...` 或 `WAIT_RESULT=...` 契约。
- 不暴露 UU Remote custom code、账户密码、原始 CLI stdout 或原始 CLI stderr。
- 不新增跨平台 supervisor，也不替换平台原生 PowerShell 与 Bash 实现。
- 除非对比证据和 failing regression 证明有必要，否则不改变 macOS execution user 或 GUI session context。

## 4. 已考虑的方案

### 4.1 Workflow 负责轮询

可以将 YAML loop 从固定尝试次数改为 60 秒 deadline，同时保留独立的启动、轮询和 diagnostic 命令。这个文本改动较小，但会继续把职责拆分在 YAML 与 Bash 之间，并使 Windows/macOS 日后更容易再次偏离。

### 4.2 Helper 负责启动与 readiness

`macos.yml` 只委托一次 `apple.sh launch-and-wait-device`。helper 负责进程检测、启动、deadline 计算、bounded CLI 调用、验证、成功输出和失败状态。这样既能对齐 Windows 的职责边界，又能保留平台特有的内部实现。

这是已批准方案。

### 4.3 共享跨平台 supervisor

可以新增由 Windows 与 macOS 共享的 Python controller。尽管这会最大程度统一内部实现，但会重写已验证的 Windows 路径、扩大风险面，而且不会提供必要的新用户可见能力。

## 5. 架构与控制流

macOS workflow 的 launch step 变为薄委托层：

```text
macos.yml
  -> apple.sh launch-and-wait-device
       -> 验证应用与 CLI 路径
       -> 检测 UU Remote 是否已经运行
       -> 若未运行则启动一次
       -> 建立单一 monotonic 60 秒 deadline
       -> 在剩余预算内调用 bounded assist-id attempts
       -> 解析并验证第一个成功的设备 ID
       -> 精确输出一次 readiness pair
       -> 否则在 deadline 到期时 fail closed
```

workflow 不得包含自己的 retry loop 或 readiness state variable。`report-device-id readiness` 可以作为兼容的内部 route 保留，但 production launch step 不再通过重复调用该 route 来组合 readiness。

进程检测必须识别目标 UU Remote 应用，不能将无关进程视为 ready。若不存在匹配进程，helper 启动该应用一次；若已经存在，则复用该进程。readiness loop 不会 restart 或替换应用。

应用启动不再由 `gtimeout` 包裹。60 秒 deadline 属于 readiness controller，不属于长期运行的 GUI 应用。readiness 失败时，不终止在 helper 调用前就已存在的进程；本设计也不要求终止本次调用启动的进程。保留失败现场有助于安全 diagnostics，并与 Windows 不做 recovery 的行为一致。

## 6. Deadline 与 subprocess 语义

controller 使用 monotonic clock，在 readiness 开始时计算唯一 deadline，并在每次 attempt 和 sleep 前重新计算剩余时长。

每次 `assist id` 尝试收到的 timeout 不得大于剩余整体时长。CLI process timeout 后先接收 TERM，必要时再接收 KILL，并且始终被 wait 和 reap。其 stdout 仅写入由当前调用拥有且 mode 为 `0600` 的临时文件；stderr 不回显。所有返回路径都删除临时文件。

一次尝试失败后，controller sleep 500 毫秒与剩余时长中的较小值。deadline 之后不启动新 attempt，也不进行 sleep。非法 timing value 以及缺失应用或 CLI 路径属于 configuration error，立即失败。

controller 总时长受 60 秒 deadline 约束，只允许额外增加终止和回收 owned child 所需的小幅确定性 cleanup allowance。

## 7. 设备 ID 与日志契约

既有 macOS parser 继续作为唯一 extraction 与 validation boundary。成功值必须是已批准的 strict JSON envelope 或 legacy single printable line，之后再应用共享的设备 ID 验证规则。空输出、非零 CLI exit、非法 UTF-8、malformed JSON、`success:false`、duplicate key、multiline value、C0 或 DEL control，以及 Unicode control 或 separator character 均属于失败尝试。

第一次取得通过验证的值时，stdout 仅精确包含以下 readiness lines 一次：

```text
DEVICE_ID=<validated device ID>
DEVICE_ID_STATE=ready
```

production wait route 保持：

```text
WAIT_CONNECTIONS DEVICE_ID=<validated device ID>
```

其他消息均不得新增设备 ID。尤其是 retry、timeout、diagnostic 和 error 消息不得包含原始或未验证的 CLI 输出。

UU Remote custom code 与账户密码继续视为 secret。它们不得出现在 stdout、stderr、截图、artifact、diagnostics 捕获的 process argument，或表示真实凭据的测试 fixture 中。

## 8. 错误与 diagnostics

暂时性 CLI failure 在 raw-data boundary 保持静默，只要仍有剩余时间就可以进行下一次尝试。最终 timeout 返回非零状态，并输出通用错误；该错误可以包含安全的 elapsed-time 和 attempt-count metadata，但不得包含 CLI payload。

当 `UUREMOTE_DEBUG` 非零时，workflow 在最终 readiness failure 后调用一次既有安全设备 ID diagnostic route。diagnostic 保持固定的 metadata-only 契约，且不得打印设备 ID、custom code、密码、原始 stdout 或原始 stderr。debug level 不改变 readiness timing、validation 或成功输出。

应用或 CLI path error 立即失败。意外的 controller 或 cleanup error 同样以通用消息 fail closed。

## 9. 测试策略

实现遵循 test-driven development。测试通过受控的 process、clock、sleep、launch 和 CLI boundary 执行真实 production helper，而不是复制其决策逻辑。

Workflow contract tests 证明：

- Launch GameViewer step 精确委托一次 `apple.sh launch-and-wait-device`；
- YAML-owned 120-attempt loop 与 readiness state variable 不再存在；
- 长期运行的应用不由 `gtimeout` 包裹；
- safe diagnostics 最多执行一次，且仅在最终失败和 debug 非零时执行。

Executable helper tests 证明：

- 应用不存在时只启动一次，允许若干暂时性失败后成功，并且 readiness pair 精确且唯一；
- 应用已经存在时复用它，不重复启动；
- hanging CLI 受剩余 deadline 约束，被终止并回收；
- deadline 之后不启动 attempt 或 sleep；
- 最终失败返回非零且仅输出通用内容；
- 非法 JSON、非法 UTF-8、multiline 和 control-character value 不会泄露；
- 临时输出 mode 为 `0600`，返回后不残留文件或 child process；
- debug diagnostics 执行一次并保持既有 fixed safe-field contract。

Regression verification 包括 macOS 设备 ID、diagnostics、wait 与 workflow-contract tests；完整 Windows parity suite；全仓库 test discovery；Bash syntax；PowerShell parsing；JSON validation；双语 Markdown counterpart 与 navigation 检查；sensitive-value scan；以及 `git diff --check`。

## 10. 实现与 review workflow

本设计批准并提交后，在新 feature branch 的隔离 worktree 中实现。书面 implementation plan 会列出精确文件、测试、RED 与 GREEN 命令、review checkpoint 和 live validation step。

除非证据确定必须涉及额外文件，否则变更预计仅涉及双语 design 与 plan 文档、`macos.yml`、`apple.sh` 和 focused tests。每项 behavior change 都先由 failing test 引入。合入前由 independent review 解决全部 Critical 与 Important finding。

## 11. Live 验收

feature branch 仅在本地验证和 review 完成后推送。使用 `debug=1` 与 `wait=0` dispatch 真实 macOS workflow。验收要求：

- device-ID test module 通过；
- Launch GameViewer 在 60 秒 readiness 契约内完成；
- readiness pair 精确出现一次且包含通过验证的设备 ID；
- 日志或 artifact 中不出现 custom code、密码或原始 CLI payload；
- workflow 继续通过 Launch GameViewer 阶段。

如果该运行失败，保留 feature branch 与安全 diagnostic 证据，以便 systematic debugging；在没有新 hypothesis 时不反复重试 workflow。

本地验证、independent review 和 feature-branch live acceptance 均通过后，将分支合入 `main`。随后在 `main` 上以相同的 `debug=1`、`wait=0` 再次 dispatch workflow，并且必须复现结果。只有该 main run 为 green 后，才可以删除此前保留的 remote backup branch。
