# HelloWorldRemote

[English](README.md) | [简体中文](README-zh_CN.md)

## 用途

HelloWorldRemote 会在 GitHub Actions 的 macOS runner 上自动运行 UU Remote/GameViewer：配置主机、启动应用程序，并让 runner 保持可供远程连接。

## 工作流

- [macOS 工作流](.github/workflows/macos.yml) 通过手动触发运行，是当前功能完整的工作流。
- [Windows 工作流](.github/workflows/windows.yml) 会安装并启动 GameViewer，但目前功能较少。它计划与 macOS 达成功能一致，当前不会使用 macOS 的 secrets 或 inputs。

## 必需的 secrets

macOS 工作流需要以下 GitHub repository secrets：

- `UUREMOTE_ACCOUNT_PASSWORD`：用于配置 macOS 主机帐户。
- `UUREMOTE_CUSTOM_CODE`：用于配置 UU Remote 自定义代码。

macOS 工作流会在使用前检查这两个 secret 并对其进行遮蔽。触发 macOS 工作流前，请在仓库的 Actions secrets 中配置它们。

## 输入与诊断

macOS 的 `workflow_dispatch` 接口提供：

- `debug_level`：诊断级别 `0` 到 `3`（默认值为 `0`；更高级别会按工作流说明启用截图、幂等性验证或实时采样）。
- `wait_connections_seconds`：等待连接的整数秒数，范围为 `0` 到 `21000`（默认值为 `300`）。仅当 `debug_level` 为 `0` 时使用该等待时间。

## 安全说明

请将两个必需值都作为 secret 处理：不要把它们放入仓库文件、issue 或日志。请仔细审核工作流修改，因为它们会在托管的 macOS 或 Windows 机器上以 `contents: write` 权限运行，并下载 GameViewer 安装程序。

## 仓库结构

- `.github/workflows/` 包含 macOS 与 Windows Actions 工作流，以及 macOS 辅助脚本。
- `AGENTS.md` 与 `CLAUDE.md` 是英文 agent 指令；对应的 `-zh_CN` 文件是简体中文翻译。
- `docs/prompts/` 包含可复用的会话捕获说明。
- `tests/` 包含工作流和仓库契约测试。

## 验证

可使用 Python 的 unittest runner 在本地运行聚焦的工作流测试，例如：

```powershell
python -m unittest tests.test_agent_work_environment -v
```

如需进行端到端运行，请配置两个 macOS repository secret，并从 GitHub Actions 手动触发 macOS 工作流，传入所需的诊断 inputs。
