# AI Agent Work Environment Implementation Plan

[English](2026-08-14-ai-agent-work-environment.md) | [简体中文](2026-08-14-ai-agent-work-environment-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure HelloWorldRemote with the complete bilingual Codex and Claude Code agent environment adopted from the first three `scratchpad` commits.

**Architecture:** Repository policy is expressed through paired root instruction documents, project-level Claude settings, and paired README and prompt documents. A focused Python contract test enforces machine-checkable structure, while the eight historical Superpowers documents retain their English technical content except for the authorized `xxxxxx` security redaction.

**Tech Stack:** Markdown, JSON, Git, Python 3 `unittest`, PowerShell validation commands

## Global Constraints

- Use `scratchpad` commits `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`, `24be21461f21fc57ff05cd4d74f650c19683d819`, and `21fd7b173587547384c8757c67c8a01459709b42` as the policy references.
- Every Markdown file in the repository root and under `docs/` recursively must have meaning-equivalent English and Simplified Chinese versions.
- Write or update English first; append `-zh_CN` to the basename for the Chinese counterpart.
- Put `[English](...) | [简体中文](...)` immediately after each H1 with exactly one blank line before and after it.
- Keep comments in source, configuration, scripts, tests, and code examples in English.
- Do not change `.github/workflows/*`, `apple.sh`, the Swift watcher, or existing runtime behavior.
- Do not hard-code or expose account passwords, custom codes, or remote-device connection information. Security takes precedence over historical fidelity: represent the known plaintext custom code as exactly `xxxxxx` in every English and Chinese document.
- Automated tests may assert machine-readable structure but must not assert required words or tokens in human prose; semantic completeness and translation equivalence are task-review responsibilities.
- Markdown, JSON, and ignore-file authoring is exempt from strict test-first development; new Python validation behavior still requires red-green-refactor.
- Use `apply_patch` for authored repository edits; mechanical reference-file copying and formatting may use purpose-built commands.
- Use Conventional Commits for every implementation commit.

---

### Task 1: Add the machine-checkable base configuration contract

**Files:**
- Create: `.claude/settings.json`
- Modify: `.gitignore`
- Create: `tests/test_agent_work_environment.py`

**Interfaces:**
- Consumes: The exact plugin identifier `superpowers@claude-plugins-official` from `scratchpad` commit `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`.
- Produces: `BaseConfigurationContractTests`, which later tasks extend with additional contract-test classes.

- [ ] **Step 1: Write the failing base-configuration tests**

Create `tests/test_agent_work_environment.py` with imports, `ROOT`, a UTF-8 `text()` helper, and this test class:

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

- [ ] **Step 2: Run the focused tests and verify the expected failure**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests -v
```

Expected: one error caused by missing `.claude/settings.json` and one failure because `.gitignore` contains only the worktree safety entry.

- [ ] **Step 3: Add the minimal settings and ignore files**

Create `.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
```

Extend the existing `.gitignore`, retaining `.worktrees/` and adding the remaining entries so the complete file is:

```gitignore
.superpowers/
.worktrees/
.venv/
__pycache__/
*.pyc
```

- [ ] **Step 4: Run the focused tests and verify success**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests -v
```

Expected: `Ran 2 tests` and `OK`.

- [ ] **Step 5: Commit the base configuration**

```powershell
git add -- .claude/settings.json .gitignore tests/test_agent_work_environment.py
git commit -m "chore: add AI agent base configuration"
```

---

### Task 2: Add bilingual Codex and Claude Code instructions

**Files:**
- Create: `AGENTS.md`
- Create: `AGENTS-zh_CN.md`
- Create: `CLAUDE.md`
- Create: `CLAUDE-zh_CN.md`
- Modify: `tests/test_agent_work_environment.py`

**Interfaces:**
- Consumes: `text()` and `ROOT` from Task 1; the four instruction templates from `scratchpad` commit `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`; the approved safety rules in the design spec.
- Produces: Root-scoped instructions for Codex and Claude Code plus `AgentInstructionContractTests`.

- [ ] **Step 1: Add failing instruction-contract tests**

Insert this class before the module's `if __name__ == "__main__"` block:

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

- [ ] **Step 2: Run the focused class and verify the expected failure**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.AgentInstructionContractTests -v
```

Expected: errors caused by all four instruction files being absent.

- [ ] **Step 3: Author the English Codex instruction file**

Start from `AGENTS.md` in reference commit `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`. Preserve its startup check, full Superpowers workflow, communication rules, documentation rules, English-comment rule, and cross-harness equivalence rule. Add a `## Project safety and validation` section containing all requirements from design sections 5 and 9, including the exact secret names `UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE`.

The final heading order must be:

```markdown
# Project instructions
## Startup check
## Project scope
## Development workflow
## Project safety and validation
## Language and documentation rules
```

In `Project scope`, identify `.github/workflows/macos.yml`, `.github/workflows/windows.yml`, `.github/workflows/apple.sh`, `.github/workflows/uuremote-shutdown-wait.swift`, `tests/`, and `docs/superpowers/` by responsibility.

- [ ] **Step 4: Create the meaning-equivalent Chinese Codex counterpart**

Create `AGENTS-zh_CN.md` from the completed English file. Keep paths, secret names, command names, and skill identifiers unchanged. Use this exact navigation line in both Codex files:

```markdown
[English](AGENTS.md) | [简体中文](AGENTS-zh_CN.md)
```

- [ ] **Step 5: Author both Claude Code instruction files**

Create `CLAUDE.md` and `CLAUDE-zh_CN.md` from their files in reference commit `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`. Apply the same `Project scope` and `Project safety and validation` content as the Codex pair. Preserve the Claude-specific checks for `superpowers:using-superpowers`, `/plugin install superpowers@claude-plugins-official`, and `/reload-plugins`.

Use this exact navigation line in both Claude files:

```markdown
[English](CLAUDE.md) | [简体中文](CLAUDE-zh_CN.md)
```

- [ ] **Step 6: Run the instruction and base contracts**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.BaseConfigurationContractTests tests.test_agent_work_environment.AgentInstructionContractTests -v
```

Expected: `Ran 3 tests` and `OK`.

- [ ] **Step 7: Review cross-harness equivalence and commit**

Compare the English pair and Chinese pair section by section. Confirm manually that every workflow skill, secret-handling rule, project safety boundary, validation requirement, and documentation rule from the design is present. The only policy differences allowed are harness-specific plugin naming, installation, reload, and startup instructions.

```powershell
git add -- AGENTS.md AGENTS-zh_CN.md CLAUDE.md CLAUDE-zh_CN.md tests/test_agent_work_environment.py
git commit -m "docs: add bilingual agent instructions"
```

---

### Task 3: Add the bilingual project entry point and capture prompt

**Files:**
- Modify: `README.md`
- Create: `README-zh_CN.md`
- Create: `docs/prompts/capture-conversation.md`
- Create: `docs/prompts/capture-conversation-zh_CN.md`
- Modify: `tests/test_agent_work_environment.py`

**Interfaces:**
- Consumes: Current workflow facts from `.github/workflows/macos.yml` and `.github/workflows/windows.yml`; capture prompts from `scratchpad` commit `21fd7b173587547384c8757c67c8a01459709b42`.
- Produces: Human-facing bilingual repository documentation and `EntryPointContractTests`.

- [ ] **Step 1: Add failing entry-point tests**

Insert this class before the module entry point:

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

- [ ] **Step 2: Run the entry-point tests and verify failure**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.EntryPointContractTests -v
```

Expected: the README contract fails and both prompt files are missing.

- [ ] **Step 3: Expand the English README**

Replace the title-only README with these sections and facts:

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

State that macOS currently uses both required secrets, debug levels `0` through `3`, and a `wait_connections_seconds` range of `0` through `21000`. State accurately that the current Windows workflow is less complete and is scheduled for functional parity; do not claim that it already consumes the secrets or inputs.

- [ ] **Step 4: Create the Chinese README counterpart**

Translate the completed English README into `README-zh_CN.md` without changing paths, identifiers, ranges, or security requirements. Use the exact shared navigation line required by the contract test.

- [ ] **Step 5: Add the reference capture prompts**

Create both prompt files from commit `21fd7b173587547384c8757c67c8a01459709b42` without summarizing or shortening them. Preserve all nine numbered sections, YAML metadata schema, authenticity rules, filename rules, and output requirements. Their navigation links must remain relative to the two files in `docs/prompts/`.

- [ ] **Step 6: Run the entry-point contracts**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.EntryPointContractTests -v
```

Expected: `Ran 2 tests` and `OK`.

- [ ] **Step 7: Commit the entry-point documentation**

Before committing, review both README files against the current workflow YAML and review both capture prompts against `scratchpad` commit `21fd7b173587547384c8757c67c8a01459709b42`. This semantic review replaces brittle required-token tests.

```powershell
git add -- README.md README-zh_CN.md docs/prompts/capture-conversation.md docs/prompts/capture-conversation-zh_CN.md tests/test_agent_work_environment.py
git commit -m "docs: add bilingual project entry points"
```

---

### Task 4: Migrate historical Superpowers documents to the bilingual contract

**Files:**
- Modify and translate these four plan pairs:
  - `docs/superpowers/plans/2026-08-10-uuremote-host-bootstrap.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-host-bootstrap-zh_CN.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-three-permissions.md`
  - `docs/superpowers/plans/2026-08-10-uuremote-three-permissions-zh_CN.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-zh_CN.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-secrets-and-shutdown-aware-wait.md`
  - `docs/superpowers/plans/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-zh_CN.md`
- Modify and translate these four historical spec pairs:
  - `docs/superpowers/specs/2026-08-10-uuremote-host-bootstrap-design.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-host-bootstrap-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-three-permissions-design.md`
  - `docs/superpowers/specs/2026-08-10-uuremote-three-permissions-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design-zh_CN.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design.md`
  - `docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design-zh_CN.md`
- Modify: `tests/test_agent_work_environment.py`

**Interfaces:**
- Consumes: The eight historical English documents at base commit `e30a65b`; the already-paired environment design and implementation plan; the authorized `xxxxxx` custom-code redaction exception.
- Produces: A complete bilingual Markdown graph enforced by `BilingualDocumentationContractTests`.

- [ ] **Step 1: Add the failing repository-wide bilingual contract**

Insert this class before the module entry point:

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

- [ ] **Step 2: Run the bilingual contract and verify failure**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.BilingualDocumentationContractTests -v
```

Expected: failures identify the eight historical English documents whose Chinese counterparts or navigation lines are absent.

- [ ] **Step 3: Add navigation and apply the authorized security redaction**

For each of the eight English files listed under `Files`, keep the existing H1 as line 1, replace the original blank line 2 with a blank line, the exact pair-specific navigation line, and another blank line, then keep the original content beginning at its previous line 3. The only authorized historical-body change is to replace every occurrence of the known plaintext custom code with exactly `xxxxxx`. Do not correct spelling, dates, encoded UI strings, commands, or superseded design choices.

Example for the host-bootstrap design:

```markdown
# UU Remote macOS Host Bootstrap Design

[English](2026-08-10-uuremote-host-bootstrap-design.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-design-zh_CN.md)

**Date:** 2026-08-10
```

- [ ] **Step 4: Translate the four plan files**

Create the four `-zh_CN.md` plan counterparts listed under `Files`. Translate headings, prose, expected test descriptions, and explanatory comments. Preserve code, paths, command lines, identifiers, hashes, secret names, regular expressions, and quoted UI strings exactly unless the original document itself supplies a Chinese UI equivalent. Apply the same authorized replacement of the known plaintext custom code with exactly `xxxxxx` in the Chinese counterparts.

- [ ] **Step 5: Translate the four historical spec files**

Create the four `-zh_CN.md` spec counterparts listed under `Files` using the same preservation and security-redaction rules. Keep section numbering, tables, ordered steps, non-goals, and reference links aligned one-to-one with English.

- [ ] **Step 6: Run the entire agent-environment contract suite**

Run:

```powershell
python -m unittest tests.test_agent_work_environment -v
```

Expected: all base, instruction, entry-point, and bilingual documentation tests pass.

- [ ] **Step 7: Verify historical English content preservation**

For each of the eight historical English paths, use `git show` with commit `e30a65b` and the exact path listed in this task to obtain the base version. Replace working-version lines 2 through 4 with one blank line. For the known historical custom-code positions only, compare the working `xxxxxx` placeholder with the corresponding base token read from `git show` in memory; never hard-code or write that base token into tracked documentation. After accounting for this authorized redaction, the resulting UTF-8 text must equal the base-commit file with no other semantic or formatting changes.

Review the resulting diff:

```powershell
git diff e30a65b -- docs/superpowers/plans docs/superpowers/specs
```

Expected: each historical English file adds only one blank line, the navigation line, and one blank line after its H1, plus the authorized `xxxxxx` substitutions at the known custom-code positions; new Chinese files contain faithful translations with the same redaction.

- [ ] **Step 8: Commit the historical documentation migration**

```powershell
git add -- docs/superpowers/plans docs/superpowers/specs tests/test_agent_work_environment.py
git commit -m "docs: add bilingual Superpowers history"
```

---

### Task 5: Perform final environment verification

**Files:**
- Verify: all files added or modified in Tasks 1 through 4

**Interfaces:**
- Consumes: The four contract-test classes and all paired documentation.
- Produces: A freshly verified AI agent work environment ready for branch integration.

- [ ] **Step 1: Run the focused cross-platform contract suite**

```powershell
python -m unittest tests.test_agent_work_environment -v
```

Expected: every test passes with `OK`.

- [ ] **Step 2: Parse the Claude settings independently**

```powershell
Get-Content -Raw -LiteralPath '.claude\settings.json' | ConvertFrom-Json | Out-Null
```

Expected: exit code 0 and no output.

- [ ] **Step 3: Check whitespace and unintended runtime changes**

```powershell
git diff --check e30a65b..HEAD
git diff e30a65b --name-only
```

Expected: `git diff --check e30a65b..HEAD` exits 0. The name list contains only `.claude/settings.json`, `.gitignore`, the six root Markdown instruction/README files, `docs/prompts/*`, paired `docs/superpowers/*` documents, and `tests/test_agent_work_environment.py`; it contains no `.github/workflows/*` path.

- [ ] **Step 4: Review secrets and recursively suffixed filenames**

```powershell
rg --pcre2 -n '(?<![\w${])UUREMOTE_(ACCOUNT_PASSWORD|CUSTOM_CODE)\s*[:=]\h*+(?!\$)' --glob '!docs/superpowers/**' .
Get-ChildItem -Recurse -File -Filter '*-zh_CN-zh_CN.md'
```

Expected: no newly added plaintext secret value, no newly added secret assignment, and no recursively suffixed Markdown file. Existing runtime debt outside this task must be reported rather than silently changed.

- [ ] **Step 5: Inspect commit and worktree state**

```powershell
git log --oneline 64d91d5..HEAD
git status --short
```

Expected: exactly six commits appear after `64d91d5`: one approved plan-correction commit, four focused implementation commits, and one approved security-redaction commit; the worktree is clean.

- [ ] **Step 6: Request final code review and finish the branch**

Invoke `superpowers:requesting-code-review`. Resolve all Critical and Important findings, rerun Steps 1 through 5, then invoke `superpowers:verification-before-completion` and `superpowers:finishing-a-development-branch`.
