# UU Remote Secrets 与关机感知等待设计

[English](2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design.md) | [简体中文](2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design-zh_CN.md)

## 目标

移除明文账户密码 workflow 输入，并让 `Wait connections` 仅在 macOS 开始关机或重启时提前结束。

等待步骤不得因为 UU Remote 断开连接、UU Remote 进程退出、网络不可用或图形用户注销而提前结束。

## 范围

此变更涵盖：

- 从 GitHub Actions repository secret 获取共享账户密码；
- 保留现有的主机密码、login keychain 和 `/etc/kcpassword` 配置行为；
- 用有界的关机感知等待替换固定等待；
- 自动化 contract 测试和 macOS 行为测试。

此变更不修改 UU Remote 权限自动化、debug level 语义、locale 选择，也不修改受支持的 `wait_connections_seconds` 范围。

## 密码 Secret

移除可见的 `workflow_dispatch.inputs.account_password` 输入。workflow 将改为读取以下 repository Actions secret：

```text
UUREMOTE_ACCOUNT_PASSWORD
```

`Configure host` 步骤只通过同名环境变量向该步骤公开 secret。运行主机配置前，它会以清晰的错误拒绝缺失或空值。它不会回退到 `john.doe` 或任何其他默认值。

GitHub 会自动屏蔽 secret 值。该步骤还会在调用 `apple.sh` 前向 Actions 日志屏蔽器注册该值；任何命令都不得打印该值。

该 secret 仍是以下各项使用的唯一值：

- 图形桌面用户的账户密码；
- root 账户密码，但不启用直接 root 登录；
- 图形用户的 login keychain 密码；
- root login keychain 密码；
- `/etc/kcpassword`。

## 等待 Contract

现有 `wait_connections_seconds` workflow 输入仍为整数，默认值为 300，有效范围为包含端点的 0 到 21000 秒。

`Wait connections` 有两条成功完成路径：

1. 请求的持续时间已过；或
2. macOS 发出系统定义的关机事件，表示关机或重启正在进行。

值为 0 时立即返回，并且不启动 AppKit watcher。

任何 UU Remote CLI、进程、socket、连接或网络状态都不参与此决定。用户注销绝不会被解释为成功的提前完成。

## 关机检测

`apple.sh` 将公开一个由 `macos.yml` 使用的专用等待命令。该命令会将一个已签入的小型 Swift/AppKit 源文件编译为临时 helper，并在活跃的图形会话中运行它。helper 不会显示窗口，也不会出现在 Dock 中。

helper 将运行 AppKit event loop，并为 `NSEvent.EventType.systemDefined` 同时安装 local 和 global monitor。仅当事件 subtype 为 `NSEvent.EventSubtype.powerOff` 时它才完成。Apple 将该 subtype 定义为表明系统关机或重启正在进行的事件。

同时使用两个 monitor，是因为 local monitor 可以看到分派给 helper 本身的事件，而 global monitor 可以看到分派给其他应用程序的匹配事件副本。第一个匹配事件胜出；清理操作是幂等的。

有意不使用 `NSWorkspace.willPowerOffNotification` 作为完成条件，因为 Apple 文档说明该通知也会在注销时发生。进程 `SIGTERM`、UU Remote 进程退出和连接轮询也不是完成条件，因为它们无法唯一识别关机或重启。

helper 将使用 monotonic timer 计量请求的持续时间。它会打印一个简短完成原因（`timeout` 或 `shutdown/restart`）并成功返回。初始化或编译失败会返回非零值，使 workflow 不会静默跳过请求的等待。

临时 binary 和 build directory 会在每次正常退出以及 shell 捕获到的终止路径中删除。

## Workflow 集成

`macos.yml` 保留对 `wait_connections_seconds` 的校验，然后调用新的 `apple.sh` 等待命令，而不是调用一个固定的 `sleep`。

此步骤仍位于 UU Remote 启动和权限配置之后，现有的 workflow debug-level gate 保持不变。其完成决定不依赖 debug level、截图、artifact、幂等性检查或 level-3 live diagnostic sampler。

## 失败和生命周期行为

- 密码 secret 缺失或为空：在任何密码变更之前失败。
- 等待值无效：在启动 watcher 前失败。
- Swift/AppKit helper 无法编译或初始化：等待步骤失败。
- UU Remote 断开或退出：继续等待。
- 网络不可用：在本地继续等待。
- 图形用户注销：不要报告成功的提前完成。如果注销销毁了图形会话或其中的 GitHub runner，普通进程终止仍可能中断 job；不得将其误标为关机/重启匹配。
- 系统开始关机或重启：打印原因并立即从等待中返回。
- workflow 被取消或 shell 被外部终止：遵循正常的进程终止行为；shell 收到可捕获的 signal 时清理临时文件。取消不会被报告为关机事件。

真实关机开始后，runner 可能在向 GitHub 发送最终步骤结果前失去网络。局部等待可以结束并记录其原因，但 GitHub job 仍可能显示为已中断或已断开。workflow 不得声称其能在断电后保证最终远程状态。

## 测试

Python contract 测试将验证：

- 可见的 `account_password` 输入不存在；
- workflow 对此密码仅引用 `secrets.UUREMOTE_ACCOUNT_PASSWORD`；
- 主机配置拒绝空 secret；
- 输入默认值和允许范围仍为 300 以及 0 到 21000；
- `Wait connections` 调用 `apple.sh` 等待命令，而不是固定的 `sleep`；
- production event predicate 同时要求 `systemDefined` 和 `powerOff`；
- `NSWorkspace.willPowerOffNotification`、UU 进程状态和网络状态不会驱动完成。

AppKit helper 将提供一个仅用于测试的 event-injection mode，并在 macOS runner 上执行。行为测试将验证：

- 较短的持续时间通过 timeout 完成；
- 注入普通系统事件不会完成等待；
- 注入 `systemDefined`/`powerOff` 事件会使其提前完成；
- 零秒直接返回且不启动 helper。

在报告完成前，现有测试套件、Bash 语法检查、`git diff --check` 和端到端 GitHub Actions run 必须全部通过。

## 推出

运行更新后的 workflow 前，配置 repository Actions secret `UUREMOTE_ACCOUNT_PASSWORD`。第一次端到端 run 应使用较短等待，以验证正常 timeout 行为。然后可以在一次性 macOS runner 或目标机器上确认实际关机/重启处理，并接受主机断电后 GitHub 报告方面的已知限制。
