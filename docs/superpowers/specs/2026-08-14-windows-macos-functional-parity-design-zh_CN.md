# Windows 与 macOS 功能对齐设计

[English](2026-08-14-windows-macos-functional-parity-design.md) | [简体中文](2026-08-14-windows-macos-functional-parity-design-zh_CN.md)

## 1. 背景

当前 macOS workflow 已具备成熟的 UU Remote 生命周期：经过验证的 dispatch inputs、step-scoped secrets、host 准备、应用就绪、自定义码配置、隐私权限自动化、幂等性诊断、桌面收尾、截图 artifacts、live sampling，以及 shutdown-aware 连接等待。

当前 Windows workflow 只会安装并启动 UU Remote、轮询 device ID、设置硬编码自定义码，并等待固定时长。它尚未提供相同的 dispatch contract、诊断级别、secret 处理、幂等性检查、桌面收尾或 shutdown-aware wait。

本设计实施已批准的功能对齐方案：对齐对外可见的 workflow contract 和用户体验，同时保留平台特有的内部实现。

## 2. 目标

- 让两份 workflow 使用相同的 `debug_level` 和 `wait_connections_seconds` inputs。
- 让 debug level `0` 到 `3` 在两个平台具有相同含义。
- 两个平台都从 step-scoped repository secret `UUREMOTE_CUSTOM_CODE` 配置 UU Remote 自定义码。
- 对齐安装、启动就绪、device ID 发现、无人值守就绪验证、诊断、幂等性、桌面收尾和等待结果。
- 使用独立 PowerShell helper 提供可测试的 Windows 实现。
- 使用原生 Windows shutdown watcher，并让它的公共结果 contract 与 macOS watcher 一致。
- 将平台特有机制隔离在等价 workflow steps 后面。
- 当某项能力无法在不依赖未公开命令或不削弱操作系统保护的前提下得到验证时，采用 fail-closed。

## 3. 非目标

- 不修改 Windows 用户或 Administrator 密码。
- 不启用 Windows 自动登录。
- 不让 Windows 消费 `UUREMOTE_ACCOUNT_PASSWORD`。
- 不在 Windows 上复制 macOS root、login keychain 或 `/etc/kcpassword` 行为。
- 不削弱 UAC、Windows Firewall、SSH、macOS 隐私控制或任何其他操作系统权限边界。
- 不强制安装包版本、安装路径、CLI 语法或内部实现语言完全相同。
- 不把成熟的 macOS helper 重写为跨平台 orchestrator。
- 不虚构未公开的 Windows UU Remote CLI options。

## 4. 共享 workflow contract

`macos.yml` 和 `windows.yml` 都公开以下必需的 `workflow_dispatch` inputs：

| Input | 类型 | 默认值 | 有效值 |
| --- | --- | --- | --- |
| `debug_level` | choice | `0` | `0`、`1`、`2`、`3` |
| `wait_connections_seconds` | number | `300` | `0` 到 `21000` 之间的整数，包含端点 |

两份 workflow 只在 job scope 保存以下非敏感值：

- `UUREMOTE_DEBUG`
- `UUREMOTE_WAIT_CONNECTIONS_SECONDS`

`UUREMOTE_CUSTOM_CODE` 保持 step-scoped。`UUREMOTE_ACCOUNT_PASSWORD` 保持 step-scoped 且仅用于 macOS。

共享的语义步骤顺序是：

1. Checkout。
2. 在启用诊断时测试 shutdown-aware wait。
3. 执行平台特有的 host 准备。
4. 安装 UU Remote。
5. 启动 UU Remote 并等待非空 device ID。
6. 配置自定义码。
7. 配置或验证平台特有的无人值守访问前置条件。
8. 在 debug level `2` 和 `3` 下重复配置检查以验证幂等性。
9. 收尾桌面，并在启用时捕获最终诊断状态。
10. 在 debug level `3` 下捕获 live samples。
11. 在 debug level `0` 下等待连接。
12. 只要 debug 非零就上传诊断；即使发生失败，只要文件存在也应上传。

平台特有 step names 可以表明具体 host 操作，但其顺序和对外可见结果必须等价。

## 5. Debug level 语义

Debug levels 采用累积语义：

| Level | 行为 |
| --- | --- |
| `0` | 快速生产路径，不生成截图或诊断 artifact，执行连接等待。 |
| `1` | 运行诊断 self-tests，并捕获完成收尾的桌面。 |
| `2` | Level 1 加上重复配置并验证幂等性。 |
| `3` | Level 2 加上每 15 秒一次、共 20 次的状态保持型 live samples。 |

两个平台的 artifact 名称统一为 `uuremote-diagnostics`。每个平台只写入各自的 runner 临时目录。诊断捕获不得暴露 secrets 或远程设备连接信息。

## 6. 架构

macOS 实现保留在：

- `.github/workflows/macos.yml`
- `.github/workflows/apple.sh`
- `.github/workflows/uuremote-shutdown-wait.swift`

Windows 实现拆分为：

- `.github/workflows/windows.yml`：负责编排和注入 step-scoped secret。
- `.github/workflows/windows.ps1`：负责验证、启动就绪、自定义码配置、无人值守就绪检查、桌面收尾、截图、幂等性和等待编排。
- `.github/workflows/uuremote-shutdown-wait.cs`：负责原生 Windows message loop 和 shutdown signal。

这种方式在不强制共享实现语言的情况下复用 macOS 的职责分离思路。

## 7. Windows helper 接口

`windows.ps1` 公开适合直接 contract tests 的显式 modes：

- `validate-custom-code`
- `validate-wait-seconds`
- `launch-and-wait-device`
- `set-custom-code`
- `verify-unattended-readiness`
- `verify-idempotency`
- `finalize-desktop`
- `snapshot`
- `self-test-wait-connections`
- `wait-connections`

未知 mode 和错误参数数量返回 exit code `2`。Validation modes 不要求已经安装 UU Remote。Runtime modes 在调用 binaries 之前解析并验证预期安装路径。

## 8. 安装和启动就绪

Windows workflow 保留平台特有的 installer 和静默安装机制。继续执行前，它会验证 installer exit code 和必需的已安装文件。

启动就绪必须具备幂等性：

- 已经运行 UU Remote 时复用现有 process，不启动重复实例。
- 否则使用经过验证的 executable，并以其安装目录作为 working directory 启动。
- 最多轮询 CLI 60 秒，等待非空 device ID。
- 在 deadline 之前，只把非零 CLI 结果视为暂时失败。
- 绝不输出自定义码或远程设备连接信息。
- 到达 deadline 后，以通用的就绪错误和尝试次数失败。

## 9. 自定义码安全与配置

两个平台都要求 `UUREMOTE_CUSTOM_CODE`，并且只接受匹配 `^[A-Za-z0-9]{8,16}$` 的值。

Windows workflow：

1. 只在自定义码步骤中注入 secret。
2. 缺少 secret 时以 exit code `2` 拒绝继续。
3. 调用 helper logic 前先 mask 该值。
4. 通过环境将值传给 `windows.ps1`。
5. 使用 variable reference 调用已安装 CLI，不把值插入 workflow source 或日志。
6. 只报告通用成功消息。
7. 在可行时尽快从该步骤环境移除该值。

任何 source、test、default、log、screenshot 或 artifact 都不得包含真实值。

## 10. Fail-closed 无人值守就绪验证

没有找到用于显式 `assist allow on` 等价操作的权威公开 Windows CLI 文档。因此实现不得猜测命令。

Windows 自动化就绪 gate 验证已安装产品能够提供的证据：

- 必需 executables 存在。
- 当已安装产品公开相应组件时，UU Remote process 以及预期 supporting service 或 process 状态正常。
- CLI 返回非空 device ID。
- 当前仓库已使用的自定义码命令成功完成。
- 只有当已安装 CLI 本身证明支持时，才允许使用额外的无人值守访问命令，并且 implementation 或 live validation 必须捕获经过脱敏的支持证据。

无法建立这些证据时 workflow 必须停止。实现不得通过禁用 UAC、开放宽泛 firewall rules、启用 Administrator login 或更改账户策略来补偿。

Windows live run 中的真实手机客户端连接是 release acceptance 要求，不能替代自动化检查。

## 11. 桌面收尾和诊断

Windows 桌面收尾必须保持状态：

- 最小化现有 UU Remote top-level windows，不启动应用，也不将它带到前台。
- 不在安全对话框中合成点击。
- 在可观察时验证最终窗口状态。
- 捕获桌面时不改变焦点。
- 把 PNG 文件存入 `${RUNNER_TEMP}/uuremote-diagnostics/`。
- 使用经过清理的 labels 和确定性的 filename prefixes。

在 debug level `3` 下，20 个 live samples 都观察已经完成收尾的状态，不得重新激活 UU Remote。

macOS 保留已有的隐私权限和桌面收尾实现，但 workflow artifact 名称和共享 debug contract 与 Windows 对齐。

## 12. Shutdown-aware wait

两个平台都把 `wait_connections_seconds` 验证为 `0` 到 `21000` 之间的整数，包含端点。值为 `0` 时立即返回，不进行应用 preflight 或启动 watcher。

公共结果 contract 是：

- `WAIT_RESULT=timeout`
- `WAIT_RESULT=shutdown/restart`

Windows watcher 使用隐藏的原生 top-level window 和 message loop 观察 `WM_QUERYENDSESSION`。它不取消关机。单独的 injected-event argument 用于确定性的 self-tests，不会关闭测试主机。

实现不单独依赖 `Win32_ComputerShutdownEvent`：Microsoft 文档说明，本地应用可能在该 WMI event 送达之前就被终止。PowerShell 负责 watcher 的编译或启动，验证其 exit 和 output，并在 `finally` blocks 中删除临时 binaries 和 event resources。

## 13. 幂等性

在 debug level `2` 和 `3` 下，Windows 在同一个 runner session 中重复安全配置检查：

- 复用已经运行的应用。
- Device ID 就绪仍然成功。
- 应用相同自定义码成功且不记录其值。
- 就绪证据保持正常。
- 窗口已经最小化时，桌面收尾保持 no-op。

第二次执行不得安装另一份副本、启动重复 processes、更改账户策略或扩大权限。

## 14. 错误处理和清理

- 无效的用户控制值或缺少必需 secret 时返回 exit code `2`。
- 安装、CLI、watcher、readiness、screenshot 或 desktop-finalization 失败时返回 exit code `1`。
- 不允许任何无边界 retry loop。
- 配置步骤失败后不得启动生产等待。
- Event subscriptions、watcher processes、临时编译文件和截图资源必须在 `finally` blocks 中清理。
- Debug artifact upload 同时使用 `if: always()` 和非零 debug gate，并且只允许明确配置的 missing-file 行为。
- 错误消息只能标明失败阶段和脱敏 exit status，绝不包含 secret 值。

## 15. 自动化测试

新增 `tests/test_windows_parity.py`。测试读取真实仓库文件，并在 Windows 上直接调用 validation 和 self-test modes。

测试范围包括：

- 匹配的 workflow inputs、defaults、debug 含义和等待范围。
- 共享语义步骤顺序和 conditions。
- Step-scoped 自定义码 secret 处理以及不存在硬编码值。
- Windows helper mode dispatch 和 validation exit codes。
- 有边界的应用及 device ID readiness。
- 保持状态的桌面收尾和诊断路径。
- Wait timeout、zero、invalid input、injected ordinary event 和 injected shutdown event。
- 六提交文档规则和现有 agent-environment contracts 保持不受影响。

继续运行现有 macOS contract tests。需要 Bash 和 AppKit 的 behavior tests 仍按平台进行 gate；不得在不兼容的 Windows host 上把它们报告为通过。

所有行为变更都遵循 red-green-refactor：先增加聚焦的失败 contract，观察预期失败，实现最小行为，然后在保持 green 的前提下重构。

## 16. Live validation matrix

本地和 review gates 通过后，在不显示 repository secrets 值的前提下验证 Windows workflow：

1. `debug_level=1`、`wait_connections_seconds=0`：验证自定义码配置、最终截图、artifact upload 和真实手机客户端连接。
2. `debug_level=2`、`wait_connections_seconds=0`：验证第二次配置具备幂等性。
3. `debug_level=3`、`wait_connections_seconds=0`：验证 20 个保持状态的 live samples。
4. `debug_level=0`、`wait_connections_seconds=5`：验证不生成 artifact，并得到 timeout result。
5. 一次专用的远程关机或重启 run：在主机存活到足以报告结果时，验证 shutdown-aware path。

任何 live failure 都使用经过脱敏的 logs 和 diagnostics 进入 systematic debugging。失败不构成削弱操作系统保护的授权。

## 17. 文档与发布

更新两种语言的 README，说明已经对齐的公共 contract 和平台特有例外。新增双语 implementation-plan 文档。只有当 runtime contract 确实改变时才更新现有 tests 和历史事实；不得改写历史记录来暗示 Windows parity 以前已经存在。

实现工作在 feature branch 的隔离 worktree 中进行。每个 plan task 都需要聚焦测试和 code review。最终完成要求包括适用的本地 tests、干净的结构文档检查、带 revision range 的 `git diff --check`、完整分支 review，以及 live validation matrix，或明确记录仍在等待授权的外部验证。

## 18. 验收标准

满足以下条件时工作完成：

- 两份 workflow 公开批准的 inputs 和 debug 语义。
- 两份 workflow 都安全使用 `UUREMOTE_CUSTOM_CODE`，active runtime 配置中不再存在硬编码自定义码。
- Windows runtime 行为在独立 helper 和原生 watcher 中实现。
- Windows 执行有边界的 readiness checks、保持状态的 diagnostics、幂等性验证和共享 wait contract。
- Windows 不消费账户密码 secret，也不修改用户、Administrator、autologin、UAC、firewall 或 SSH policy。
- 自动化 tests 在适用 hosts 上通过，且准确说明 platform-only limitations。
- Windows live acceptance run 建立真实远程连接并验证批准的诊断行为。
- 英文与简体中文文档保持含义等价且结构有效。
