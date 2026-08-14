# UU Remote 桌面收尾与自定义代码 Secret 设计

[English](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design.md) | [简体中文](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design-zh_CN.md)

## 目标

让活跃的 macOS 图形会话无需重启或注销即可立即接受 UU Remote 控制。必须关闭所有权限对话框和 System Settings 窗口；UU Remote 必须保持运行，其普通窗口应最小化；Finder 和菜单栏时钟必须使用新加坡地区的简体中文；Terminal 窗口必须在其 shell 退出时关闭；键盘重复控制必须使用 System Settings 中可用的最快值。

用必需且经过验证的 GitHub Actions repository secret 替换硬编码的 UU Remote 自定义代码。

## 全局约束

- 不得重启 macOS。
- 不得注销活跃图形用户。
- 不得终止无人值守控制所需的 UU Remote 后台服务。
- 继续支持英文和简体中文 macOS 界面。
- 保留现有 debug level 含义和权限幂等性。
- 对安全提示使用 accessibility 结构和精确的本地化按钮标题；不得使用屏幕坐标或盲目提交 Return 键。
- 保持直接 root 登录为禁用状态，不得改变现有 account-secret 行为。

## 最终桌面 Contract

在 `apple.sh` 成功完成之后、`Wait connections` 开始之前：

1. requester 为 `com.netease.uuremote.agent` 的 private-window-picker 提示已经按下其精确的 `Allow` 或 `允许` 操作，并且不再可见；
2. 任何说明 UU Remote 退出前无法录制的屏幕录制重启提示，已经按下其精确的 `Quit & Reopen`、`Quit and Reopen` 或 `退出并重新打开` 操作，并且不再可见；
3. UU Remote 正在运行、无人值守控制已启用，并且每个普通 UU Remote 窗口都已最小化；
4. System Settings 没有可见窗口，并且 Screen & System Audio Recording 页面已关闭；
5. Finder 菜单使用简体中文，而不是 `File`、`Edit`、`View`、`Go`、`Window` 和 `Help`；
6. 菜单栏时钟不包含英文星期或月份名称，并反映新加坡简体中文 locale；
7. 每个现有 Terminal `Window Settings` profile 都有 `shellExitAction=0`，因此 Ctrl+D 或其他正常 shell 退出会关闭其窗口；
8. `NSGlobalDomain KeyRepeat` 为 `2`，`InitialKeyRepeat` 为 `15`，与 System Settings 提供的最快重复速率和最短延迟一致。

## 架构

现有主机和权限脚本将增加三个有界单元。

### 桌面偏好配置

`configure_desktop_preferences` 作为 `configure-host` 的一部分运行，位于语言和地区值选定之后。它将：

- 保持现有首选语言顺序：先 `zh-Hans-SG`，再 `en-SG`，并保留现有 `zh-Hans-CN` fallback；
- 保持 `AppleLocale=zh_SG` 和新加坡公制设置；
- 在图形用户的全局 preferences 中设置 `KeyRepeat=2` 和 `InitialKeyRepeat=15`；
- 更新图形用户 `com.apple.Terminal.plist` 中 `Window Settings` 下的每个 dictionary，使 `shellExitAction` 为整数 `0`；
- 在继续之前验证持久化的 plist 和全局 preference 值；
- 仅重新加载图形用户的 preference cache、Finder 和 SystemUIServer，使新的本地化无需机器重启或用户注销即可显示；
- 等待 Finder 和 SystemUIServer 恢复，然后通过 accessibility tree 验证可见的 Finder 菜单词汇和菜单栏时钟词汇。

该例程必须通过现有 account-resolution 函数发现 console user 和 home directory。不得假设用户名称为 `runner`。

### 权限事务

`ensure_uuremote_permissions` 保留现有 Accessibility 和 Screen & System Audio Recording 行检查。已经启用的行不会被切换。

当屏幕录制变更产生重启提示时，脚本将根据 UU Remote 录制文本匹配对话框，并且只按下已识别的本地化重启操作。然后等待对话框消失、UU Remote 恢复、其 CLI 恢复以及权限行继续保持启用。

添加应用程序后的现有无条件 Return 键提交将被移除。身份验证和文件选择器提交仍可使用各自经过验证的控件，但任何通用击键都不得接受权限或重启对话框。

权限持久化后，脚本将触发或观察 private-window-picker 请求，通过精确的 requester bundle identifier 匹配它，仅按下 `Allow` 或 `允许`，并等待匹配的 UserNotificationCenter 窗口消失。

### 桌面规范化

`normalize_remote_desktop` 是最后的 UI 操作。它将：

- 重新扫描两个已知对话框；如果其中任一个存在未知操作结构，则失败；
- 通过 `AXMinimized` 最小化所有普通 UU Remote 窗口，同时保持应用程序及其后台服务运行；
- 退出 System Settings，并等待其不再有可见窗口；
- 通过 UU Remote CLI 验证其仍然可用；
- 验证没有匹配的权限对话框残留；
- 验证最小化的 UU Remote 状态、已关闭的 System Settings 状态、本地化 Finder 和时钟、Terminal profile 值以及键盘值。

正常成功和错误路径都会尝试安全的桌面规范化。启用 debug 时发生错误，会在清理前捕获诊断证据。清理绝不点击含义不明确的安全操作。

## Debug-Level 行为

- Level `0`：使用基于条件的轮询，并且只进行必要的短暂等待；不创建截图或上传 artifact。
- Level `1`：使用更长的诊断宽限时间，在每个重要提示执行操作前后捕获提示，并捕获最终干净桌面。
- Level `2`：重复权限配置以证明幂等性；第二次执行必须以相同的最终桌面状态结束。
- Level `3`：保留现有 live sampler，但 snapshot 不得重新打开 UU Remote、取消其最小化或将其置于前台，也不得重新打开 System Settings。

因此，现有 `capture_snapshot` 对 `live-*` 和 `final-app*` 的特殊处理必须停止打开 UU Remote。最终证据代表新连接的远程 client 所看到的真实状态。

## 自定义代码 Secret

移除硬编码的 `xxxxxx` 值。workflow 将要求以下 repository Actions secret：

```text
UUREMOTE_CUSTOM_CODE
```

secret 仅在匹配以下表达式时有效：

```regex
^[A-Za-z0-9]{8,16}$
```

因此它只包含大写 ASCII 字母、小写 ASCII 字母和数字，长度为包含端点的 8 到 16 个字符。

workflow 只向调用 UU Remote CLI 的步骤公开该值。该步骤将：

- 在调用 CLI 前拒绝缺失、为空、过短、过长或含非字母数字字符的值；
- 向 GitHub Actions 日志屏蔽器注册该值；
- 将其传给 `uuyc-cli assist set-code`，而不打印命令或值；
- 只报告通用成功消息，而不回显 secret 或可能包含它的 CLI response；
- 使用后立即 unset 环境变量。

该值不得作为 workflow-dispatch 输入、job-level 环境变量、签入的默认值或诊断字段。

## 失败行为

- `UUREMOTE_CUSTOM_CODE` 缺失或无效：在调用 `uuyc-cli assist set-code` 前失败。
- 检测到目标提示，但没有精确的预期操作：在启用时捕获诊断，并且不点击就失败。
- 按下已识别操作，但其对话框仍可见：失败。
- UU Remote 在 `Quit & Reopen` 后未恢复：失败。
- 重新打开 System Settings 后权限未持久化：失败。
- Finder 或 SystemUIServer 在定向重新加载后未恢复：失败。
- Finder 菜单或菜单栏时钟仍为英文：失败。
- Terminal 或键盘 preference 回读与 contract 不同：失败。
- 最终验证期间无法最小化 UU Remote 或其 CLI 不可用：失败。
- 清理后 System Settings 仍有可见窗口：失败。

任何失败路径都不得重启或注销机器。

## 测试

Python contract 测试将验证：

- workflow 和脚本中不存在 `xxxxxx`；
- `UUREMOTE_CUSTOM_CODE` 是 step-scoped 的必需 secret，并且已被屏蔽；
- 精确的验证表达式只接受 8–16 个 ASCII 字母数字字符；
- 权限流程均不包含旧的添加后无条件 Return 操作；
- 三个新的有界单元存在，并按所需顺序执行；
- 目标是所有 Terminal profile，而不是一个硬编码 profile；
- 请求的键盘值恰好为 `2` 和 `15`；
- Finder 和 SystemUIServer 在不执行重启或注销命令的情况下重新加载；
- final 和 live snapshot 不会打开 UU Remote 或将其置于前台；
- 桌面规范化在 private-picker 处理之后、workflow connection wait 之前执行。

macOS Actions 验证将以两种模式运行：

1. `debug=1`、`wait=0`：检查两个提示转换和最终干净桌面的详细日志与截图 artifact；
2. `debug=0` 并使用较短等待或用户选择的等待：证明 fast path，在需要时连接真实 remote client，并验证 diagnostics 和 artifact 保持禁用。

macOS run 必须回读所有持久化 preference，并检查最终桌面 contract 的 UI accessibility tree。完成前需要完整 Python 测试套件、Bash 语法检查、`git diff --check`、干净 worktree 检查以及相匹配的本地/远程 `main` commit hash。

## 推出

运行更新后的 workflow 前，配置两个 repository Actions secret：

```text
UUREMOTE_ACCOUNT_PASSWORD
UUREMOTE_CUSTOM_CODE
```

第一次诊断 run 将使用一次性的 GitHub-hosted macOS runner。artifact 和 accessibility assertion 通过后，可以在远程物理 Mac 上使用 fast path，而无需重启或注销该机器。
