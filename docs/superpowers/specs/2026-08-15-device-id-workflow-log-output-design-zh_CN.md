# Device ID Workflow 日志输出设计

[English](2026-08-15-device-id-workflow-log-output-design.md) | [简体中文](2026-08-15-device-id-workflow-log-output-design-zh_CN.md)

## 1. 背景

统一后的 Windows 与 macOS workflows 当前将 UU Remote device ID 视为远程设备连接信息，并使用通用 token `DEVICE_ID_STATE=ready` 代替其真实值。这让 workflows 可以被安全检查，但也导致操作人员无法获得建立真实 UU Remote 连接所需的 device ID。

本设计修改已批准的数据分类。UU Remote device ID 是可以打印到 workflow logs 的 operational identifier。账户密码、UU Remote custom code 和其他连接凭据仍然是 secrets，禁止打印。

## 2. 目标

- 在每次成功的 Windows 和 macOS workflow run 中打印完整 device ID，不受 `debug_level` 影响。
- 两个平台使用相同、可被机器读取的 launch 输出。
- 在 production `Wait connections` 消息中再次包含当前 device ID，方便操作人员在实际使用位置找到它。
- 继续对 custom codes 和账户密码进行 masking，将其限制在 step scope，并确保 logs、screenshots 和 artifacts 中不存在这些值。
- 拒绝不安全的 device-ID 输出，避免控制字符或多行内容改变 workflow log 结构。
- 保留现有 debug gates、wait-result contract、diagnostics 和平台特有实现。

## 3. 非目标

- 不显示 custom code 或账户密码。
- 不打印原始 CLI errors、失败 polling 输出、process arguments、window titles 或其他远程连接数据。
- 不添加加密 artifact、私有通知集成或独立 reporting service。
- 不让 `Wait connections` 在 debug level `1`、`2` 或 `3` 下执行。
- 不修改 `WAIT_RESULT=timeout|shutdown/restart` 或允许的等待范围。
- 不为创建独立 reporting step 而额外调用一次 device-ID CLI。

## 4. 数据分类

共享仓库政策改为：

- 账户密码和 `UUREMOTE_CUSTOM_CODE` 是 secrets。
- UU Remote device ID 是可以记录到日志的 operational identifier。
- 除非后续已批准设计另行明确分类，否则其他远程设备连接信息仍然禁止记录。
- 即使指定的 workflow log 消息可以包含 device ID，diagnostic artifacts 仍不得包含 device ID。

`AGENTS.md`、`CLAUDE.md`、README 和 governing parity documents 的英文与简体中文版本必须一致表达这一区分。

## 5. 公共日志 contract

在无条件执行的 launch/readiness 阶段首次成功观察到非空 device ID 后，两个平台都精确输出：

```text
DEVICE_ID=<完整 device ID>
DEVICE_ID_STATE=ready
```

对于 debug level `0`、`1`、`2` 和 `3`，每次成功 run 都会输出一次这组 launch/readiness 内容。

Production `Wait connections` step 仍然只在 `debug_level=0` 下执行。在调用 shutdown-aware wait 前，它再次获取当前 device ID，并输出：

```text
WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>
```

现有最终结果继续使用独立的精确行：

```text
WAIT_RESULT=timeout
```

或者：

```text
WAIT_RESULT=shutdown/restart
```

因此，成功的 debug-level `0` run 会打印两次 device ID：launch/readiness 时一次，在实际等待连接的位置再打印一次。成功的 debug level `1`、`2` 和 `3` runs 只在 launch/readiness 时打印一次。

## 6. Device-ID validation

只有 CLI 成功返回且通过验证的非空 device ID 才允许记录。平台收到的内容可以是 legacy 单行可打印 device ID，也可以是平台内部 JSON envelope。Envelope 必须是严格 UTF-8 JSON，其 root 必须为 object，`success` 必须等于 JSON boolean `true`，`data` member 必须为 object，且 `data.deviceId` 必须为 string；存在重复 object keys 时无效。Envelope 本身绝不允许记录。

完成平台特定的提取后，两条路径都应用同一个 device-ID validator。去除允许的首尾空格后，提取出的值必须是单个可打印行。包含 CR、LF、NUL、其他 C0 控制字符、DEL 或 Unicode control/non-printing/separator 字符的值均为无效。

固定 prefixes `DEVICE_ID=` 和 `WAIT_CONNECTIONS DEVICE_ID=` 可以防止该值出现在 GitHub workflow-command 行首。Validation failure 必须 fail-closed，并且只输出通用 readiness 或 device-ID validation error。失败尝试和原始 CLI stderr 绝不回显。

Workflows 不会对 device IDs 使用 `::add-mask::`，因为 masking 会把操作人员需要使用的值替换为 `***`。

## 7. 平台集成

### 7.1 Windows

`Get-UURemoteDeviceId` 继续作为唯一有边界的 CLI boundary。一个小型输出 helper 负责验证返回值，并输出两种已批准消息之一。

`Start-UURemoteAndWaitDevice` 在首次观察到合法 device ID 后立即输出 launch/readiness 两行。真实 `wait-connections` route 获取并验证当前 device ID、输出 wait 消息，然后调用现有 shutdown-aware watcher。注入式 watcher self-test 继续与已安装 CLI 隔离，并且不打印 device ID。

### 7.2 macOS

macOS `assist id` command 可能返回 pretty-printed JSON envelope，而不是只返回 ID。Helper 在内部解析该 envelope，要求已批准的 success/data/deviceId 结构，拒绝 malformed 或 duplicate-key JSON，并且只验证提取出的 `deviceId`。Legacy 非 JSON 单行 response 继续通过同一个最终 device-ID validator 接受。未通过 envelope validation 的 JSON-looking output 绝不回退到 legacy path。

`apple.sh launch-and-wait-device` route 负责 macOS 启动与 readiness：它仅在 GameViewer 未运行时启动它，验证首次成功提取的 `assist id` 值，输出 launch/readiness 两行，并在 readiness 后保持应用继续运行。Helper 使用 60 秒整体 deadline 和 500 毫秒轮询间隔。

真实 `wait_connections` route 获取并验证当前 `assist id` 值、输出 wait 消息，然后调用现有 Swift watcher。Watcher self-test 继续独立于已安装 CLI。

两个平台可以使用不同 validation 实现，但它们接受的输出与失败行为必须等价。

## 8. Secret handling 与 cleanup

`UUREMOTE_CUSTOM_CODE` 和账户密码的现有处理保持不变：

- 只通过 step-scoped environment variables 传递 secrets；
- 在任何可能记录命令的操作前 mask secrets；
- 不得把 secrets 写入 command output、screenshots、artifacts、source、tests 或 defaults；
- 在实际可行的最早时机从 environment 中移除 secrets。

即使 device ID 不再被分类为 secret，使用后仍要清除 device-ID variables，以保持 data flow 狭窄并防止意外复用。

## 9. 测试

实现遵循 test-driven development。

Behavior tests 必须证明：

- Windows 和 macOS 在首次成功 readiness observation 后输出 `DEVICE_ID=<fixture>`，紧接着输出 `DEVICE_ID_STATE=ready`。
- Launch/readiness 输出与 debug level 无关，并且每次成功 run 精确出现一次。
- Production wait route 在不变的 wait result 前输出 `WAIT_CONNECTIONS DEVICE_ID=<fixture>`。
- Debug level `0` 包含两条已批准的 device-ID 消息，而 debug level `1`、`2` 和 `3` 只包含 launch/readiness 消息。
- 空值、多行值和包含控制字符的值必须 fail-closed，且不得输出不安全值。
- 失败 retry 输出和原始 CLI stderr 继续保持不可见。
- Custom-code 与 password fixtures 继续不出现在 stdout、stderr、screenshots 和 artifacts 中。
- Diagnostic artifacts 不会因本次日志修改而获得 device-ID 内容。
- Shutdown-wait self-tests 必须独立观察 cleanup：macOS 不得遗留临时 build directory 或 watcher process，Windows 必须回到同一 process 内的 watcher resource baseline。

Contract tests 必须确认 Windows 与 macOS 的 prefixes、ordering、debug gates 和 documentation policies 等价。最终验证包括完整 repository test suite、双语 Markdown counterpart/navigation checks、JSON validation、sensitive-value scans 和 `git diff --check`。

## 10. Live acceptance

Live validation 覆盖 Windows 和 macOS 的 debug level `0` 与 `1`，以及现有 Windows diagnostic matrix：

- 每次成功 run 都包含 launch/readiness device-ID 两行；
- debug-level `0` 包含带当前 device ID 的 wait 消息；
- mobile client 可以使用打印出的 device ID 和单独配置的 custom code 建立连接；
- logs 与 artifacts 不包含 custom code 或账户密码；
- artifacts 保持现有名称和文件内容；
- timeout 与 shutdown/restart runs 保持其精确 `WAIT_RESULT` 值。

Executable injected shutdown-wait self-test 为精确 `WAIT_RESULT=shutdown/restart` 结果与 cleanup contract 提供确定性 evidence。它必须在 live acceptance 前通过。

Live acceptance 与此分开：它要求 mobile-client 连接成功，并观察到所请求的真实 shutdown/offline effect。由用户发起 remote shutdown/restart action；agent 禁止执行 operating-system shutdown command。

Shutdown/restart 后的 GitHub log、result 与 cleanup reporting 仅作 best-effort，且不阻塞验收。Shutdown/restart 开始后缺少回传不属于 watcher failure；当确定性 self-test 已通过，且已观察到 live connection 与 shutdown/offline effect 时，该回传缺失不阻塞验收。
