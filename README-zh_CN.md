# HelloWorldRemote

[English](README.md) | [简体中文](README-zh_CN.md)

## 用途

HelloWorldRemote 为 UU Remote/GameViewer 自动化 GitHub Actions runner。macOS 和 Windows 工作流会配置各自的平台主机、启动应用程序、应用 repository custom code，并在共享同一公开工作流 contract 的同时使 runner 保持可供远程连接。

## 工作流

- [macOS 工作流](.github/workflows/macos.yml) 和 [Windows 工作流](.github/workflows/windows.yml) 都是手动触发的特定平台工作流。
- 两个工作流都提供必填的 `workflow_dispatch` inputs：`debug_level` 可取 `0` 到 `3`，默认值为 `0`；`wait_connections_seconds` 为从 `0` 到 `21000` 的整数，默认值为 `300`。
- 两个工作流都需要 `UUREMOTE_CUSTOM_CODE` repository secret。只有 macOS 还需要 `UUREMOTE_ACCOUNT_PASSWORD` repository secret 来配置其主机。

## 诊断与连接等待

两个平台的 debug level 均为累积式：

- `0`：快速生产路径；不生成截图或诊断 artifact；执行连接等待。
- `1`：运行诊断 self-test 并捕获完成 finalization 的 desktop。
- `2`：包含 level 1，并重复配置且验证 idempotency。
- `3`：包含 level 2，并以 15 秒间隔采集 20 个保持状态的实时样本。

两个平台仅在 `debug_level` 非零时上传 `uuremote-diagnostics` artifact。在 level `0` 时，`wait_connections_seconds` 控制连接等待。

## 平台安全边界

请将 repository secret 视为秘密：不要将其写入 repository 文件、issue、日志、截图或 artifact。工作流会先遮蔽 secret，并仅在需要它们的步骤中使用。

Windows 不会更改用户或 Administrator 密码、启用 automatic login、使用 `UUREMOTE_ACCOUNT_PASSWORD`，或更改 UAC、Windows Firewall 或 SSH policy。它也不会削弱任何 operating-system permission boundary，或虚构未记录的 UU Remote CLI command。

## 仓库结构

- `.github/workflows/` 包含 macOS 和 Windows Actions 工作流及其各自的平台 helper。
- `AGENTS.md` 和 `CLAUDE.md` 包含英文 agent instructions；其 `-zh_CN` counterpart 包含简体中文翻译。
- `docs/prompts/` 包含可复用的会话捕获说明。
- `tests/` 包含工作流和 repository-contract tests。

## 验证与端到端验收

请使用以下命令运行本地验证：

```powershell
python -m unittest discover -s tests -v
```

仅限平台的行为只会在不兼容的 host 上跳过；在兼容的 host 上必须执行。

端到端验收需要适用的 GitHub repository secrets 以及手动 dispatch 的 macOS 或 Windows workflow。未经当前授权，请勿 dispatch workflow 或暴露 secret。在该手动运行中，验证所选平台预期的诊断行为以及真实 remote client connectivity。
