# HelloWorldRemote

[English](README.md) | [简体中文](README-zh_CN.md)

## Purpose

HelloWorldRemote automates GitHub Actions runners for UU Remote/GameViewer. The macOS and Windows workflows configure their respective hosts, launch the application, apply the repository custom code, and leave the runner available for remote connections while sharing one public workflow contract.

## Workflows

- [macOS workflow](.github/workflows/macos.yml) and [Windows workflow](.github/workflows/windows.yml) are manually dispatched platform workflows.
- Both workflows expose required `workflow_dispatch` inputs: `debug_level`, with values `0` through `3` and default `0`, and `wait_connections_seconds`, an integer from `0` through `21000` with default `300`.
- Both workflows require the `UUREMOTE_CUSTOM_CODE` repository secret. Only macOS also requires the `UUREMOTE_ACCOUNT_PASSWORD` repository secret for its host configuration.

## Diagnostics and connection waits

The debug levels are cumulative on both platforms:

- `0`: fast production path; no screenshots or diagnostic artifact; run the connection wait.
- `1`: run diagnostic self-tests and capture the finalized desktop.
- `2`: level 1 plus repeat configuration and verify idempotency.
- `3`: level 2 plus 20 state-preserving live samples at 15-second intervals.

Both platforms upload the `uuremote-diagnostics` artifact only when `debug_level` is non-zero. At level `0`, `wait_connections_seconds` controls the connection wait.

## Platform security boundaries

Treat repository secrets as secrets: do not place them in repository files, issues, logs, screenshots, or artifacts. Workflows mask and use secrets only in the steps that need them.

Windows does not change user or Administrator passwords, enable automatic login, consume `UUREMOTE_ACCOUNT_PASSWORD`, or change UAC, Windows Firewall, or SSH policy. It also does not weaken any operating-system permission boundary or invent undocumented UU Remote CLI commands.

## Repository layout

- `.github/workflows/` contains the macOS and Windows Actions workflows and their platform-specific helpers.
- `AGENTS.md` and `CLAUDE.md` contain English agent instructions; their `-zh_CN` counterparts contain Simplified Chinese translations.
- `docs/prompts/` contains reusable conversation-capture instructions.
- `tests/` contains workflow and repository-contract tests.

## Validation and end-to-end acceptance

Run local validation with:

```powershell
python -m unittest discover -s tests -v
```

Platform-only behavior is skipped only on incompatible hosts; it must run on compatible hosts.

End-to-end acceptance requires the applicable GitHub repository secrets and a manually dispatched macOS or Windows workflow. Do not dispatch a workflow or expose a secret without current authorization. Verify the selected platform's expected diagnostic behavior and real remote-client connectivity in that manual run.
