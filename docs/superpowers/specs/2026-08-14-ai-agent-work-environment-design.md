# AI Agent Work Environment Design

[English](2026-08-14-ai-agent-work-environment-design.md) | [简体中文](2026-08-14-ai-agent-work-environment-design-zh_CN.md)

**Date:** 2026-08-14  
**Status:** Approved in conversation; awaiting written-spec review  
**Scope:** Repository-level AI agent instructions, bilingual documentation scaffolding, Claude Code project settings, ignore rules, and conversation-capture prompts

## 1. Objective

Adopt the AI agent work-environment conventions introduced by the first three commits of the sibling `scratchpad` project and adapt them to HelloWorldRemote.

The environment must:

1. Support both Codex and Claude Code with harness-specific startup checks.
2. Require the complete Superpowers development workflow for significant work.
3. Establish meaning-equivalent English and Simplified Chinese documentation.
4. Document project-specific security, validation, and platform-parity constraints.
5. Keep agent-generated worktrees, Superpowers state, Python environments, and caches out of Git.
6. Provide the bilingual conversation-capture prompt from the reference project.

This task configures the agent work environment only. It does not change the macOS or Windows workflows, scripts, runtime behavior, or existing technical decisions.

## 2. Reference Commits

The design uses these initial `scratchpad` commits as its reference:

- `a119e6d8a6834dc996f28f273dd01cd5f53c8c59`, which added the AI project template: `.claude/settings.json`, `.gitignore`, bilingual `AGENTS`, bilingual `CLAUDE`, and bilingual `README` files.
- `24be21461f21fc57ff05cd4d74f650c19683d819`, which replaced the template project name in the README files.
- `21fd7b173587547384c8757c67c8a01459709b42`, which added the bilingual conversation-capture prompt.

The reference files supply the policy structure. HelloWorldRemote-specific names, repository purpose, security boundaries, file layout, and validation requirements replace generic template content.

## 3. Repository Structure

The migration adds or updates this structure:

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

`AGENTS.md` is the English Codex instruction source and `AGENTS-zh_CN.md` is its meaning-equivalent Simplified Chinese counterpart. `CLAUDE.md` and `CLAUDE-zh_CN.md` serve the same roles for Claude Code.

`.claude/settings.json` requests project-level activation of `superpowers@claude-plugins-official`. It must not include personal paths, machine-specific permissions, or unrelated settings.

`.gitignore` includes `.superpowers/`, `.worktrees/`, `.venv/`, `__pycache__/`, and `*.pyc`.

## 4. Agent Development Workflow

The Codex and Claude Code instructions share the following requirements. Only harness-specific plugin names, installation instructions, and commands may differ.

### 4.1 Startup check

At the beginning of a new session, the agent checks that the applicable Superpowers startup skill is available and can be invoked. If it is unavailable, the agent must not claim that Superpowers is active, must tell the user how to install or enable it for that harness, and must not modify the repository merely to install it unless explicitly requested.

### 4.2 Significant-work workflow

For significant work, agents must:

1. Use `brainstorming` before designing new behavior.
2. Use `using-git-worktrees` after design approval and before implementation.
3. Use `writing-plans` before multi-step implementation.
4. Use `subagent-driven-development`, or `executing-plans` when human batch checkpoints are preferred, to execute an approved plan.
5. Follow `test-driven-development` for behavior changes and bug fixes.
6. Use `systematic-debugging` for failures and unexpected behavior.
7. Use `requesting-code-review` between tasks and before integration.
8. Use `receiving-code-review` before acting on review feedback.
9. Use `verification-before-completion` before making completion claims.
10. Use `finishing-a-development-branch` after fresh final verification.

Commit messages must follow Conventional Commits, using an appropriate type such as `fix:`, `feat:`, `chore:`, `docs:`, `refactor:`, or `test:`.

## 5. Project-Specific Safety and Platform Rules

The agent instructions must establish these HelloWorldRemote-specific constraints:

- Treat account passwords, UU Remote custom codes, and remote-device connection information as sensitive.
- Never hard-code real credentials in source, tests, defaults, logs, screenshots, or artifacts.
- Pass secrets through step-scoped environment variables, mask them before potentially logging commands run, and remove them from the environment as soon as practical.
- Do not enable direct root or Administrator login, and do not weaken SSH, UAC, firewall, or operating-system permission controls without an explicitly approved design.
- Make host configuration idempotent. Verify system state before mutation, verify the result afterward, and roll back changes made by the current run in reverse order when safe recovery information is available.
- Keep the externally visible macOS and Windows workflow contracts aligned while allowing platform-specific internal implementations.
- Write comments in source code, configuration files, scripts, tests, and code examples in English.
- Reply in Simplified Chinese when the user communicates in Simplified Chinese; otherwise default to English unless the user requests another language.

## 6. Bilingual Documentation Contract

Every Markdown file in the repository root and under `docs/` recursively must have meaning-equivalent English and Simplified Chinese versions.

The rules are:

1. Write or update the English version first.
2. Name the Chinese counterpart by appending `-zh_CN` to the basename before `.md`.
3. Treat suffixed files as counterparts, not source files; never create recursively suffixed names such as `README-zh_CN-zh_CN.md`.
4. Put a relative-language navigation line immediately after the H1 heading, with exactly one blank line before and after it.
5. Update all counterparts and navigation links in the same change.
6. Do not omit, add, weaken, or reinterpret requirements between language versions.
7. Use CommonMark-compliant longer backtick delimiters when an inline code span itself contains backticks.

This contract applies to all existing and future Superpowers plans and specifications. The migration therefore adds Simplified Chinese counterparts for every existing document under `docs/superpowers/plans/` and `docs/superpowers/specs/`, and adds navigation to the existing English files without changing their technical meaning.

## 7. README and Conversation Capture

The bilingual README files become the human entry point for the repository. They describe:

- the repository's purpose;
- the macOS and Windows workflow entry points;
- required GitHub Actions secrets;
- workflow inputs and diagnostic levels;
- the security implications of provisioning a remotely accessible runner;
- the source and test layout; and
- the applicable local and hosted validation paths.

The bilingual conversation-capture prompt is copied from the third reference commit with its fidelity, content-boundary, metadata, filename, and output requirements preserved. Only corrections required for valid language navigation or repository placement are permitted.

## 8. Migration Process

Implementation proceeds in this order:

1. Add the shared ignore rules and Claude Code project settings.
2. Add and customize the bilingual Codex and Claude Code instruction files.
3. Expand the English README and add its meaning-equivalent Chinese counterpart.
4. Add the bilingual conversation-capture prompts.
5. Add language navigation to every existing English plan and specification.
6. Translate every existing plan and specification into a `-zh_CN.md` counterpart without changing its technical conclusions, except for the authorized custom-code redaction described below.
7. Validate the complete documentation graph and configuration.
8. Commit the environment configuration as one coherent change.

Translation must preserve historical content except for one security-governed redaction: the known plaintext UU Remote custom code is represented as exactly `xxxxxx` in every English and Chinese document. This authorized placeholder replacement takes precedence over byte-for-byte historical preservation. Other obsolete or questionable statements in an existing design are not corrected silently during translation; any other semantic correction requires a separate, explicitly scoped change.

The implementation does not modify `.github/workflows/*`, `.github/workflows/apple.sh`, the Swift shutdown watcher, or existing runtime tests.

## 9. Validation

Before completion, verify:

- every root and `docs/**` Markdown file has exactly one correctly named counterpart;
- all language navigation links resolve to existing relative paths;
- every document has the required H1/navigation/blank-line structure;
- no recursively suffixed `-zh_CN-zh_CN.md` file exists;
- `.claude/settings.json` parses as JSON and enables only the expected Superpowers plugin;
- automated checks cover machine-readable structure only: JSON validity, required ignore entries, counterpart existence, exact navigation format, and relative-link resolution;
- task review confirms that the Codex and Claude Code instruction pairs contain the complete shared workflow and project rules, that the README files state current workflow facts accurately, and that the capture prompts preserve the reference semantics;
- existing English plans and specifications differ from the base versions only by language navigation and the authorized replacement of the known plaintext custom code with `xxxxxx`;
- currently runnable repository tests still pass;
- `git diff --check e30a65b..HEAD` passes; and
- the final diff contains only the approved environment and documentation changes.

If any counterpart is missing, any navigation link is invalid, any configuration cannot be parsed, or the shared instruction policies are inconsistent, the migration is incomplete and must not be committed as finished.

Exact-word or required-token assertions against human prose are prohibited because they are brittle change detectors rather than behavioral tests. Markdown, JSON, and ignore-file authoring is explicitly exempt from strict test-first development. Any new Python validation behavior still follows red-green-refactor and exercises real repository structure rather than asserting prose content.

## 10. Non-Goals

This task does not:

- implement Windows/macOS functional parity;
- change UU Remote installation, launch, permission, custom-code, or wait behavior;
- introduce personal Codex or Claude configuration;
- install plugins on the user's machine;
- rewrite historical technical decisions while translating them, except for the authorized `xxxxxx` security redaction; or
- add unrelated repository tooling.

After this environment task is implemented and verified, work returns to the separately approved functional-parity approach B.
