# UU远程 macOS 三项被控权限自动化设计

[English](2026-08-10-uuremote-three-permissions-design.md) | [简体中文](2026-08-10-uuremote-three-permissions-design-zh_CN.md)

## 目标

在 GitHub Actions 的 macOS 26 图形桌面会话中，通过命令行和 AppleScript 自动完成 UU远程作为被控端所需的三项设置：

1. 使用 `uuyc-cli assist allow on` 开启“允许本设备被控”，并确认 CLI 返回 `enabled: true`。
2. 在“系统设置 → 隐私与安全性 → 辅助功能”中为 `/Applications/UURemote.app` 开启权限。
3. 在“系统设置 → 隐私与安全性 → 录屏与系统录音”中为 `/Applications/UURemote.app` 开启权限。

完成后重启 UU远程，确认 CLI 恢复并可从手机客户端连接和操作键鼠。脚本再次执行时不得重复添加应用、关闭已有权限或产生失败提示。

## 范围

修改以下文件：

- `.github/workflows/apple.sh`：实现三项设置、验证、重启和诊断截图。
- `.github/workflows/macos.yml`：运行首次设置、同机幂等性验证，并上传截图 artifact。

不修改安装方式、验证码设置方式、workflow 的 runner 类型，也不直接写入 macOS TCC 数据库。

## 方案

### 允许本设备被控

在 `apple.sh` 中先确保 UU远程已在图形桌面用户会话中启动并等待 CLI 就绪，再执行 `uuyc-cli assist allow on`，而不是依赖 workflow 中分散的预处理命令。命令失败时按照现有模式每 500 毫秒重试，设置完成后读取返回 JSON，只有同时满足命令成功以及 `enabled: true` 才继续。

将该逻辑放入 `apple.sh` 可保证脚本独立运行时也具备完整功能。`macos.yml` 中原有的同名设置可以删除，避免两处实现漂移。

### 系统隐私权限

把当前只处理“录屏与系统录音”的 AppleScript 主流程提取为可复用的权限处理器。处理器接收：

- 系统设置页面 URL；
- 英文窗口标题；
- 权限名称和截图标签；
- UU远程应用路径；
- 管理员密码和截图目录。

调用顺序为：

1. 辅助功能：`Privacy_Accessibility`，窗口标题 `Accessibility`。
2. 录屏与系统录音：`Privacy_ScreenCapture`，窗口标题 `Screen & System Audio Recording`。

每个页面执行相同的状态驱动流程：

1. 等待窗口标题就绪后才遍历可访问性树。
2. 查找 UU远程现有行；存在且开关已开时直接成功。
3. 不存在时定位列表下方的加号，处理管理员授权。
4. 从 `/etc/kcpassword` 还原 runner 自动登录密码，并在提交前用 `dscl -authonly` 验证，绝不输出明文。
5. 在文件选择器中选择 `/Applications/UURemote.app`。通过当前焦点角色判断 “Go to Folder” 是否仍打开，避免依赖固定 Return 次数。
6. 兼容选择应用后直接出现 `Quit & Reopen`，以及仍需按 `Open` 的两种路径。
7. 重新定位应用行，确认开关已开；若关闭则先停止 UU远程进程，再开启并处理重启提示。

两项权限处理完成后统一重启 UU远程，避免每项权限各重启一次。

## 应用识别

兼容以下列表显示名称：

- `UU远程`
- `UURemote`
- `UU Remote`
- `网易UU远程`
- `网易 UU 远程`

首次添加后优先用“新增行相对于添加前行标题的差集”定位开关，从而兼容未来显示名称变化。幂等执行时使用上述已知名称识别现有行。

## 诊断与安全

- 只在图形桌面用户 UID 下操作 System Settings 和 UU远程。
- 管理员密码只保存在 shell/AppleScript 进程内存中，验证和使用后立即取消 shell 变量；日志不输出密码或密码字段值。
- 每个权限页面在关键文件选择阶段生成窗口范围 JPEG 截图。
- workflow 使用 `actions/upload-artifact@v4`，并在失败时也上传截图。
- 所有等待均有明确超时和包含权限名称的错误消息。
- 不直接修改 TCC 数据库、AuthorizationDB 或关闭 SIP。

## 验证

workflow 在同一台 runner 上执行：

1. 首次运行 `apple.sh`，验证三项设置完成。
2. 再次运行 `apple.sh`，验证两个系统权限均被识别为已开启，“允许本设备被控”仍为 `enabled: true`，且不再次添加应用。
3. 上传两类权限页面截图。
4. 进入保活步骤，供手机客户端实际连接验证画面和键鼠操作。

成功标准：

- 首次运行和同机第二次运行均以退出码 0 结束。
- 日志分别显示辅助功能和录屏与系统录音权限已启用或已处于启用状态。
- CLI 返回网络正常、`success: true`，并确认 `assist allow` 的 `enabled: true`。
- 手机客户端既能看到画面，也能使用键盘和鼠标操作被控端。
