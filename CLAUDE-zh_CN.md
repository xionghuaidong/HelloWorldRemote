# 项目说明

[English](CLAUDE.md) | [简体中文](CLAUDE-zh_CN.md)

本项目使用适用于 Claude Code 的 Superpowers 插件。

## 启动检查

`.claude/settings.json` 要求为本项目启用 Superpowers，但这项设置本身不能证明插件已经安装或成功加载。信任本文件夹后，如有需要，Claude Code 应提示安装该插件。在每个新会话开始时：

1. 检查 `superpowers:using-superpowers` skill 是否可用且可以调用。
2. 如果 `superpowers:using-superpowers` 不可用或无法调用，不要假装 Superpowers 已启用。
3. 告知用户：

   > 本项目要求使用 Superpowers，但它尚未安装或启用。
   > 运行 `/plugin install superpowers@claude-plugins-official`，然后运行 `/reload-plugins` 或启动一个新的 Claude Code 会话。

4. 除非用户明确要求，否则不要仅为安装 Superpowers 而修改仓库。

## 项目范围

* `.github/workflows/macos.yml` 定义 macOS GitHub Actions workflow contract。
* `.github/workflows/windows.yml` 定义 Windows GitHub Actions workflow contract。
* `.github/workflows/apple.sh` 实现 macOS 主机配置与 workflow 操作。
* `.github/workflows/uuremote-shutdown-wait.swift` 监视 macOS 上 UU Remote 的关机完成情况。
* `tests/` 包含仓库验证和 runtime contract tests。
* `docs/superpowers/` 包含用于指导重要工作的已批准设计和 implementation plans。

## 开发工作流

当 Superpowers 可用时，应遵循其完整工作流，而不只是使用其中测试和调试的部分。已安装的 Superpowers skill 内容是各项 skill 详细流程的 source of truth。以下规则是项目特定的最低要求，不得将其解释为削弱已安装 skills 中更严格的要求。

* 在设计重要的新行为之前使用 `superpowers:brainstorming`，让它通过提问把一个粗略的想法整理成规格说明，并在它分段呈现设计时逐段确认，而不是跳过设计直接写代码。
* 设计获得批准后，使用 `superpowers:using-git-worktrees` 在一个新分支上建立一个独立的工作区，避免直接在起始分支上进行实现。
* 在进行多步骤实现之前使用 `superpowers:writing-plans`。计划应被拆分为一个个小任务，每个任务都有明确的文件路径、代码和验证步骤。
* 使用 `superpowers:subagent-driven-development` 来执行已批准的计划，为每个任务派发一个全新的 subagent 并在每一步进行审查；如果更倾向于按批次执行并设置人工检查点，则改用 `superpowers:executing-plans`。
* 对行为变更和 bug 修复遵循 test-driven development（`superpowers:test-driven-development`）：先写一个失败的测试，确认它失败，再写出让它通过的最小代码，然后重构。
* 对测试失败和意外行为使用 `superpowers:systematic-debugging`，而不是临时性的修补。
* 在任务之间以及合并之前使用 `superpowers:requesting-code-review`。立即修复 Critical 问题，并在继续执行之前解决 Important 问题；Minor 问题可以推迟处理。
* 在处理 code review 反馈之前使用 `superpowers:receiving-code-review`，尤其是在反馈不明确或技术上存疑时。
* 在声称工作已完成、问题已修复或检查已通过之前使用 `superpowers:verification-before-completion`。
* 在工作完成并经过最新验证后使用 `superpowers:finishing-a-development-branch`。
* commit message 必须遵循 Conventional Commits。使用合适的 type，例如 `fix:`、`feat:`、`chore:`、`docs:`、`refactor:` 或 `test:`。

## 项目安全与验证

* 将帐户密码和 UU Remote custom codes 视为 secrets。UU Remote device ID 是可以记录到日志的 operational identifier；除非已批准设计另有规定，否则其他远程设备连接信息仍然是敏感信息。尤其是 `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE` 属于 secrets。
* 绝不在 source、tests、defaults、logs、screenshots 或 artifacts 中硬编码真实凭据。
* 通过 step-scoped environment variables 传递 secrets；在可能会记录命令的操作开始前进行 masking，并在可行时尽快从 environment 中移除。
* 未经明确批准的设计，不得启用直接 root 或 Administrator login，也不得削弱 SSH、UAC、firewall 或 operating-system permission controls。
* 主机配置必须具备 idempotence。变更前验证 system state，变更后验证结果；在安全恢复信息可用时，按相反顺序回滚当前运行作出的变更。
* 在允许平台特定内部实现的同时，保持对外可见的 macOS 与 Windows workflow contracts 一致。
* 完成前，确认每个根目录和 `docs/**` 下的 Markdown 文件都恰有一个正确命名的对应版本；语言导航链接解析为存在的相对路径；每份文档都具有要求的 H1、导航和空行结构；并且不存在递归后缀 `-zh_CN-zh_CN.md` 文件。
* 同时确认 `.claude/settings.json` 可解析为 JSON 且只启用预期的 Superpowers plugin；automated checks 只覆盖 machine-readable structure；review 确认共享 instructions 完整、README workflow facts 准确、capture prompts 忠实；历史英文文档与其 base versions 原则上仅有语言导航差异，但本次获授权迁移允许将已知自定义码替换为恰好六个小写 x 字符 `xxxxxx`；当前可运行的 repository tests 通过；`git diff --check e30a65b..HEAD` 通过；最终 diff 仅包含获批准的环境和文档变更。
* 如果任何对应版本缺失、任何导航链接无效、任何配置无法解析，或共享 instructions 政策不一致，则迁移尚未完成，不得作为已完成状态提交。

## 语言和文档规则

* 通过聊天界面与用户沟通时，如果用户使用简体中文，则使用简体中文回复。否则，默认使用英文，除非用户明确要求使用其他语言。
* 如果翻译常见的软件开发术语可能降低准确性或产生歧义，请保留其英文形式。
* 以下多语言文档规则适用于仓库顶级目录下的所有 `.md` 文件，以及 `docs/` 目录及其递归子目录下的所有 `.md` 文件：

  1. 先编写英文版本，再创建或更新含义等价的简体中文版本。简体中文文件名必须在 `.md` 之前的 basename 后添加 `-zh_CN`。
  2. 将带语言后缀的文件视为对应语言版本，而不是源文档。不要创建 `README-zh_CN-zh_CN.md` 之类带递归后缀的文件名。
  3. 在每个语言版本中，将导航行放在一级标题之后，并确保一级标题与导航之间、导航与后续正文之间各有且仅有一个空行。导航行必须使用相对链接指向所有可用的语言版本，并至少包含 English 和简体中文。
  4. 任一语言版本发生变更时，必须在同一次变更中同步更新所有对应版本及其导航链接。不同语言版本之间不得遗漏、增加、弱化或重新解释要求。
  5. 当行内代码块的内容本身需要包含反引号时，应使用比内容中反引号序列更长的一串反引号作为该代码块的分隔符；如果内容以反引号开头或结尾，还需在分隔符内侧各加一个空格，遵循 CommonMark 对反引号分隔行内代码块的规则。

* 源代码、配置文件、脚本、测试和代码示例中的所有注释都必须使用英文。不要在代码注释中使用中文。
* 除特定于 harness 的安装和启动说明外，`AGENTS.md` 与 `CLAUDE.md` 中共享的工作流、语言、文档、范围、安全和验证政策必须保持含义等价。
