# UU Remote 桌面收尾与自定义代码 Secret 实施计划

[English](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret.md) | [简体中文](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-zh_CN.md)

> **供智能体工作者使用：** 必须使用子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项任务实施本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 让活跃 macOS 桌面立即可供 UU Remote 控制：关闭所有权限对话框、最小化 UU Remote、关闭 System Settings、本地化 Finder 和时钟 UI、配置高效的 Terminal 和键盘 preference，并使用经过验证、由 secret 支持的自定义代码。

**架构：** 为 `apple.sh` 扩展三项有界职责：console-user 桌面 preference 配置、精确的 UU Remote 权限对话框处理，以及最终桌面规范化。将自定义代码验证和 CLI 调用移至 `apple.sh` 接口之后，并将其 GitHub secret 限定在一个 workflow 步骤中。保留 debug level 作为编排策略：快速 run 使用条件轮询，诊断 run 添加证据但不改变最终 UI 状态。

**技术栈：** Bash 3.2、AppleScript/System Events accessibility API、Python 3 `plistlib`、macOS `defaults` 和 `launchctl`、UU Remote CLI、GitHub Actions YAML、Python `unittest`。

## 全局约束

- 直接在 `main` 上工作；不得创建 feature branch 或 worktree。
- 不得重启 macOS。
- 不得注销活跃图形用户。
- 不得终止无人值守控制所需的 UU Remote 后台服务。
- 继续支持英文和简体中文 macOS 界面。
- 保留 debug 含义：`0` 快速、`1` 截图、`2` 幂等性、`3` live sampling。
- 使用精确的本地化安全对话框操作；绝不使用屏幕坐标或盲目提交 Return 键。
- 保持直接 root 登录为禁用状态，并保留 `UUREMOTE_ACCOUNT_PASSWORD` 行为。
- 精确使用 `KeyRepeat=2` 和 `InitialKeyRepeat=15`。
- 仅当 `UUREMOTE_CUSTOM_CODE` 匹配 `^[A-Za-z0-9]{8,16}$` 时才接受它。
- 在相应 production 变更前运行每个 red 测试，然后在提交前将其重跑为 green。

---

### 任务 1：由 Secret 支持的 UU Remote 自定义代码

**文件：**
- 修改：`.github/workflows/macos.yml:64-104`
- 修改：`.github/workflows/apple.sh:1-120, 1071-1103, 1123-1335`
- 创建：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：step-scoped `UUREMOTE_CUSTOM_CODE`。
- 输出：`validate_uuremote_custom_code(value: string) -> shell status`、`set_uuremote_custom_code() -> shell status` 和 `apple.sh set-custom-code` 命令。

- [ ] **步骤 1：编写失败的 workflow secret-contract 测试**

添加到 `tests/test_uuremote_desktop_finalization.py`：

```python
from pathlib import Path
import os
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/macos.yml"
SCRIPT = ROOT / ".github/workflows/apple.sh"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    end = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if end < 0 else workflow[start:end]


class CustomCodeWorkflowTests(unittest.TestCase):
    def test_custom_code_is_required_masked_and_step_scoped(self):
        workflow = read(WORKFLOW)
        job_env = workflow[workflow.index("    env:\n"):workflow.index("\n    steps:\n")]
        block = step_block(workflow, "Configure UU Remote custom code")

        self.assertNotIn("UUREMOTE_CUSTOM_CODE", job_env)
        self.assertIn(
            "UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}",
            block,
        )
        self.assertIn("::add-mask::${UUREMOTE_CUSTOM_CODE}", block)
        self.assertIn("apple.sh set-custom-code", block)

    def test_hard_coded_custom_code_and_cli_echo_are_absent(self):
        combined = read(WORKFLOW) + read(SCRIPT)
        self.assertNotIn("johnDOE123", combined)
        self.assertNotIn("echo \"customCode: $output\"", combined)
```

- [ ] **步骤 2：运行 secret-contract 测试并验证 RED**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
```

预期：失败，因为专用 workflow 步骤和 `set-custom-code` 路由尚不存在，并且 `johnDOE123` 仍然存在。

- [ ] **步骤 3：编写失败的可执行验证测试**

添加：

```python
class CustomCodeValidationTests(unittest.TestCase):
    def validate(self, value: str | None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if value is None:
            env.pop("UUREMOTE_CUSTOM_CODE", None)
        else:
            env["UUREMOTE_CUSTOM_CODE"] = value
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "validate-custom-code"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_only_ascii_alphanumeric_codes_of_length_8_through_16(self):
        for value in ("Abcdef12", "A1b2C3d4E5f6G7h8", "12345678"):
            with self.subTest(value=value):
                self.assertEqual(self.validate(value).returncode, 0)

        for value in (None, "", "Abc1234", "A" * 17, "Abcd-123", "密码Abcd1234"):
            with self.subTest(value=value):
                result = self.validate(value)
                self.assertEqual(result.returncode, 2)
                if value:
                    self.assertNotIn(value, result.stdout + result.stderr)
```

- [ ] **步骤 4：运行验证测试并验证 RED**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeValidationTests -v
```

预期：失败，因为尚未实施 `validate-custom-code`。

- [ ] **步骤 5：实施验证和 CLI 重试且不记录该值**

在任何 macOS preflight 前添加早期、平台无关的 validator 和路由：

```bash
validate_uuremote_custom_code() {
    local value="${1:-}"
    [[ "$value" =~ ^[A-Za-z0-9]{8,16}$ ]]
}

if [ "$mode" = "validate-custom-code" ]; then
    if validate_uuremote_custom_code "${UUREMOTE_CUSTOM_CODE:-}"; then
        exit 0
    fi
    echo "UUREMOTE_CUSTOM_CODE must match ^[A-Za-z0-9]{8,16}$" >&2
    exit 2
fi
```

在 `run_in_gui` 可用后实施 `set_uuremote_custom_code`：在第一次 CLI 调用前进行验证，以 500 ms 间隔最多重试 120 次，丢弃 CLI stdout，仅记录尝试次数和通用成功消息，并在返回前 unset 其本地副本和环境变量。

拆分 `Launch GameViewer`，使其只启动 UU Remote 并等待 device ID。紧接着添加：

```yaml
      - name: Configure UU Remote custom code
        shell: bash
        env:
          UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}
        run: |
            if [ -z "${UUREMOTE_CUSTOM_CODE:-}" ]; then
                echo "Repository secret UUREMOTE_CUSTOM_CODE is required" >&2
                exit 2
            fi
            echo "::add-mask::${UUREMOTE_CUSTOM_CODE}"
            .github/workflows/apple.sh set-custom-code
            unset UUREMOTE_CUSTOM_CODE
```

将现有权限调用移入后续 `Configure UU Remote permissions` 步骤，且不带 custom-code 环境变量。

- [ ] **步骤 6：将聚焦测试和完整测试运行至 GREEN**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeValidationTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

预期：所有测试和检查通过，输出中没有 secret 值。

- [ ] **步骤 7：提交任务 1**

```bash
git add .github/workflows/macos.yml .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "security: source UU Remote custom code from secret"
git push origin main
```

---

### 任务 2：桌面 Preference 和免重启本地化刷新

**文件：**
- 修改：`.github/workflows/apple.sh:858-1068`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：现有 `console_uid`、`console_user`、`console_home`、`run_as_console_user`。
- 输出：`configure_desktop_preferences()`、`desktop_preferences_match()` 和 `refresh_localized_desktop()`。

- [ ] **步骤 1：编写失败的 preference contract 测试**

添加：

```python
class DesktopPreferenceContractTests(unittest.TestCase):
    def test_keyboard_uses_system_settings_visible_extremes(self):
        script = read(SCRIPT)
        self.assertIn("KeyRepeat", script)
        self.assertIn("InitialKeyRepeat", script)
        self.assertRegex(script, r"KeyRepeat.*(?:-int|integer).*2")
        self.assertRegex(script, r"InitialKeyRepeat.*(?:-int|integer).*15")

    def test_every_terminal_profile_gets_shell_exit_action_zero(self):
        script = read(SCRIPT)
        self.assertIn('preferences.get("Window Settings")', script)
        self.assertIn('profile["shellExitAction"] = 0', script)
        self.assertNotIn('"Window Settings":Basic:shellExitAction', script)

    def test_localization_refresh_never_restarts_or_logs_out(self):
        script = read(SCRIPT)
        self.assertIn("refresh_localized_desktop()", script)
        self.assertIn('killall Finder', script)
        self.assertIn('killall SystemUIServer', script)
        self.assertNotIn("shutdown -r", script)
        self.assertNotIn("osascript -e 'tell application \"System Events\" to log out'", script)
```

- [ ] **步骤 2：运行 preference 测试并验证 RED**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DesktopPreferenceContractTests -v
```

预期：失败，因为桌面 preference 单元不存在。

- [ ] **步骤 3：实施确定性 preference 写入和回读**

紧接 `configure_language_and_region` 后实施 `configure_desktop_preferences`：

- 以 console user 身份写入 `NSGlobalDomain KeyRepeat -int 2` 和 `InitialKeyRepeat -int 15`；
- 将 `com.apple.Terminal` 导出到 console user 所有的临时 plist；
- 使用 Python `plistlib` 要求 `Window Settings` 处为 dictionary，迭代每个 profile dictionary，并将 `shellExitAction` 设为整数 `0`；
- 通过 console user 的 `defaults` 进程导入修改后的 plist；
- 使用现有 bootstrap 临时目录删除这个精确的临时 plist；
- 回读两个 domain，除非每个值都匹配，否则失败。

Python mutation 核心必须等价于：

```python
window_settings = preferences.get("Window Settings")
if not isinstance(window_settings, dict) or not window_settings:
    raise SystemExit("Terminal Window Settings profiles are unavailable")
for profile in window_settings.values():
    if isinstance(profile, dict):
        profile["shellExitAction"] = 0
```

- [ ] **步骤 4：实施定向本地化刷新和 UI 验证**

实施 `refresh_localized_desktop` 以：

- 停止 console user 的 `cfprefsd`，以加载新的全局 preference；
- 仅在 Finder、SystemUIServer 和 ControlCenter 存在时终止它们；
- 根据条件等待 Finder 和菜单栏 owner 恢复；
- 检查 Finder 的 accessibility 菜单栏是否有中文菜单标题，并拒绝英文集合 `File`、`Edit`、`View`、`Go`、`Window`、`Help`；
- 检查 SystemUIServer 和 ControlCenter 菜单栏项目并拒绝英文星期/月份 token，同时要求至少出现 `月`、`周`、`星期`、`上午` 或 `下午` 等一个中文日期标记。

不得调用 reboot、shutdown 或 logout API。在语言和地区配置之后、提交主机事务之前，从 `configure_host` 调用 `configure_desktop_preferences`。

- [ ] **步骤 5：将聚焦测试和完整测试运行至 GREEN**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DesktopPreferenceContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

预期：所有检查均通过。

- [ ] **步骤 6：提交任务 2**

```bash
git add .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: configure macOS remote desktop preferences"
git push origin main
```

---

### 任务 3：精确重启提示处理和最终桌面规范化

**文件：**
- 修改：`.github/workflows/apple.sh:1425-2386`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：现有目标应用程序名称、debug level、截图目录和 CLI readiness helper。
- 输出：AppleScript `dismissUURemoteRestartPrompt`、shell `normalize_remote_desktop()` 和 final-state verifier。

- [ ] **步骤 1：编写失败的权限和顺序测试**

添加：

```python
class PermissionFinalizationContractTests(unittest.TestCase):
    def test_permission_dialogs_use_exact_bilingual_actions(self):
        script = read(SCRIPT)
        for token in (
            "com.netease.uuremote.agent",
            "Allow",
            "允许",
            "Quit & Reopen",
            "Quit and Reopen",
            "退出并重新打开",
        ):
            self.assertIn(token, script)

    def test_old_blind_post_add_return_is_absent(self):
        script = read(SCRIPT)
        self.assertNotIn(
            "accepted the default post-add confirmation, if present",
            script,
        )

    def test_final_order_is_picker_then_minimize_then_close_settings(self):
        script = read(SCRIPT)
        picker = script.rindex("run_permission agent-private-picker")
        normalize = script.index("normalize_remote_desktop", picker)
        self.assertLess(picker, normalize)
        self.assertLess(
            script.index("minimizeUURemoteWindows", normalize),
            script.index("closeSystemSettings", normalize),
        )

    def test_normalizer_verifies_cli_dialogs_minimized_app_and_closed_settings(self):
        script = read(SCRIPT)
        for token in (
            "AXMinimized",
            "UserNotificationCenter",
            "System Settings",
            "wait_for_cli",
            "FINAL_DESKTOP_STATE=ready",
        ):
            self.assertIn(token, script)
```

- [ ] **步骤 2：运行权限测试并验证 RED**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.PermissionFinalizationContractTests -v
```

预期：失败，因为桌面 normalizer 不存在，且盲目的 post-add Return 路径仍然存在。

- [ ] **步骤 3：用对话框特定匹配替换盲目接受重启**

在权限 AppleScript 内：

- 移除无条件的 `key code 36` 及其通用成功消息；
- 从 window title、description 和 static text 构建 dialog context string；
- 要求 context 包含 UU Remote 名称以及英文或简体中文的“退出前无法录制”含义；
- 仅在该窗口中搜索 `Quit & Reopen`、`Quit and Reopen` 或 `退出并重新打开`；
- 按下精确操作，等待该特定对话框消失，等待 UU Remote 及其 CLI 恢复，然后回读屏幕录制 switch；
- 将提示不存在视为幂等路径，但如果匹配的提示没有已识别操作则失败。

- [ ] **步骤 4：实施最终桌面规范化**

在最终 private-picker handler 后添加 shell `normalize_remote_desktop`。其 AppleScript 必须按顺序公开并调用以下 handler：

- `assertKnownPromptsAbsent()` 以 `shouldPressAllow=false` 调用现有 private-picker inspector，扫描每个 System Settings 窗口中的双语 UU Remote “退出前无法录制”文本，并在任一 inspector 返回匹配时引发错误；
- `minimizeUURemoteWindows()` 迭代名称匹配双语 UU Remote target-name 列表的每个现有进程，将每个普通窗口的 `AXMinimized` attribute 设为 `true`，并在返回前回读该 attribute；
- `closeSystemSettings()` 发送正常应用程序 quit 事件，轮询至进程不存在或窗口数为零，并且仅当有界优雅等待后仍有窗口时，才使用现有 GUI-session `killall` fallback。

UI 清理后，调用 `wait_for_cli`，验证所有剩余 UU Remote 普通窗口都报告 `AXMinimized=true`，验证 System Settings 没有窗口，重新扫描两个已知对话框，并精确打印 `FINAL_DESKTOP_STATE=ready`。

在权限配置周围安装 EXIT trap：启用 debug 时捕获诊断截图，并且只尝试规范化中不点击的部分。最终验证成功后清除 trap。

- [ ] **步骤 5：将聚焦测试和完整测试运行至 GREEN**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.PermissionFinalizationContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

预期：所有检查均通过。

- [ ] **步骤 6：提交任务 3**

```bash
git add .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: finalize UU Remote macOS desktop state"
git push origin main
```

---

### 任务 4：在诊断和幂等性运行中保留最终状态

**文件：**
- 修改：`.github/workflows/apple.sh:1163-1235, 2361-2386`
- 修改：`.github/workflows/macos.yml:105-149`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：任务 3 的最终桌面 contract 和现有 debug level。
- 输出：保留状态的 `capture_snapshot(label)` 和 workflow 顺序保证。

- [ ] **步骤 1：编写失败的 diagnostics-state 测试**

添加：

```python
class DiagnosticStateContractTests(unittest.TestCase):
    def test_final_and_live_snapshots_do_not_open_uuremote(self):
        script = read(SCRIPT)
        capture = script[
            script.index("capture_snapshot()"):
            script.index("dismiss_uuremote_private_window_prompt()")
        ]
        self.assertNotIn('run_in_gui /usr/bin/open "$APP"', capture)
        self.assertNotIn("live-*|final-app*", capture)

    def test_normalization_precedes_wait_connections(self):
        workflow = read(WORKFLOW)
        permission = workflow.index("      - name: Configure UU Remote permissions")
        wait = workflow.index("      - name: Wait connections")
        self.assertLess(permission, wait)

    def test_debug_zero_keeps_screenshot_and_artifact_paths_disabled(self):
        workflow = read(WORKFLOW)
        upload = step_block(workflow, "Upload permission screenshots")
        self.assertIn("env.UUREMOTE_DEBUG != '0'", upload)
```

- [ ] **步骤 2：运行 diagnostics-state 测试并验证 RED**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DiagnosticStateContractTests -v
```

预期：失败，因为 `capture_snapshot` 仍会为 `live-*` 和 `final-app*` 打开 UU Remote。

- [ ] **步骤 3：使证据捕获仅进行观察**

从 `capture_snapshot` 移除 `live-*|final-app*` open-app case。将最终 label 重命名为 `final-desktop`，仅在规范化后调用它，并确保 level 1 捕获：

- 操作前后的重启提示；
- 执行 Allow 前后的 private picker；
- Finder/时钟本地化验证；
- UU Remote 最小化且 System Settings 关闭后的最终干净桌面。

保持 level 0 无截图。保留 level 2 的第二次权限 run 和 level 3 live sampler，但使每个 sample 都观察已规范化的状态。

- [ ] **步骤 4：将聚焦测试和完整测试运行至 GREEN**

运行：

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DiagnosticStateContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

预期：所有检查均通过。

- [ ] **步骤 5：提交任务 4**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_desktop_finalization.py
git commit -m "test: preserve finalized desktop during diagnostics"
git push origin main
```

---

### 任务 5：macOS Actions 验证和最终交接

**文件：**
- 验证：`.github/workflows/apple.sh`
- 验证：`.github/workflows/macos.yml`
- 验证：`tests/test_uuremote_desktop_finalization.py`
- 验证：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：repository secret `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE`。
- 输出：两次成功的 Actions run，以及最终桌面 contract 成立的证据。

- [ ] **步骤 1：运行完整 repository 验证**

运行：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
```

预期：所有测试通过，Bash 语法检查成功，没有 whitespace 错误，并且 worktree 干净。

- [ ] **步骤 2：确认两个 repository secret 均存在且不读取其值**

使用 GitHub Actions secrets 页面，并验证列表中存在 `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE`。如果 custom-code secret 缺失，停止并请用户创建；绝不虚构或显示其值。

- [ ] **步骤 3：运行诊断 Actions 验证**

使用以下值分派 `macOS`：

```text
debug_level=1
wait_connections_seconds=0
```

验证日志包含通用 custom-code 成功信息、持久化权限、本地化 Finder/时钟验证、Terminal 和键盘回读、`FINAL_DESKTOP_STATE=ready`，且不含 secret 值。检查 artifact 的最终截图，确认 UU Remote 和 System Settings 未显示在前台。

- [ ] **步骤 4：通过新的 RED/GREEN 循环修复任何仅限 macOS 的失败**

对于每个真实 runner 失败，添加能复现所观察原因的最小 contract 或行为测试，将其运行至 RED，实施一个根因修复，将其运行至 GREEN，然后在再次分派前重跑完整套件。不得叠加推测性修复。

- [ ] **步骤 5：运行 fast-path Actions 验证**

使用以下值分派 `macOS`：

```text
debug_level=0
wait_connections_seconds=5
```

验证诊断 self-test、幂等性、live sampling、截图捕获和 artifact 上传仍被跳过；验证桌面 finalizer 成功，并且等待以 `WAIT_RESULT=timeout` 结束。

- [ ] **步骤 6：执行最终 main 同步检查**

运行：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

预期：所有检查均通过，工作树干净，并且两个 hash 相匹配。
