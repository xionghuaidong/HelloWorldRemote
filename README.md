# HelloWorldRemote

[English](README.md) | [简体中文](README-zh_CN.md)

## Purpose

HelloWorldRemote automates a GitHub Actions macOS runner for UU Remote/GameViewer: it configures the host, launches the application, and leaves the runner available for remote connections.

## Workflows

- [macOS workflow](.github/workflows/macos.yml) is manually dispatched and is the complete current workflow.
- [Windows workflow](.github/workflows/windows.yml) installs and launches GameViewer, but is less complete. It is scheduled for functional parity with macOS and does not currently consume the macOS secrets or inputs.

## Required secrets

The macOS workflow requires these GitHub repository secrets:

- `UUREMOTE_ACCOUNT_PASSWORD` configures the macOS host account.
- `UUREMOTE_CUSTOM_CODE` configures the UU Remote custom code.

Both secrets are checked before use and masked by the macOS workflow. Configure them in the repository's Actions secrets before dispatching macOS.

## Inputs and diagnostics

The macOS `workflow_dispatch` interface provides:

- `debug_level`: diagnostic level `0` through `3` (`0` is the default; higher levels enable screenshots, idempotency verification, or live sampling as documented by the workflow).
- `wait_connections_seconds`: whole seconds to wait for connections, from `0` through `21000` (default `300`). This wait is used when `debug_level` is `0`.

## Security notice

Treat both required values as secrets: do not place them in repository files, issues, or logs. Review changes to the workflows carefully because they run on hosted macOS or Windows machines with `contents: write` permission and download the GameViewer installer.

## Repository layout

- `.github/workflows/` contains the macOS and Windows Actions workflows and their macOS helper script.
- `AGENTS.md` and `CLAUDE.md` contain English agent instructions; their `-zh_CN` counterparts contain Simplified Chinese translations.
- `docs/prompts/` contains reusable conversation-capture instructions.
- `tests/` contains the workflow and repository-contract tests.

## Validation

Run the focused agent-environment contract tests locally with Python's unittest runner, for example:

```powershell
python -m unittest tests.test_agent_work_environment -v
```

For an end-to-end run, configure the two macOS repository secrets and manually dispatch the macOS workflow from GitHub Actions with the desired diagnostic inputs.
