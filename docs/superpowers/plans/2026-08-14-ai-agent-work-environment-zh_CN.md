# AI Agent 工作环境实施计划

[English](2026-08-14-ai-agent-work-environment.md) | [简体中文](2026-08-14-ai-agent-work-environment-zh_CN.md)

> **面向 agentic workers：** 必需的 sub-skill：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 使用 `scratchpad` 最初三个提交采用的完整双语 Codex 与 Claude Code agent 环境配置 HelloWorldRemote。

**架构：** 仓库 policy 通过成对的根目录指令文档、项目级 Claude 设置，以及成对的 README 和 prompt 文档表达。一个聚焦的 Python contract test 强制执行可机器检查的结构，同时在不改变英文技术内容的前提下迁移 8 份历史 Superpowers 文档。

**技术栈：** Markdown、JSON、Git、Python 3 `unittest`、PowerShell 验证命令

## 全局约束

- 使用 `scratchpad` 提交 `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`、`24be21461f21fc57ff05cd4d74f650c19683d819` 和 `21fd7b173587547384c8757c67c8a01459709b42` 作为 policy 参考。
- 仓库根目录及 `docs/` 递归目录下每个 Markdown 文件都必须有含义等价的英文与简体中文版本。
- 先编写或更新英文版本；在 basename 后附加 `-zh_CN` 作为中文 counterpart。
- 将 `[English](...) | [简体中文](...)` 紧接在每个 H1 后，其前后各有且仅有一个空行。
- 源码、配置、scripts、tests 和代码示例中的注释使用英文。
- 不修改 `.github/workflows/*`、`apple.sh`、Swift watcher 或现有运行时行为。
- 不硬编码或暴露账户密码、自定义连接码或远程设备连接信息。
- 对人工编写的仓库编辑使用 `apply_patch`；机械性的参考文件复制和格式化可以使用专用命令。
- 每个 implementation commit 使用 Conventional Commits。

---

### 任务 1：增加可机器检查的基础配置契约

**文件：**
- 新建：`.claude/settings.json`
- 新建：`.gitignore`
- 新建：`tests/test_agent_work_environment.py`

**接口：**
- 消费：`scratchpad` 提交 `a119e6d8a6834dc996f28f273dd01cd5f53c8c59` 中准确的插件标识符 `superpowers@claude-plugins-official`。
- 产出：`BaseConfigurationContractTests`，后续任务将在同一文件中增加其他 contract-test classes。

- [ ] **步骤 1：编写失败的基础配置 tests**

创建 `tests/test_agent_work_environment.py`：

```python
from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class BaseConfigurationContractTests(unittest.TestCase):
    def test_claude_settings_enable_only_superpowers(self):
        settings = json.loads(text(ROOT / ".claude/settings.json"))
        self.assertEqual(
            settings,
            {
                "enabledPlugins": {
                    "superpowers@claude-plugins-official": True,
                }
            },
        )

    def test_generated_agent_state_is_ignored(self):
        entries = set(text(ROOT / ".gitignore").splitlines())
        self.assertTrue(
            {
                ".superpowers/",
                ".worktrees/",
                ".venv/",
                "__pycache__/",
                "*.pyc",
            }.issubset(entries)
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **步骤 2：运行聚焦 tests 并确认预期失败**

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests -v
```

预期：因缺少 `.claude/settings.json` 和 `.gitignore` 产生两个 errors。

- [ ] **步骤 3：增加最小 settings 与 ignore 文件**

创建 `.claude/settings.json`：

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
```

创建 `.gitignore`：

```gitignore
.superpowers/
.worktrees/
.venv/
__pycache__/
*.pyc
```

- [ ] **步骤 4：运行聚焦 tests 并确认成功**

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests -v
```

预期：`Ran 2 tests` 和 `OK`。

- [ ] **步骤 5：提交基础配置**

```powershell
git add -- .claude/settings.json .gitignore tests/test_agent_work_environment.py
git commit -m "chore: add AI agent base configuration"
```

---

### 任务 2：增加双语 Codex 与 Claude Code 指令

**文件：**
- 新建：`AGENTS.md`
- 新建：`AGENTS-zh_CN.md`
- 新建：`CLAUDE.md`
- 新建：`CLAUDE-zh_CN.md`
- 修改：`tests/test_agent_work_environment.py`

**接口：**
- 消费：任务 1 的 `text()` 和 `ROOT`；`scratchpad` 提交 `a119e6d8a6834dc996f28f273dd01cd5f53c8c59` 中的 4 份指令模板；设计 spec 中已批准的安全规则。
- 产出：适用于仓库根目录的 Codex 与 Claude Code 指令，以及 `AgentInstructionContractTests`。

- [ ] **步骤 1：增加失败的指令契约 tests**

在 module 的 `if __name__ == "__main__"` block 前插入：

```python
class AgentInstructionContractTests(unittest.TestCase):
    FILES = (
        "AGENTS.md",
        "AGENTS-zh_CN.md",
        "CLAUDE.md",
        "CLAUDE-zh_CN.md",
    )

    def test_instruction_files_exist_with_language_navigation(self):
        for name in self.FILES:
            with self.subTest(name=name):
                lines = text(ROOT / name).splitlines()
                self.assertTrue(lines[0].startswith("# "))
                self.assertEqual(lines[1], "")
                self.assertEqual(
                    lines[2],
                    (
                        "[English](AGENTS.md) | [简体中文](AGENTS-zh_CN.md)"
                        if name.startswith("AGENTS")
                        else "[English](CLAUDE.md) | [简体中文](CLAUDE-zh_CN.md)"
                    ),
                )
                self.assertEqual(lines[3], "")

    def test_all_instruction_files_define_the_shared_workflow(self):
        required_tokens = (
            "brainstorming",
            "using-git-worktrees",
            "writing-plans",
            "subagent-driven-development",
            "executing-plans",
            "test-driven-development",
            "systematic-debugging",
            "requesting-code-review",
            "receiving-code-review",
            "verification-before-completion",
            "finishing-a-development-branch",
            "Conventional Commits",
            "UUREMOTE_ACCOUNT_PASSWORD",
            "UUREMOTE_CUSTOM_CODE",
        )
        for name in self.FILES:
            content = text(ROOT / name)
            for token in required_tokens:
                with self.subTest(name=name, token=token):
                    self.assertIn(token, content)

    def test_harness_specific_startup_instructions_are_present(self):
        self.assertIn("Open `/plugins`", text(ROOT / "AGENTS.md"))
        self.assertIn(
            "superpowers@claude-plugins-official",
            text(ROOT / "CLAUDE.md"),
        )
```

- [ ] **步骤 2：运行聚焦 class 并确认预期失败**

```powershell
python -m unittest tests.test_agent_work_environment.AgentInstructionContractTests -v
```

预期：因 4 份指令文件均不存在而产生 errors。

- [ ] **步骤 3：编写英文 Codex 指令文件**

从参考提交中的 `AGENTS.md` 开始，保留 startup check、完整 Superpowers workflow、沟通规则、文档规则、英文注释规则和跨 harness 等价规则。增加 `## Project safety and validation`，包含设计第 5 节与第 9 节的全部要求，以及准确的 secret names `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE`。

最终 heading 顺序为：

```markdown
# Project instructions
## Startup check
## Project scope
## Development workflow
## Project safety and validation
## Language and documentation rules
```

`Project scope` 按职责说明 `.github/workflows/macos.yml`、`.github/workflows/windows.yml`、`.github/workflows/apple.sh`、`.github/workflows/uuremote-shutdown-wait.swift`、`tests/` 和 `docs/superpowers/`。

- [ ] **步骤 4：创建含义等价的中文 Codex counterpart**

根据完成后的英文文件创建 `AGENTS-zh_CN.md`。Paths、secret names、commands 和 skill identifiers 保持不变。两份 Codex 文件都使用：

```markdown
[English](AGENTS.md) | [简体中文](AGENTS-zh_CN.md)
```

- [ ] **步骤 5：编写两份 Claude Code 指令文件**

以参考提交中的 `CLAUDE.md` 和 `CLAUDE-zh_CN.md` 为起点。使用与 Codex 文件含义等价的 `Project scope` 和 `Project safety and validation` 内容。保留 Claude 特定的 `superpowers:using-superpowers`、`/plugin install superpowers@claude-plugins-official` 和 `/reload-plugins` 检查。

两份 Claude 文件都使用：

```markdown
[English](CLAUDE.md) | [简体中文](CLAUDE-zh_CN.md)
```

- [ ] **步骤 6：运行指令与基础契约**

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests tests.test_agent_work_environment.AgentInstructionContractTests -v
```

预期：`Ran 5 tests` 和 `OK`。

- [ ] **步骤 7：审查跨 harness 等价性并提交**

逐节比较英文 pair 与中文 pair。仅允许 harness 特定的 plugin naming、安装、reload 和 startup instructions 不同。

```powershell
git add -- AGENTS.md AGENTS-zh_CN.md CLAUDE.md CLAUDE-zh_CN.md tests/test_agent_work_environment.py
git commit -m "docs: add bilingual agent instructions"
```

---

### 任务 3：增加双语项目入口和捕获 prompt

**文件：**
- 修改：`README.md`
- 新建：`README-zh_CN.md`
- 新建：`docs/prompts/capture-conversation.md`
- 新建：`docs/prompts/capture-conversation-zh_CN.md`
- 修改：`tests/test_agent_work_environment.py`

**接口：**
- 消费：`.github/workflows/macos.yml` 与 `.github/workflows/windows.yml` 的当前事实；`scratchpad` 提交 `21fd7b173587547384c8757c67c8a01459709b42` 中的 capture prompts。
- 产出：面向人的双语仓库文档和 `EntryPointContractTests`。

- [ ] **步骤 1：增加失败的入口 tests**

在 module entry point 前插入：

```python
class EntryPointContractTests(unittest.TestCase):
    def test_readmes_have_navigation_and_required_facts(self):
        for name in ("README.md", "README-zh_CN.md"):
            content = text(ROOT / name)
            lines = content.splitlines()
            self.assertEqual(lines[1], "")
            self.assertEqual(
                lines[2],
                "[English](README.md) | [简体中文](README-zh_CN.md)",
            )
            for token in (
                "macos.yml",
                "windows.yml",
                "UUREMOTE_ACCOUNT_PASSWORD",
                "UUREMOTE_CUSTOM_CODE",
                "debug_level",
                "wait_connections_seconds",
            ):
                with self.subTest(name=name, token=token):
                    self.assertIn(token, content)

    def test_capture_prompts_preserve_required_sections(self):
        files = (
            ROOT / "docs/prompts/capture-conversation.md",
            ROOT / "docs/prompts/capture-conversation-zh_CN.md",
        )
        for path in files:
            content = text(path)
            for token in (
                "## Conversation",
                "Capture note:",
                "docs/conversations/",
                "YYYY-MM-DD-brief-english-slug",
            ):
                with self.subTest(path=path.name, token=token):
                    self.assertIn(token, content)
```

- [ ] **步骤 2：运行入口 tests 并确认失败**

```powershell
python -m unittest tests.test_agent_work_environment.EntryPointContractTests -v
```

预期：README contract 失败，并且两份 prompt 文件缺失。

- [ ] **步骤 3：扩充英文 README**

将只有标题的 README 替换为以下 sections：

```markdown
# HelloWorldRemote
## Purpose
## Workflows
## Required secrets
## Inputs and diagnostics
## Security notice
## Repository layout
## Validation
```

说明 macOS 当前使用两个必需 secrets、`0` 至 `3` 的 debug levels，以及 `0` 至 `21000` 的 `wait_connections_seconds` 范围。准确说明 Windows workflow 当前较不完整且已计划进行功能对齐；不得声称它已经消费这些 secrets 或 inputs。

- [ ] **步骤 4：创建中文 README counterpart**

将完成后的英文 README 翻译为 `README-zh_CN.md`，不改变 paths、identifiers、ranges 或安全要求。使用 contract test 要求的准确共享 navigation line。

- [ ] **步骤 5：增加参考 capture prompts**

从提交 `21fd7b173587547384c8757c67c8a01459709b42` 创建两份 prompt 文件，不进行总结或缩写。保留全部 9 个编号 sections、YAML metadata schema、真实性规则、filename rules 和 output requirements。Navigation links 保持为 `docs/prompts/` 两个文件之间的相对链接。

- [ ] **步骤 6：运行入口契约**

```powershell
python -m unittest tests.test_agent_work_environment.EntryPointContractTests -v
```

预期：`Ran 2 tests` 和 `OK`。

- [ ] **步骤 7：提交入口文档**

```powershell
git add -- README.md README-zh_CN.md docs/prompts/capture-conversation.md docs/prompts/capture-conversation-zh_CN.md tests/test_agent_work_environment.py
git commit -m "docs: add bilingual project entry points"
```

---

### 任务 4：将历史 Superpowers 文档迁移到双语契约

**文件：**
- 修改并翻译以下 4 组 plan pairs：
  - `docs/superpowers/plans/2026-08-10-uuremote-host-bootstrap.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-host-bootstrap-zh_CN.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-three-permissions.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-three-permissions-zh_CN.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-zh_CN.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-secrets-and-shutdown-aware-wait.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-zh_CN.md`
- 修改并翻译以下 4 组 historical spec pairs：
  - `docs/superpowers/specs/2026-08-10-uuremote-host-bootstrap-design.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-host-bootstrap-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-three-permissions-design.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-three-permissions-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design-zh_CN.md`
- 修改：`tests/test_agent_work_environment.py`

**接口：**
- 消费：base commit `e30a65b` 中的 8 份历史英文文档；已经成对的环境设计与实施计划。
- 产出：由 `BilingualDocumentationContractTests` 强制执行的完整双语 Markdown 关系。

- [ ] **步骤 1：增加失败的仓库级双语契约**

在 module entry point 前插入：

```python
class BilingualDocumentationContractTests(unittest.TestCase):
    def markdown_files(self) -> list[Path]:
        return sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").rglob("*.md"))

    def counterparts(self, path: Path) -> tuple[Path, Path]:
        if path.stem.endswith("-zh_CN"):
            english = path.with_name(path.stem.removesuffix("-zh_CN") + ".md")
            return english, path
        return path, path.with_name(path.stem + "-zh_CN.md")

    def test_every_markdown_file_has_exactly_one_counterpart(self):
        for path in self.markdown_files():
            english, chinese = self.counterparts(path)
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                self.assertTrue(english.is_file())
                self.assertTrue(chinese.is_file())
                self.assertNotIn("-zh_CN-zh_CN", path.name)

    def test_every_markdown_file_has_exact_navigation(self):
        checked: set[Path] = set()
        for path in self.markdown_files():
            english, chinese = self.counterparts(path)
            if english in checked:
                continue
            checked.add(english)
            expected = (
                f"[English]({english.name}) | "
                f"[简体中文]({chinese.name})"
            )
            for version in (english, chinese):
                lines = text(version).splitlines()
                with self.subTest(path=version.relative_to(ROOT).as_posix()):
                    self.assertTrue(lines[0].startswith("# "))
                    self.assertEqual(lines[1], "")
                    self.assertEqual(lines[2], expected)
                    self.assertEqual(lines[3], "")
```

- [ ] **步骤 2：运行双语契约并确认失败**

```powershell
python -m unittest tests.test_agent_work_environment.BilingualDocumentationContractTests -v
```

预期：failures 指出缺少中文 counterparts 或 navigation lines 的 8 份历史英文文档。

- [ ] **步骤 3：增加 navigation 且不改变历史英文正文**

对本任务文件清单中的每个英文文件，保留现有 H1 为第 1 行，将原有空白第 2 行替换为一个空行、准确的 pair-specific navigation line 和另一个空行，然后从原第 3 行开始保留现有内容。不得更正 spelling、dates、encoded UI strings、commands 或已被后续取代的设计选择。

Host-bootstrap design 的变换示例：

```markdown
# UU Remote macOS Host Bootstrap Design

[English](2026-08-10-uuremote-host-bootstrap-design.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-design-zh_CN.md)

**Date:** 2026-08-10
```

- [ ] **步骤 4：翻译 4 份 plan 文件**

创建本任务文件清单中的 4 份 `-zh_CN.md` plan counterparts。翻译 headings、prose、expected test descriptions 与 explanatory comments。Code、paths、commands、identifiers、hashes、secret names、regular expressions 和 quoted UI strings 保持不变，除非原文自己提供了中文 UI counterpart。

- [ ] **步骤 5：翻译 4 份 historical spec 文件**

使用相同保留规则创建本任务文件清单中的 4 份 `-zh_CN.md` spec counterparts。Section numbering、tables、ordered steps、non-goals 与 reference links 同英文一一对齐。

- [ ] **步骤 6：运行完整 agent-environment contract suite**

```powershell
python -m unittest tests.test_agent_work_environment -v
```

预期：所有基础、指令、入口和双语文档 tests 通过。

- [ ] **步骤 7：验证历史英文内容保留**

对 8 个 historical English paths，使用 `git show`、commit `e30a65b` 和本任务列出的准确路径取得 base version。将 working-version 的第 2 至 4 行替换为一个空行；所得 UTF-8 文本必须与 base-commit file 相等，不得存在语义或格式修改。

```powershell
git diff e30a65b -- docs/superpowers/plans docs/superpowers/specs
```

预期：每份历史英文文件仅在 H1 后增加一个空行、navigation line 和一个空行；新增中文文件是忠实翻译。

- [ ] **步骤 8：提交历史文档迁移**

```powershell
git add -- docs/superpowers/plans docs/superpowers/specs tests/test_agent_work_environment.py
git commit -m "docs: add bilingual Superpowers history"
```

---

### 任务 5：执行最终环境验证

**文件：**
- 验证：任务 1 至 4 增加或修改的全部文件

**接口：**
- 消费：4 个 contract-test classes 和全部成对文档。
- 产出：经过最新验证、可进行 branch integration 的 AI agent 工作环境。

- [ ] **步骤 1：运行聚焦的跨平台 contract suite**

```powershell
python -m unittest tests.test_agent_work_environment -v
```

预期：所有 tests 以 `OK` 通过。

- [ ] **步骤 2：独立解析 Claude settings**

```powershell
Get-Content -Raw -LiteralPath '.claude\settings.json' | ConvertFrom-Json | Out-Null
```

预期：exit code 0 且无输出。

- [ ] **步骤 3：检查 whitespace 与非预期 runtime changes**

```powershell
git diff --check
git diff e30a65b --name-only
```

预期：`git diff --check` exit 0。Name list 只包含 `.claude/settings.json`、`.gitignore`、6 份根目录 Markdown 指令/README 文件、`docs/prompts/*`、成对的 `docs/superpowers/*` 文档，以及 `tests/test_agent_work_environment.py`；不包含 `.github/workflows/*` path。

- [ ] **步骤 4：审查 secrets 和递归后缀 filenames**

```powershell
rg -n 'johnDOE123|UUREMOTE_ACCOUNT_PASSWORD\s*[:=]\s*[^$]|UUREMOTE_CUSTOM_CODE\s*[:=]\s*[^$]' --glob '!docs/superpowers/**' .
Get-ChildItem -Recurse -File -Filter '*-zh_CN-zh_CN.md'
```

预期：没有新增 plaintext secret value，没有新增 secret assignment，也没有递归后缀 Markdown 文件。本任务范围外的现有 runtime debt 必须报告，不得静默修改。

- [ ] **步骤 5：检查 commits 与 worktree state**

```powershell
git log --oneline e30a65b..HEAD
git status --short
```

预期：`e30a65b` 之后有本计划 commit 和 4 个聚焦 implementation commits，worktree clean。

- [ ] **步骤 6：请求最终 code review 并完成 branch**

调用 `superpowers:requesting-code-review`。解决全部 Critical 和 Important findings，重新运行步骤 1 至 5，然后调用 `superpowers:verification-before-completion` 和 `superpowers:finishing-a-development-branch`。
