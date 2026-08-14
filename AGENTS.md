# Project instructions

[English](AGENTS.md) | [简体中文](AGENTS-zh_CN.md)

This project uses the Superpowers plugin for Codex.

## Startup check

At the beginning of a new session:

1. Check whether the `using-superpowers` skill is available and can be invoked.
2. If `using-superpowers` is unavailable or cannot be invoked, do not pretend that Superpowers is active.
3. Tell the user:

   > Superpowers is required for this project but is not installed or enabled.
   > Open `/plugins`, search for `superpowers`, install and enable it, then start a new Codex session.

4. Do not modify the repository merely to install Superpowers unless the user explicitly asks you to do so.

## Project scope

* `.github/workflows/macos.yml` defines the macOS GitHub Actions workflow contract.
* `.github/workflows/windows.yml` defines the Windows GitHub Actions workflow contract.
* `.github/workflows/apple.sh` implements the macOS host provisioning and workflow operations.
* `.github/workflows/uuremote-shutdown-wait.swift` observes UU Remote shutdown completion on macOS.
* `tests/` contains repository validation and runtime contract tests.
* `docs/superpowers/` contains the approved designs and implementation plans that govern significant work.

## Development workflow

When Superpowers is available, follow its full workflow for significant work rather than only its testing and debugging pieces. The installed Superpowers skill content is the source of truth for each skill's detailed procedure. The rules below are project-specific minimum requirements and must not be interpreted as weakening stricter requirements in the installed skills.

* Use `brainstorming` before designing significant new behavior. Let it turn a rough idea into a spec through questions, and review the design in the sections it presents rather than skipping ahead to code.
* Once a design is approved, use `using-git-worktrees` to set up an isolated workspace on a new branch, so implementation doesn't happen directly on the branch you started from.
* Use `writing-plans` before multi-step implementation. Expect the plan to be broken into small tasks with exact file paths, code, and verification steps.
* Use `subagent-driven-development` to carry out an approved plan, dispatching a fresh subagent per task with review at each step; use `executing-plans` instead when batch execution with human checkpoints is preferred.
* Follow test-driven development (`test-driven-development`) for behavior changes and bug fixes: write a failing test, watch it fail, write the minimal code to pass it, then refactor.
* Use `systematic-debugging` for test failures and unexpected behavior instead of ad hoc fixes.
* Use `requesting-code-review` between tasks and before merging. Fix Critical issues immediately and resolve Important issues before proceeding; Minor issues may be deferred.
* Use `receiving-code-review` before acting on review feedback, especially when the feedback is unclear or technically questionable.
* Use `verification-before-completion` before claiming that work is complete, fixed, or passing.
* Use `finishing-a-development-branch` once work is complete and freshly verified.
* Commit messages must follow Conventional Commits. Use an appropriate type such as `fix:`, `feat:`, `chore:`, `docs:`, `refactor:`, or `test:`.

## Project safety and validation

* Treat account passwords, UU Remote custom codes, and remote-device connection information as sensitive. In particular, `UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE` are secrets.
* Never hard-code real credentials in source, tests, defaults, logs, screenshots, or artifacts.
* Pass secrets through step-scoped environment variables, mask them before potentially logging commands run, and remove them from the environment as soon as practical.
* Do not enable direct root or Administrator login, and do not weaken SSH, UAC, firewall, or operating-system permission controls without an explicitly approved design.
* Make host configuration idempotent. Verify system state before mutation, verify the result afterward, and roll back changes made by the current run in reverse order when safe recovery information is available.
* Keep the externally visible macOS and Windows workflow contracts aligned while allowing platform-specific internal implementations.
* Before completion, verify that every root and `docs/**` Markdown file has exactly one correctly named counterpart; language navigation links resolve to existing relative paths; every document has the required H1, navigation, and blank-line structure; and no recursively suffixed `-zh_CN-zh_CN.md` file exists.
* Also verify that `.claude/settings.json` parses as JSON and enables only the expected Superpowers plugin; automated checks cover only machine-readable structure; review confirms complete shared instruction policies, accurate README workflow facts, and faithful capture prompts; existing English plans and specifications differ only by language navigation; currently runnable repository tests pass; `git diff --check` passes; and the final diff contains only approved environment and documentation changes.
* If any counterpart is missing, any navigation link is invalid, any configuration cannot be parsed, or the shared instruction policies are inconsistent, the migration is incomplete and must not be committed as finished.

## Language and documentation rules

* When communicating with the user through the chat interface, reply in Simplified Chinese when the user uses Simplified Chinese. Otherwise, default to English unless the user explicitly requests a different language.
* Keep common software development terms in English when translating them could reduce precision or create ambiguity.
* The following multilingual documentation rules apply to every `.md` file in the repository's top-level directory and under the `docs/` directory recursively:

  1. Write the English version first, then create or update a meaning-equivalent Simplified Chinese version by appending `-zh_CN` to the basename before `.md`.
  2. Treat files with language suffixes as counterparts, not source documents. Do not create recursively suffixed filenames such as `README-zh_CN-zh_CN.md`.
  3. In every language version, place the navigation line after the level-one heading with exactly one blank line between the heading and navigation and exactly one blank line between navigation and the following content. It must use relative links to all available language versions and include at least English and Simplified Chinese.
  4. Whenever one language version changes, update all counterparts and their navigation links in the same change. Do not omit, add, weaken, or reinterpret requirements between language versions.
  5. When an inline code span's content itself needs to contain a backtick, delimit the span with a longer run of backticks than any backtick sequence inside it, and add a single space just inside each delimiter if the content starts or ends with a backtick, following CommonMark's rules for backtick-delimited code spans.

* All comments in source code, configuration files, scripts, tests, and code examples must be written in English. Do not use Chinese in code comments.
* Except for harness-specific installation and startup instructions, the shared workflow, language, documentation, scope, safety, and validation policies in `AGENTS.md` and `CLAUDE.md` must remain meaning-equivalent.
