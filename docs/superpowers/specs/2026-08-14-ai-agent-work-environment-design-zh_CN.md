# AI Agent 工作环境设计

[English](2026-08-14-ai-agent-work-environment-design.md) | [简体中文](2026-08-14-ai-agent-work-environment-design-zh_CN.md)

**日期：** 2026-08-14  
**状态：** 已在会话中批准；等待书面规格审阅  
**范围：** 仓库级 AI agent 指令、双语文档脚手架、Claude Code 项目设置、忽略规则和会话捕获 prompts

## 1. 目标

采用同级 `scratchpad` 项目前三个提交引入的 AI agent 工作环境约定，并使其适配 HelloWorldRemote。

该环境必须：

1. 通过 harness 特定的启动检查同时支持 Codex 和 Claude Code。
2. 要求重要工作遵循完整的 Superpowers 开发流程。
3. 建立含义等价的英文和简体中文文档。
4. 记录项目特定的安全、验证和平台对齐约束。
5. 避免将 agent 生成的 worktrees、Superpowers 状态、Python 环境和缓存纳入 Git。
6. 提供参考项目中的双语 conversation capture prompt。

本任务只配置 agent 工作环境，不修改 macOS 或 Windows workflows、scripts、运行时行为或现有技术决策。

## 2. 参考提交

本设计使用 `scratchpad` 的以下初始提交作为参考：

- `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`：增加 AI 项目模板，包括 `.claude/settings.json`、`.gitignore`、双语 `AGENTS`、双语 `CLAUDE` 和双语 `README` 文件。
- `24be21461f21fc57ff05cd4d74f650c19683d819`：替换 README 文件中的模板项目名。
- `21fd7b173587547384c8757c67c8a01459709b42`：增加双语 conversation capture prompt。

参考文件提供 policy 结构。通用模板内容会替换为 HelloWorldRemote 特定的名称、仓库用途、安全边界、文件布局和验证要求。

## 3. 仓库结构

迁移会增加或更新以下结构：

```text
HelloWorldRemote/
├── .claude/
│   └── settings.json
├── .gitignore
├── AGENTS.md
├── AGENTS-zh_CN.md
├── CLAUDE.md
├── CLAUDE-zh_CN.md
├── README.md
├── README-zh_CN.md
└── docs/
    ├── prompts/
    │   ├── capture-conversation.md
    │   └── capture-conversation-zh_CN.md
    └── superpowers/
        ├── plans/
        │   ├── 2026-08-10-uuremote-host-bootstrap.md
        │   └── 2026-08-10-uuremote-host-bootstrap-zh_CN.md
        └── specs/
            ├── 2026-08-10-uuremote-host-bootstrap-design.md
            └── 2026-08-10-uuremote-host-bootstrap-design-zh_CN.md
```

`AGENTS.md` 是 Codex 的英文指令源，`AGENTS-zh_CN.md` 是其含义等价的简体中文版本。`CLAUDE.md` 和 `CLAUDE-zh_CN.md` 对 Claude Code 承担相同角色。

`.claude/settings.json` 在项目级请求启用 `superpowers@claude-plugins-official`。其中不得包含个人路径、机器特定权限或无关设置。

`.gitignore` 包括 `.superpowers/`、`.worktrees/`、`.venv/`、`__pycache__/` 和 `*.pyc`。

## 4. Agent 开发工作流

Codex 与 Claude Code 指令共享以下要求。只有 harness 特定的插件名称、安装说明和命令可以不同。

### 4.1 启动检查

每个新会话开始时，agent 检查适用的 Superpowers 启动 skill 是否可用且可以调用。如果不可用，agent 不得声称 Superpowers 已启用，必须告知用户如何为相应 harness 安装或启用它，并且除非用户明确要求，不得仅为安装插件而修改仓库。

### 4.2 重要工作流程

对于重要工作，agents 必须：

1. 在设计新行为之前使用 `brainstorming`。
2. 在设计获批后、实现开始前使用 `using-git-worktrees`。
3. 在多步骤实现之前使用 `writing-plans`。
4. 使用 `subagent-driven-development` 执行获批计划；当更适合人工分批检查点时，使用 `executing-plans`。
5. 对行为变更和 bug 修复遵循 `test-driven-development`。
6. 对失败和意外行为使用 `systematic-debugging`。
7. 在任务之间和集成之前使用 `requesting-code-review`。
8. 在处理 review 反馈之前使用 `receiving-code-review`。
9. 在声称完成之前使用 `verification-before-completion`。
10. 在最新最终验证之后使用 `finishing-a-development-branch`。

Commit message 必须遵循 Conventional Commits，使用适当的 type，例如 `fix:`、`feat:`、`chore:`、`docs:`、`refactor:` 或 `test:`。

## 5. 项目特定的安全与平台规则

Agent 指令必须建立以下 HelloWorldRemote 特定约束：

- 将账户密码、UU 远程自定义连接码和远程设备连接信息视为敏感数据。
- 绝不在源码、测试夹具、默认值、日志、截图或 artifacts 中硬编码真实凭据。
- 通过步骤级环境变量传递 secrets，在可能记录命令执行前屏蔽它们，并尽快从环境中清除。
- 不启用 root 或 Administrator 直接登录；没有明确获批设计时，不得削弱 SSH、UAC、防火墙或操作系统权限控制。
- 使主机配置具备幂等性：修改前验证系统状态，修改后验证结果；当存在安全恢复信息时，按逆序回滚当前运行产生的变更。
- 保持 macOS 和 Windows 对外可见的 workflow contracts 对齐，同时允许平台特定的内部实现。
- 源代码、配置文件、scripts、tests 和代码示例中的注释使用英文。
- 当用户使用简体中文交流时使用简体中文回复；否则默认使用英文，除非用户要求其他语言。

## 6. 双语文档契约

仓库根目录及 `docs/` 递归目录下的每个 Markdown 文件都必须有含义等价的英文和简体中文版本。

规则如下：

1. 先编写或更新英文版本。
2. 在 basename 后、`.md` 前附加 `-zh_CN`，以此命名中文对应版本。
3. 将带后缀文件视为 counterpart 而非 source file；绝不创建 `README-zh_CN-zh_CN.md` 这类递归后缀名称。
4. 在 H1 标题后立即放置相对语言导航行，其前后各有且仅有一个空行。
5. 在同一次变更中更新全部 counterparts 和导航链接。
6. 不得在不同语言版本之间遗漏、增加、弱化或重新解释要求。
7. 当 inline code span 本身包含反引号时，使用符合 CommonMark 的更长反引号分隔符。

该契约适用于现有及未来所有 Superpowers plans 和 specifications。因此，迁移会为 `docs/superpowers/plans/` 与 `docs/superpowers/specs/` 下每个现有文档增加简体中文 counterpart，并在不改变技术含义的前提下为现有英文文件增加导航。

## 7. README 与 Conversation Capture

双语 README 文件成为仓库的人类入口。它们说明：

- 仓库用途；
- macOS 与 Windows workflow 入口；
- 必需的 GitHub Actions secrets；
- workflow inputs 与诊断等级；
- 配置可远程访问 runner 的安全影响；
- 源码与测试布局；以及
- 适用的本地和 hosted 验证路径。

双语 conversation capture prompt 从第三个参考提交复制，并保留其真实性、内容边界、metadata、文件名和输出要求。只允许进行确保语言导航有效或仓库放置正确所必需的修正。

## 8. 迁移过程

实现按以下顺序进行：

1. 增加共享忽略规则和 Claude Code 项目设置。
2. 增加并定制双语 Codex 与 Claude Code 指令文件。
3. 扩充英文 README，并增加含义等价的中文 counterpart。
4. 增加双语 conversation capture prompts。
5. 为每个现有英文 plan 和 specification 增加语言导航。
6. 将每个现有 plan 和 specification 翻译为 `-zh_CN.md` counterpart，且不改变其技术结论，但下述获授权的自定义连接码脱敏除外。
7. 验证完整的文档关系和配置。
8. 将环境配置作为一项完整变更提交。

翻译必须保留历史内容，但有一项由安全规则决定的脱敏例外：已知的 UU 远程明文自定义连接码在每份英文和中文文档中都精确表示为 `xxxxxx`。这项获授权的占位符替换优先于逐字节历史保留。不得在翻译过程中静默修正现有设计中的其他过时或可疑陈述；任何其他语义修正都需要单独明确划定范围的变更。

实现不会修改 `.github/workflows/*`、`.github/workflows/apple.sh`、Swift shutdown watcher 或现有运行时 tests。

## 9. 验证

完成之前验证：

- 根目录及 `docs/**` 下每个 Markdown 文件都有且只有一个命名正确的 counterpart；
- 所有语言导航链接都能解析到现有相对路径；
- 每份文档都具备要求的 H1、导航和空行结构；
- 不存在递归后缀的 `-zh_CN-zh_CN.md` 文件；
- `.claude/settings.json` 可以被解析为 JSON，且只启用预期的 Superpowers 插件；
- 自动检查只覆盖机器可读结构：JSON 合法性、必需 ignore entries、counterpart 存在性、准确的 navigation 格式和相对链接解析；
- Task review 确认 Codex 与 Claude Code 指令对包含完整的共享工作流和项目规则，README 文件准确陈述当前 workflow facts，并且 capture prompts 保留参考语义；
- 现有英文 plans 与 specifications 相较 base versions，除增加语言导航和将已知明文自定义连接码替换为获授权的 `xxxxxx` 外，没有其他差异；
- 当前可运行的仓库 tests 仍然通过；
- `git diff --check e30a65b..HEAD` 通过；并且
- 最终 diff 只包含获批的环境和文档变更。

如果缺少任何 counterpart、任何导航链接无效、任何配置无法解析，或共享指令 policy 不一致，则迁移尚未完成，不得将其作为完成状态提交。

禁止针对人类 prose 使用精确文字或 required-token assertions，因为它们是脆弱的 change detectors，而非行为 tests。Markdown、JSON 和 ignore-file 编写明确豁免严格的 test-first development。任何新增 Python 验证行为仍遵循 red-green-refactor，并针对真实仓库结构运行，而不是断言 prose 内容。

## 10. 非目标

本任务不：

- 实现 Windows/macOS 功能对齐；
- 改变 UU 远程安装、启动、权限、自定义连接码或等待行为；
- 引入个人 Codex 或 Claude 配置；
- 在用户机器上安装 plugins；
- 在翻译历史技术决策时重写它们，但获授权的 `xxxxxx` 安全脱敏除外；或
- 增加无关仓库工具。

该环境任务完成实现并验证后，工作将返回已经单独批准的功能对齐方案 B。
