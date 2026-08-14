# AI Agent 工作环境实施计划

[English](2026-08-14-ai-agent-work-environment.md) | [简体中文](2026-08-14-ai-agent-work-environment-zh_CN.md)

> **面向 agentic workers：** 必需的 sub-skill：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 使用 `scratchpad` 最初三个提交采用的完整双语 Codex 与 Claude Code agent 环境配置 HelloWorldRemote。

**架构：** 仓库 policy 通过成对的根目录指令文档、项目级 Claude 设置，以及成对的 README 和 prompt 文档表达。一个聚焦的 Python contract test 强制执行可机器检查的结构，同时保留 8 份历史 Superpowers 文档的英文技术内容，但获授权的 `xxxxxx` 安全脱敏除外。

**技术栈：** Markdown、JSON、Git、Python 3 `unittest`、PowerShell 验证命令

## 全局约束

- 使用 `scratchpad` 提交 `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`、`24be21461f21fc57ff05cd4d74f650c19683d819` 和 `21fd7b173587547384c8757c67c8a01459709b42` 作为 policy 参考。
- 仓库根目录及 `docs/` 递归目录下每个 Markdown 文件都必须有含义等价的英文与简体中文版本。
- 先编写或更新英文版本；在 basename 后附加 `-zh_CN` 作为中文 counterpart。
- 将 `[English](...) | [简体中文](...)` 紧接在每个 H1 后，其前后各有且仅有一个空行。
- 源码、配置、scripts、tests 和代码示例中的注释使用英文。
- 不修改 `.github/workflows/*`、`apple.sh`、Swift watcher 或现有运行时行为。
- 不硬编码或暴露账户密码、自定义连接码或远程设备连接信息。安全规则优先于历史保真：在每份英文和中文文档中，将已知明文自定义连接码精确表示为 `xxxxxx`。
- 自动 tests 可以断言机器可读结构，但不得断言人类 prose 中的 required words 或 tokens；语义完整性与翻译等价性由 task review 负责。
- Markdown、JSON 和 ignore-file 编写豁免严格 test-first development；新增 Python 验证行为仍要求 red-green-refactor。
- 对人工编写的仓库编辑使用 `apply_patch`；机械性的参考文件复制和格式化可以使用专用命令。
- 每个 implementation commit 使用 Conventional Commits。

---

### 任务 1：增加可机器检查的基础配置契约

**文件：**
- 新建：`.claude/settings.json`
- 修改：`.gitignore`
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

预期：因缺少 `.claude/settings.json` 产生一个 error，并且因为 `.gitignore` 只有 worktree 安全 entry 而产生一个 failure。

- [ ] **步骤 3：增加最小 settings 与 ignore 文件**

创建 `.claude/settings.json`：

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
```

扩充现有 `.gitignore`，保留 `.worktrees/` 并加入其余 entries，使完整文件为：

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

预期：`Ran 3 tests` 和 `OK`。

- [ ] **步骤 7：审查跨 harness 等价性并提交**

逐节比较英文 pair 与中文 pair。手动确认设计中的每个 workflow skill、secret-handling rule、项目安全边界、验证要求和文档规则都存在。仅允许 harness 特定的 plugin naming、安装、reload 和 startup instructions 不同。

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
    def test_readmes_have_navigation(self):
        for name in ("README.md", "README-zh_CN.md"):
            lines = text(ROOT / name).splitlines()
            self.assertEqual(lines[1], "")
            self.assertEqual(
                lines[2],
                "[English](README.md) | [简体中文](README-zh_CN.md)",
            )

    def test_capture_prompts_have_navigation(self):
        for name in (
            "capture-conversation.md",
            "capture-conversation-zh_CN.md",
        ):
            lines = text(ROOT / "docs/prompts" / name).splitlines()
            self.assertEqual(lines[1], "")
            self.assertEqual(
                lines[2],
                (
                    "[English](capture-conversation.md) | "
                    "[简体中文](capture-conversation-zh_CN.md)"
                ),
            )
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

提交前，根据当前 workflow YAML 审查两份 README，并根据 `scratchpad` 提交 `21fd7b173587547384c8757c67c8a01459709b42` 审查两份 capture prompts。该语义 review 取代脆弱的 required-token tests。

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
- 消费：base commit `e30a65b` 中的 8 份历史英文文档；已经成对的环境设计与实施计划；获授权的 `xxxxxx` 自定义连接码脱敏例外。
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

- [ ] **步骤 3：增加 navigation 并应用获授权的安全脱敏**

对本任务文件清单中的每个英文文件，保留现有 H1 为第 1 行，将原有空白第 2 行替换为一个空行、准确的 pair-specific navigation line 和另一个空行，然后从原第 3 行开始保留现有内容。唯一获授权的历史正文变更是将已知明文自定义连接码的每次出现都精确替换为 `xxxxxx`。不得更正 spelling、dates、encoded UI strings、commands 或已被后续取代的设计选择。

Host-bootstrap design 的变换示例：

```markdown
# UU Remote macOS Host Bootstrap Design

[English](2026-08-10-uuremote-host-bootstrap-design.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-design-zh_CN.md)

**Date:** 2026-08-10
```

- [ ] **步骤 4：翻译 4 份 plan 文件**

创建本任务文件清单中的 4 份 `-zh_CN.md` plan counterparts。翻译 headings、prose、expected test descriptions 与 explanatory comments。Code、paths、commands、identifiers、hashes、secret names、regular expressions 和 quoted UI strings 保持不变，除非原文自己提供了中文 UI counterpart。在中文 counterparts 中同样应用获授权的替换，将已知明文自定义连接码精确替换为 `xxxxxx`。

- [ ] **步骤 5：翻译 4 份 historical spec 文件**

使用相同的保留与安全脱敏规则创建本任务文件清单中的 4 份 `-zh_CN.md` spec counterparts。Section numbering、tables、ordered steps、non-goals 与 reference links 同英文一一对齐。

- [ ] **步骤 6：运行完整 agent-environment contract suite**

```powershell
python -m unittest tests.test_agent_work_environment -v
```

预期：所有基础、指令、入口和双语文档 tests 通过。

- [ ] **步骤 7：验证历史英文内容保留**

对 8 个 historical English paths，使用 `git show`、commit `e30a65b` 和本任务列出的准确路径取得 base version。将 working-version 的第 2 至 4 行替换为一个空行。仅对于已知的历史自定义连接码位置，在内存中将 working `xxxxxx` 占位符与从 `git show` 读取的对应 base token 比较；绝不得将该 base token 硬编码或写入 tracked documentation。计入这项获授权的脱敏后，所得 UTF-8 文本必须与 base-commit file 相等，不得存在其他语义或格式修改。

```powershell
git diff e30a65b -- docs/superpowers/plans docs/superpowers/specs
```

预期：每份历史英文文件仅在 H1 后增加一个空行、navigation line 和一个空行，并在已知自定义连接码位置应用获授权的 `xxxxxx` 替换；新增中文文件是在相同脱敏条件下的忠实翻译。

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
git diff --check e30a65b..HEAD
git diff e30a65b --name-only
```

预期：`git diff --check e30a65b..HEAD` exit 0。Name list 只包含 `.claude/settings.json`、`.gitignore`、6 份根目录 Markdown 指令/README 文件、`docs/prompts/*`、成对的 `docs/superpowers/*` 文档，以及 `tests/test_agent_work_environment.py`；不包含 `.github/workflows/*` path。

- [ ] **步骤 4：审查 secrets 和递归后缀 filenames**

```powershell
rg --pcre2 -n '(?<![\w${])UUREMOTE_(ACCOUNT_PASSWORD|CUSTOM_CODE)\s*[:=]\h*+(?!\$)' --glob '!docs/superpowers/**' .
Get-ChildItem -Recurse -File -Filter '*-zh_CN-zh_CN.md'
```

预期：没有新增 plaintext secret value，没有新增 secret assignment，也没有递归后缀 Markdown 文件。本任务范围外的现有 runtime debt 必须报告，不得静默修改。

- [ ] **步骤 5：检查 commits 与 worktree state**

```powershell
git log --oneline 64d91d5..HEAD
git status --short
```

预期：`64d91d5` 之后恰好有 6 个 commits：1 个已批准的 plan-correction commit、4 个聚焦 implementation commits 和 1 个已批准的 security-redaction commit；worktree clean。

- [ ] **步骤 6：请求最终 code review 并完成 branch**

调用 `superpowers:requesting-code-review`。解决全部 Critical 和 Important findings，重新运行步骤 1 至 5，然后调用 `superpowers:verification-before-completion` 和 `superpowers:finishing-a-development-branch`。
