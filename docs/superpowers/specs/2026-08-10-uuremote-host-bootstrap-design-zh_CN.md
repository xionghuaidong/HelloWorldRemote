# UU Remote macOS 主机引导设计

[English](2026-08-10-uuremote-host-bootstrap-design.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-design-zh_CN.md)

**日期：** 2026-08-10\
**状态：** 已在对话中批准；等待书面 spec 审查\
**范围：** `.github/workflows/macos.yml` 和 `.github/workflows/apple.sh`

## 1. 目标

扩展现有 UU Remote macOS workflow，使新配置的 GitHub Actions runner 或远程物理 Mac 能在 UU Remote 权限自动化运行前准备就绪。

引导过程必须：

1. 为图形用户和 root 设置一个调用方提供的密码，但不启用 root 登录。
2. 保持图形用户的 login keychain 和 `/etc/kcpassword` 与该密码同步。
3. 仅当 root login keychain 已存在时更新其密码。
4. 将简体中文配置为第一首选语言，将英文（新加坡）配置为第二语言，并将新加坡配置为地区，且不重启或注销。
5. 保留现有 UU Remote 安装、权限、debug、等待和 artifact 行为。
6. 同时支持英文和简体中文 macOS 权限界面。

## 2. Workflow 输入和 Secret 处理

添加一个明文 `workflow_dispatch` string 输入：

```yaml
account_password:
  description: Password for the console user, root, login keychains, and auto-login data
  required: true
  default: john.doe
  type: string
```

对于这个临时 debug workflow，该输入有意采用明文。workflow 必须在任何可能回显该值的操作之前，立即使用 `::add-mask::` 向 GitHub Actions 注册该值。

密码只能通过名为 `UUREMOTE_ACCOUNT_PASSWORD` 的 step-scoped 环境变量公开给主机配置步骤。不得将其放入 job-wide 或 workflow-wide 环境变量，也绝不得打印它。

## 3. Workflow 顺序和脚本入口点

workflow 顺序为：

```text
Checkout
Configure accounts, keychains, kcpassword, languages, and region
Install UU Remote
Configure unattended access/code
Grant UU Remote permissions
Handle the private-window-picker prompt
Run the existing debug, idempotency, connection-wait, and artifact logic
```

Checkout 保持第一，因为它提供 `apple.sh`。主机配置是第一个修改 macOS 状态的步骤，必须在 UU Remote 安装前运行。

`apple.sh` 增加专用的 `configure-host` mode。正常调用仍为 UU Remote 权限流程。debug-level 幂等性重跑必须只重跑权限流程；不得重复主机配置。

## 4. 账户发现和前置条件

脚本必须从 `/dev/console` 发现图形用户，不得硬编码 `runner`。它必须从 Directory Services 获取用户 home directory，而不是使用调用进程的 `$HOME`。

如果满足以下任一条件，配置 mode 必须安全失败：

- console UID 不是普通图形用户 UID。
- 无法在 Directory Services 中解析 console account。
- `UUREMOTE_ACCOUNT_PASSWORD` 缺失或为空。
- 无法访问所需系统工具或文件。

任何失败路径均不得启用 root、启用 SSH root 登录、重启 macOS 或注销 console user。

## 5. 图形用户密码事务

图形用户的账户密码、login keychain 密码和 `/etc/kcpassword` 构成一个逻辑事务。

### 5.1 发现当前状态

脚本首先检查 `account_password` 是否已经能验证图形用户。它还会独立检查用户 login keychain 是否已能用该密码解锁，以及解码后的 `/etc/kcpassword` 是否等于该密码。

如果需要当前账户密码，脚本可以解码现有 `/etc/kcpassword`，但在将解码值视为有效旧账户密码前，必须使用 Directory Services 验证它。

这种状态优先方法支持在上一次运行部分完成后重试。

### 5.2 更新顺序

只更改不匹配的组件：

1. 当用户 login keychain 尚不接受新密码时，更新其密码。
2. 当新密码尚不能验证图形用户时，更新图形用户的 Directory Services 密码。
3. 当 `/etc/kcpassword` 的解码值尚不匹配时，替换它。

脚本必须先验证每个已完成操作，再继续执行。

### 5.3 回滚

变更前，保留足够的内存状态和 `/etc/kcpassword` 的受保护临时副本，以回滚本次运行所做的更改。

- 如果 login keychain 已更改但用户密码更改失败，则恢复 login keychain 密码。
- 如果用户密码已更改但 `/etc/kcpassword` 替换或验证失败，则恢复用户密码、恢复 keychain 密码，并恢复原始 `/etc/kcpassword`。
- 如果之后的 root 更新失败，则在原始验证状态允许时回滚图形用户事务。

临时文件必须在成功和失败时都删除。

## 6. `/etc/kcpassword` 编码和替换

脚本必须使用 Apple 已确立的静态 XOR key 格式编码和解码 `/etc/kcpassword`，包括正确的 block padding 和 termination 行为。codec 必须能处理标点符号和其他密码字符，且不得发生 shell interpolation 或日志泄露。

写入必须使用受保护的临时文件，然后执行原子替换。最终文件必须由 `root:wheel` 所有，mode 为 `0600`。

替换后，脚本必须解码最终文件并与 `account_password` 比较。不匹配即为事务失败，并触发回滚。

## 7. Root 密码和 Root Login Keychain

root 在图形用户事务后更新。

脚本必须将 root 的账户密码设为 `account_password`，但必须保留 root 的禁用登录状态。不得调用任何启用 root 用户的操作，也不得更改 SSH `PermitRootLogin` 或相关 SSH 设置。

### 7.1 现有 root login keychain

如果 root login keychain 存在：

- 如果它已经能用 `account_password` 解锁，则保持不变。
- 如果能用经过验证的旧密码解锁，则就地更改其密码并验证新密码。
- 如果无法解锁，则将其移动到受保护的临时 backup，并使用 `account_password` 创建替代 login keychain。

需要替代 keychain 时：

- 完整引导成功后，永久删除旧 backup。
- 后续任何引导失败时，删除替代 keychain，并将旧 keychain 恢复到原始位置。

如果不存在 root login keychain，不得只为此 workflow 创建空 keychain。

必须验证 root 账户密码更改，同时继续确认 root 直接登录保持禁用。

## 8. 语言、Locale 和地区

语言和地区独立配置。

期望的语言顺序是：

1. 新加坡简体中文，先尝试 `zh-Hans-SG`。
2. 英文（新加坡），`en-SG`。

写入第一选择后回读该值。如果 macOS 拒绝它或将其规范化为不可用的值，则改用 `zh-Hans-CN` 作为第一语言。英文（新加坡）仍保持第二。

将地区设为新加坡，locale 设为 `zh_SG`。回读所有设置，并验证有效语言顺序、locale 和地区。如果已经正确，则不得重写。

任何步骤都不得重启 macOS 或注销 console user。

### 8.1 重启提示

仅在实际语言或地区更改后，检查 System Settings 和系统通知对话框中的重启提示。只点击精确、已知的否定操作：

- `Not Now`
- `Later`
- `Restart Later`
- `稍后`
- `暂不`
- `以后再说`

绝不点击 `Restart Now`、`现在重新启动`、无标签的默认按钮或任何有歧义的操作。如果找不到精确且安全的否定操作，则报告该对话框并在不点击的情况下失败。

## 9. 双语 UU Remote 权限自动化

根据官方 macOS 帮助页面，现有权限自动化必须继续只以 UU Remote 主应用程序为目标。不得单独向 `UURemoteServer` 授予权限。

selector 词汇必须至少支持：

| 用途 | 英文 | 简体中文 |
|---|---|---|
| Accessibility 页面 | `Accessibility` | `辅助功能` |
| 屏幕录制页面 | `Screen & System Audio Recording` | `录屏与系统录音` |
| 允许操作 | `Allow` | `允许` |
| 打开设置操作 | `Open System Settings` | `打开系统设置` |

现有接受的 app label 仍然有效：`UU远程`、`UURemote`、`UU Remote`、`网易UU远程` 和 `网易 UU 远程`。

private-window-picker 确认不得依赖其完整英文说明句。它必须通过以下所有条件精确识别对话框：

- requester 恰好为 `com.netease.uuremote.agent`。
- 对话框提供已识别的双语 Allow 操作。
- 对话框结构还提供已识别的双语 Open System Settings 操作。

只有所有条件都匹配后，脚本才可以点击 Allow。这会防止接受无关的授权对话框。

权限流程可能重启 System Settings。因此，同一次 workflow run 必须能容忍语言 preference 更改后界面从英文切换为中文。

## 10. 幂等性和恢复

主机配置必须能在成功或中断后安全重跑：

- 已经能验证的图形用户密码不会被重置。
- 已经能解锁的用户 login keychain 不会被更改。
- 匹配的 `/etc/kcpassword` 不会被重写。
- 已经能解锁的 root keychain 不会被更改。
- 不存在的 root keychain 不会被创建。
- root 在每次运行中都保持禁用。
- 正确的语言、locale 和地区值不会被重写。
- 只在实际语言或地区更改后扫描重启提示。

现有 debug-level 含义保持不变，包括权限幂等性和 connection keepalive diagnostics 是否运行。主机配置本身不与这些 debug level 绑定。

## 11. 验证策略

实施遵循测试优先开发。

### 11.1 静态 workflow 和脚本测试

首先为以下各项创建失败检查：

- `account_password` 存在、是 string，并且默认为 `john.doe`。
- 主机配置在 UU Remote 安装前运行。
- 密码环境变量仅限配置步骤作用域。
- 没有命令启用 root 或更改 SSH root-login 设置。
- `/etc/kcpassword` 替换是原子的，并具有要求的所有者和 mode。
- 已体现 root keychain fallback、恢复和成功清理。
- 存在英文和简体中文 selector。
- 权限幂等性不再次调用 `configure-host`。

### 11.2 Codec 和语法测试

针对以下情况测试 `/etc/kcpassword` 编码和解码 round trip：

- 默认密码。
- 包含空格和 shell 标点的密码。
- codec block boundary 附近的长度。
- 正确的 padding 和 termination。

触发 GitHub Actions 前运行 Bash 和 YAML 语法/静态验证。

### 11.3 GitHub Actions 集成运行

使用：

```text
account_password = john.doe
debug_level = 0
wait_connections_seconds = 0
```

run 必须在不打印密码的情况下验证：

- 图形用户可使用配置的密码通过验证。
- 图形用户的 login keychain 可用该密码解锁。
- `/etc/kcpassword` 解码为该密码。
- root 的账户密码已更新，同时 root 保持禁用。
- 现有 root login keychain 可用该密码解锁。
- 有效语言顺序以及新加坡地区/locale 正确。
- 未发生重启或注销。
- UU Remote 权限流程在当前图形会话中完成。

## 12. 非目标

此变更不会：

- 启用直接 root 登录。
- 启用 SSH root 登录。
- 安装或配置 SSH。
- 重启或注销 Mac。
- 向每个应用程序授予权限。
- 单独向 `UURemoteServer` 授予权限。
- 在 workflow 输入和所需 macOS 状态之外持久化明文密码。
- 更改已确立的 debug-level 或 connection-wait 语义。

## 13. 参考资料

- [Apple：在 Mac 上更改“语言与地区”设置](https://support.apple.com/en-gb/guide/mac-help/intl163/mac)
- [Apple：如何在 Mac 上启用 root 用户或更改 root 密码](https://support.apple.com/en-au/102367)
- [Apple Developer：关于 user defaults system](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)
- [security keychain settings 命令参考](https://ss64.com/mac/security-keychain-settings.html)
- [Apple：如果 Mac 上的自动登录不可用](https://support.apple.com/en-la/102316)
- [GitHub Actions macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
