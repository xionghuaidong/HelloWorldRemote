# macOS 无人值守权限诊断设计

[English](2026-08-16-macos-unattended-permission-diagnostics-design.md) | [简体中文](2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md)

## 1. 背景

macOS feature workflow 现在可以通过原生 device-ID 测试和 GameViewer 启动就绪步骤。随后连续两次 feature run 都在未修改的 `Configure UU Remote permissions` 步骤失败。两次运行中，`uuyc-cli status` 都到达 `CLI_STATUS_STATE=ready`，但 `uuyc-cli assist allow on` 未能在 60 秒内产生可接受的 `enabled=true` 结果。

当前失败路径只暴露通用错误，无法区分 child 卡死、CLI 非零退出、输出格式错误、JSON schema 变化、`success=false` 或 `enabled=false`。禁止在没有新证据的情况下继续重跑。下一次 live run 必须先定位失败边界，同时不能暴露 vendor payload，也不能削弱无人值守访问 gate。

## 2. 目标

- 为 macOS 无人值守权限边界永久增加安全、仅 debug 启用的诊断。
- 使用 monotonic deadline 约束每个 `assist allow on` child process 和完整轮询操作。
- 将每次 attempt 分类为且仅分类为一个预定义安全状态，并汇总完整的 60 秒窗口。
- 保持成功输出不变：`ASSIST_STATE=enabled`。
- 保持失败为 fail-closed，并保留现有通用错误。
- 在实施 root-cause-specific 修复之前，先用一次诊断性 live run 识别根因。
- 参考 Windows helper 的 owned bounded process boundary、严格解析、固定成功输出和通用失败模式，但不强制两个平台使用相同内部实现。

## 3. 非目标

- 不打印或持久化原始 CLI stdout 或 stderr。
- 不在本诊断中打印 UU Remote custom code、账户密码、device ID 或其他远程设备连接信息。
- 不把新的诊断字段写入 `uuremote-diagnostics` 或任何其他 artifact。
- 不削弱 macOS 必须证明 `success=true` 且 `enabled=true` 的要求。
- macOS 命令失败时不降级为较弱的 Windows readiness 证据。
- 不猜测替代 vendor command，不直接修改 TCC，不削弱 macOS 安全控制，也不增加未经证实的恢复操作。
- 不修改 Windows runtime implementation。

## 4. 两阶段交付

### 4.1 永久诊断阶段

第一阶段实现下文定义的 bounded execution、严格 classifier、聚合、清理和仅 debug 启用的 reporter。请求 live run 前必须通过本地测试和 review。

该 commit 后的第一次原生 macOS run 是诊断 gate。workflow 可以仍为 RED，但权限步骤必须输出完整的安全汇总，用于识别真实失败类别。诊断性 RED run 是证据收集，不是已完成的修复。

### 4.2 根因修复阶段

在诊断 gate 识别出失败类别前，不实施行为修复。

- 如果证据表明 parser 拒绝了一种合法 vendor response shape，则先用该精确形态添加 failing fixture，再做最小的严格 parser 修改。
- 如果证据表明持续 `enabled=false`、CLI failure、timeout 或其他 vendor/environment condition，则保持 workflow fail-closed。先调查该条件；在增加恢复操作或改变权限 contract 前修订本设计。
- 不得把诊断改善视为无人值守访问已经启用的证据。

修复 gate 要求 feature workflow 通过权限步骤和其后所有未修改步骤。

## 5. 组件与数据流

### 5.1 Bounded GUI CLI boundary

`run_bounded_gui_cli_to_file` 在图形 console user 的 launchd session 中执行已安装 CLI。它拥有 child process 和 process group，将 stdout 重定向到 caller 提供的 mode-`0600` 文件，丢弃 stderr，并接受由剩余总 deadline 推导的 timeout。

这是有界 fail-closed 清理策略（Option 2）。helper 执行 `TERM`→`KILL`→回收/PGID 探测。已记录的 cleanup grace 最多为 `TERM` 后 500 milliseconds，随后最多为 `KILL`、回收和 PGID 探测的 500 milliseconds。清理最多只能在一次 CLI attempt 之外增加已记录的固定清理宽限；绝不无限等待。

确认清理后才发布现有安全 status。未确认清理或异常不发布最终 status，并以 `125` 退出；controller 只输出现有通用失败，后续 normal 或 provisioning operation 不继续。只有现有 `always()` finalization/artifact-upload step 和 hosted-runner teardown 可以执行。原始 assist payload、secrets、device connection data 和新的 `ASSIST_DIAGNOSTIC_*` fields 绝不进入 artifact；这些 fields 只保留在当前 step 日志。现有 sanitized CLI diagnostics 可以由 `always()` artifact step 上传。OS-level 残留可能仍无法确认；不得声称绝对清理。

### 5.2 严格 response classifier

`classify_assist_allow_response` 只接收 response-file path 和安全的 execution status。它执行严格 UTF-8 解码，并用 duplicate-key rejection 及拒绝 `NaN`、`Infinity` 等非标准常量的方式解析严格 JSON。

每次 attempt 必须产生且只产生一个类别：

- `timeout`
- `cli-nonzero`
- `empty`
- `invalid-utf8`
- `invalid-json`
- `not-object`
- `success-missing`
- `success-wrong-type`
- `success-false`
- `enabled-missing`
- `enabled-wrong-type`
- `enabled-false`
- `enabled-true`

只有 JSON object 的 `success` 值为 Boolean `true`，且 `enabled` 值为 Boolean `true` 时才成功。

classifier 只向 caller 输出预定义类别和数字 metadata。它绝不输出 parsed object、字符串值、response fragment 或 stderr。

### 5.3 Attempt accumulator

`ensure_assist_allowed` 拥有总 deadline 和 accumulator。它跟踪：

- 总 attempts；
- 每个预定义类别对应的一个 counter；
- response byte count 的 minimum、maximum 和 final 值；
- final category；
- final safe CLI exit value。

每次 attempt 完成分类后，立即清空原始 response file。成功的 `enabled-true` 结果只打印 `ASSIST_STATE=enabled` 并返回成功。否则继续轮询，直到 deadline。

### 5.4 安全 reporter

deadline 到期且 `UUREMOTE_DEBUG` 为 `1`、`2` 或 `3` 时，reporter 将固定行写入当前 workflow step 日志。它打印每个类别的 counter（包括值为零的 counter）、数字聚合字段和 final enum。

final CLI exit 字段只能是 `0` 到 `255` 的整数、`timeout` 或 `unavailable`。reporter 在写入任何内容前验证每个整数和 enum。内部状态无效时不输出详细诊断，并 fail-closed。

debug 为 `0` 时不运行 reporter，新的诊断数据也不会写入 artifact。

## 6. 时间和错误处理

- 第一次 attempt 前立即建立一个 60 秒 monotonic deadline。
- 每次 CLI call 最多运行 3,000 milliseconds 与剩余总时间中的较小值。
- attempt 失败后，最多等待 500 milliseconds 与剩余总时间中的较小值。
- child 完成后、解析后以及接受 `enabled-true` 前立即重新检查 deadline。
- 拒绝只在 deadline 后才可用的结果。
- launch failure、temp-file failure、parser failure、cleanup failure、signal interruption 或 accumulator invariant 无效均按 fail-closed 处理。
- 每个适用路径执行有界清理策略，并在可确认时删除私有临时文件。清理确认失败时，不得声称所有 operating-system 残留均已消失。

仅 debug 启用的汇总之后，现有 caller 仍打印：

```text
Could not enable unattended control within 60 seconds
```

并以 status `1` 退出。debug 为 `0` 时只打印通用错误。

## 7. 安全与日志 contract

原始 response data 只存在于当前 attempt 拥有的私有临时文件中。directory 和 file 使用限制性权限。立即清空私有临时文件或尝试将其删除。确认的路径会在返回前删除私有临时文件。清理失败时不得声称不存在残留。hosted-runner teardown 属于外部遏制；self-hosted runner 必须被隔离，直至 operator 确认无残留。

诊断日志只包含预定义字段名、已验证整数和预定义 enum。包含 custom code、device ID、换行、控制字符、Unicode separator 或伪造 workflow token 的 fixture 值不得出现在 stdout、stderr、临时残留或 artifact 中。

custom-code secret 仍保持 step-scoped，仅在之前的 custom-code step 中使用，权限诊断不读取它。本设计不改变账户、TCC、firewall、login 或 operating-system security policy。

## 8. 测试

实现必须增加以下 executable tests：

- 所有 response category，包括 duplicate keys 和非标准 JSON constants；
- exactly-one-category accounting 和 `sum(category counts) == attempts`；
- transient failure 后成功，且只输出 `ASSIST_STATE=enabled`；
- debug `0` 只产生通用失败；
- debug `1`、`2`、`3` 产生完整固定汇总；
- 真实受控 hanging child、单次 timeout、总 deadline、有界 `TERM`→`KILL`→回收/PGID 探测以及已确认清理；
- 针对 timeout、leader 已完成但 descendant 仍存活及已处理 signal 的 cleanup 为 false 或 raises 的 native-macOS matrix case；每个 case 必须产生 exit `125`、无最终 status 和仅 outer generic failure；后续 normal 或 provisioning operation 不得继续，只有现有 `always()` finalization/artifact-upload step 和 hosted-runner teardown 可以执行；
- late-success rejection；
- response file 和 temporary directory cleanup；
- hostile fixture marker 和 log-injection attempt 不产生泄漏；
- workflow structure 证明权限 step 可以获得 `UUREMOTE_DEBUG`，且新字段不会写入 artifact。

分类和聚合决策必须由 production helper 拥有，不能在 test 中复制该逻辑。

## 9. Live validation 与完成条件

本地验证和独立 review 完成后，在 push 或 dispatch 诊断性 live run 前请求明确授权。该 run 使用 `debug_level=1`，只记录安全的 workflow-log 字段。

诊断 run 用于建立 root-cause category。然后必须先增加 root-cause-specific failing test，再实施最小行为修复。只有后续 feature run 通过权限步骤和其后所有 workflow steps，才能完成本任务。

branch 完成前，运行相关 macOS 与 Windows contract suites、双语文档验证、JSON validation、secret 与 forbidden-output scans、`git diff --check e30a65b..HEAD` 以及独立 code review。集成到 `main` 仍是单独的 finishing decision。

当前 GitHub-hosted macOS runner 在 job 失败后的 teardown 属于外部遏制。如果将来采用 reused/self-hosted 执行，该 runner 必须被隔离，且在 operator 确认无残留前不得复用。

## 10. 范围

预期 implementation files 为：

- `.github/workflows/apple.sh`
- `tests/` 下的 focused files
- 本 English design 及其 meaning-equivalent 简体中文 counterpart
- 后续 English implementation plan 及其简体中文 counterpart

`.github/workflows/macos.yml` 应保持不变，因为 `UUREMOTE_DEBUG` 已在 job scope 到达权限 step。只有 executable contract 证明现有结构无法执行本设计时，才允许做最小 workflow change。
