# UU Remote macOS 主机引导实施计划

[English](2026-08-10-uuremote-host-bootstrap.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-zh_CN.md)

> **供智能体工作者使用：** 必须使用子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项任务实施本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 从一个幂等 workflow 输入准备活跃 macOS 图形账户、root 密码状态、login keychain、自动登录密码、新加坡语言/地区 preference 和双语 UU Remote 权限。

**架构：** 在任何 UU Remote application preflight 前，为现有 `apple.sh` 添加早期 `configure-host` mode。该 mode 运行显式账户事务、root-keychain 事务和 locale 事务；现有默认 mode 仍负责 UU Remote 并接收双语 selector。`macos.yml` 只向 bootstrap 步骤提供密码，并保留现有诊断和 connection-wait 行为。

**技术栈：** Bash 3.2、AppleScript/System Events、macOS Directory Services（`dscl`）、Keychain CLI（`security`）、`defaults`、Python 3 标准库、GitHub Actions YAML、Python `unittest`。

## 全局约束

- 添加且仅添加一个名为 `account_password` 的明文 `workflow_dispatch` string 输入，它是必需的，默认值为 `john.doe`。
- 立即用 GitHub `::add-mask::` 屏蔽该输入；绝不打印密码。
- 将 `UUREMOTE_ACCOUNT_PASSWORD` 仅限于 host-configuration 步骤。
- 从 `/dev/console` 检测图形账户；绝不硬编码 `runner`，也不从 `$HOME` 推导其 home。
- macOS 接受时首先使用 `zh-Hans-SG`，否则使用 `zh-Hans-CN`；第二个使用 `en-SG`，locale 使用 `zh_SG`，地区使用新加坡。
- 绝不重启或注销 macOS。只点击精确识别的否定重启操作。
- 更改 root 密码，但绝不启用 root，也绝不更改 SSH root-login 配置。
- root login keychain 不存在时不得创建。
- 仅在完全成功后删除不可用的旧 root-keychain backup；失败时恢复它。
- 以 `root:wheel`、mode `0600` 原子替换 `/etc/kcpassword`，并通过解码验证。
- 仅向 UU Remote 主应用程序授予权限；绝不恢复 `UURemoteServer` 权限。
- 保留 debug level `0`–`3`、等待范围 `0`–`21000` 及其当前语义。
- 不得修改 `.github/workflows/a.sh` 或无关文件。

## 文件结构

- 修改：`.github/workflows/macos.yml` — workflow 输入、有序 bootstrap 步骤和集成验证。
- 修改：`.github/workflows/apple.sh` — 路由、codec、账户/keychain 事务、locale 事务和双语权限 UI。
- 创建：`tests/test_uuremote_host_bootstrap.py` — 静态 contract 加无副作用的 codec self-test launcher。

---

### 任务 1：锁定 Workflow Contract

**文件：**
- 创建：`tests/test_uuremote_host_bootstrap.py`
- 修改：`.github/workflows/macos.yml:3-44`

**接口：**
- 输入：现有 `Checkout` 和 `Install GameViewer` 步骤。
- 输出：`inputs.account_password`；step-scoped `UUREMOTE_ACCOUNT_PASSWORD`；对 `apple.sh configure-host` 的调用。

- [ ] **步骤 1：编写失败的 workflow 测试**

创建一个标准库 `unittest` 文件，其中包含 `ROOT`、`WORKFLOW_PATH`、`SCRIPT_PATH`、UTF-8 `text(path)` reader 和 `step_block(workflow, name)` helper。添加 assertion 以确认：

```python
self.assertRegex(workflow, r"(?ms)^      account_password:.*?^        required: true$.*?^        default: [\"']?john\.doe[\"']?$.*?^        type: string$")
self.assertLess(workflow.index("- name: Configure macOS host"), workflow.index("- name: Install GameViewer"))
self.assertNotRegex(workflow, r"(?ms)^    env:.*UUREMOTE_ACCOUNT_PASSWORD")
self.assertIn("UUREMOTE_ACCOUNT_PASSWORD: ${{ inputs.account_password }}", configure_step)
self.assertIn("::add-mask::", configure_step)
self.assertIn(".github/workflows/apple.sh configure-host", configure_step)
self.assertNotIn("configure-host", idempotency_step)
```

- [ ] **步骤 2：运行测试并观察预期失败**

运行 `python3 -m unittest tests/test_uuremote_host_bootstrap.py -v`。

预期：input 和 configuration-step assertion 失败；idempotency assertion 通过。

- [ ] **步骤 3：添加输入和 bootstrap 步骤**

在 `wait_connections_seconds` 后添加：

```yaml
      account_password:
        description: Password for the console user, root, login keychains, and auto-login data
        required: true
        default: john.doe
        type: string
```

紧接 Checkout 后添加：

```yaml
      - name: Configure macOS host
        shell: bash
        env:
          UUREMOTE_ACCOUNT_PASSWORD: ${{ inputs.account_password }}
        run: |
            echo "::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}"
            .github/workflows/apple.sh configure-host
```

- [ ] **步骤 4：验证并提交**

运行 `python3 -m unittest tests/test_uuremote_host_bootstrap.py -v` 和 `git diff --check`；两者都必须通过。然后：

```bash
git add tests/test_uuremote_host_bootstrap.py .github/workflows/macos.yml
git commit -m "test: define macOS host bootstrap contract"
```

---

### 任务 2：添加早期路由和经过测试的 kcpassword Codec

**文件：**
- 修改：`.github/workflows/apple.sh:4-37,235-247,303-317`
- 修改：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：第一个位置 mode 参数。
- 输出：从 stdin 读取的 `encode_kcpassword OUTPUT_PATH`；写入 stdout 的 `decode_kcpassword INPUT_PATH`；`self-test-kcpassword` mode。

- [ ] **步骤 1：添加失败测试**

断言 `if [ "$mode" = "configure-host" ]` 出现在 `if [ ! -d "$APP" ]` 之前。使用 `subprocess.run` 启动 `/bin/bash apple.sh self-test-kcpassword`；要求退出 0 并输出 `kcpassword codec self-test passed`。

- [ ] **步骤 2：运行并观察失败**

运行聚焦测试 class。预期：早期路由不存在，self-test 遇到现有 macOS/UURemote preflight 或 usage 失败。

- [ ] **步骤 3：在 macOS preflight 前实施 codec**

使用 Python 3 和静态 XOR key `7d 89 52 23 d2 bc dd ea a3 b9 1f`。`encode_kcpassword` 从 stdin 读取 byte，追加至少一个 NUL，填充到 12-byte boundary，执行 XOR，并写入请求的文件。`decode_kcpassword` 读取文件、执行 XOR，并输出第一个 NUL 之前的 byte。密码 byte 绝不得作为命令行参数或出现在日志中。

self-test 使用 mode-0700 临时目录，并对以下值执行 round trip 而不打印它们：

```text
john.doe
space and $hell!
12345678901
123456789012
1234567890123
密码-SG
```

在读取 `/dev/console`、检查 `$APP` 或调用仅限 macOS 的 UI 命令前，分派 `self-test-kcpassword` 和 `configure-host`。在任务 3–5 完成前，`configure_host` 必须以 `Host bootstrap implementation is incomplete` 明确失败。

- [ ] **步骤 4：在权限 mode 中复用 decoder**

用以下内容替换现有 inline Python decoder：

```bash
runner_password="$(sudo decode_kcpassword /etc/kcpassword)"
```

保留现有 nonempty 和 `dscl -authonly` 检查。

- [ ] **步骤 5：验证并提交**

运行 `/bin/bash -n .github/workflows/apple.sh`、聚焦测试和 `git diff --check`。然后：

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: add kcpassword codec and bootstrap routing"
```

---

### 任务 3：实施图形用户事务

**文件：**
- 修改：`.github/workflows/apple.sh:4-345`
- 修改：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：仅在 `configure_host` 内使用的 `UUREMOTE_ACCOUNT_PASSWORD`。
- 输出：`resolve_console_account`、`password_authenticates`、`keychain_unlocks`、`configure_console_user`、`write_kcpassword_atomically`、`restore_original_kcpassword` 和 `rollback_console_user_transaction`。

- [ ] **步骤 1：添加失败的事务测试**

为所有输出的函数名称和以下精确安全标记添加 assertion：

```python
self.assertIn("stat -f '%Su' /dev/console", script)
self.assertIn("NFSHomeDirectory", script)
self.assertNotIn('console_user="runner"', configure_host_body)
self.assertNotIn('console_home="$HOME"', configure_host_body)
self.assertIn('chown root:wheel "$kcpassword_temp"', script)
self.assertIn('chmod 0600 "$kcpassword_temp"', script)
self.assertIn('mv -f "$kcpassword_temp" /etc/kcpassword', script)
self.assertIn('decode_kcpassword /etc/kcpassword', script)
```

- [ ] **步骤 2：运行并观察失败**

运行聚焦事务测试 class。预期：home lookup、事务 helper、rollback 和 atomic replacement assertion 失败。

- [ ] **步骤 3：实施图形账户发现和 probe**

`resolve_console_account` 设置全局 `console_uid`、`console_user` 和 `console_home`。拒绝低于 501 的 UID 以及账户 `root`、`loginwindow`、`_mbsetupuser`。使用以下命令读取 home：

```bash
console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory |
    /usr/bin/sed 's/^NFSHomeDirectory: //')"
```

实施丢弃输出的 probe：

```bash
password_authenticates() {
    /usr/bin/dscl . -authonly "$1" "$2" >/dev/null 2>&1
}

keychain_unlocks() {
    /usr/bin/security unlock-keychain -p "$2" "$1" >/dev/null 2>&1
}
```

优先使用 `$console_home/Library/Keychains/login.keychain-db`，其次使用 `login.keychain`；两者都不存在时在变更前失败。

- [ ] **步骤 4：捕获 rollback 状态并实施原子 kcpassword 替换**

创建 mode 为 `0700` 的 `/tmp/uuremote-bootstrap.XXXXXX`。以 root 身份将现有 `/etc/kcpassword` 复制到其中，并记录原文件是否存在。

writer 顺序必须精确如下：

```bash
kcpassword_temp="$bootstrap_temp_dir/kcpassword.new"
printf '%s' "$account_password" | encode_kcpassword "$kcpassword_temp"
sudo /usr/sbin/chown root:wheel "$kcpassword_temp"
sudo /bin/chmod 0600 "$kcpassword_temp"
sudo /bin/mv -f "$kcpassword_temp" /etc/kcpassword
decoded_password="$(sudo decode_kcpassword /etc/kcpassword)"
[ "$decoded_password" = "$account_password" ] || return 1
unset decoded_password
```

存在保存副本时，`restore_original_kcpassword` 原子恢复它；否则移除新创建的最终文件。

- [ ] **步骤 5：实施变更、验证和反向 rollback**

解码原始 kcpassword，并且仅在 `dscl -authonly` 验证后才将其作为 `old_account_password` 接受。针对账户、keychain 和 kcpassword 独立探测期望密码，然后跳过已正确的组件。

对于不匹配的组件，按以下顺序变更：

```bash
/usr/bin/security set-keychain-password \
  -o "$old_account_password" -p "$account_password" "$user_login_keychain"
sudo /usr/bin/dscl . -passwd "/Users/$console_user" \
  "$old_account_password" "$account_password"
write_kcpassword_atomically
```

继续前验证每项变更。跟踪 `user_keychain_changed`、`user_password_changed` 和 `kcpassword_changed`。以相反顺序 rollback：kcpassword、Directory Services 密码，然后是 login keychain 密码。一次失败后仍继续所有 rollback 尝试；任一恢复失败则返回非零。

- [ ] **步骤 6：验证并提交**

运行 Bash 语法检查、聚焦事务测试、codec 测试和 `git diff --check`。然后：

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: configure macOS console account atomically"
```

---

### 任务 4：更新禁用的 Root 及其现有 Keychain

**文件：**
- 修改：`.github/workflows/apple.sh:4-430`
- 修改：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：`account_password`、可用时经过验证的旧密码，以及 bootstrap rollback 目录。
- 输出：`root_is_disabled`、`verify_root_password_hash`、`find_root_login_keychain`、`configure_root`、`rollback_root_keychain` 和 `commit_root_keychain_backup`。

- [ ] **步骤 1：添加失败的 root-safety 测试**

要求每个输出函数名称、`SALTED-SHA512-PBKDF2` 和 `hashlib.pbkdf2_hmac`。禁止以下全部内容：

```python
for token in ("dsenableroot", "PermitRootLogin", "sshd_config"):
    self.assertNotIn(token, script)
```

还要求精确的 absent-keychain 状态 `No root login keychain exists; leaving it absent`，以及事务标记 `root_keychain_backup`、`rollback_root_keychain` 和 `commit_root_keychain_backup`。

- [ ] **步骤 2：运行并观察失败**

运行 root-safety 测试 class。预期：state/hash/keychain helper assertion 失败；forbidden-operation assertion 通过。

- [ ] **步骤 3：实施 disabled-state 和 root-password 验证**

`root_is_disabled` 读取 `/Users/root` 的 `AuthenticationAuthority`，并要求 Open Directory `DisabledUser` authority。在以下操作前后都要求它：

```bash
sudo /usr/bin/dscl . -passwd /Users/root "$account_password"
```

绝不调用 `dsenableroot`，也绝不更改 SSH 配置。

由于无法用普通登录验证禁用的 root，`verify_root_password_hash` 以 root 身份读取 root 的 `ShadowHashData` plist，提取 `SALTED-SHA512-PBKDF2`，并通过 stdin 将候选密码传给 Python。使用以下代码验证：

```python
derived = hashlib.pbkdf2_hmac(
    "sha512",
    password_bytes,
    hash_data["salt"],
    int(hash_data["iterations"]),
    dklen=len(hash_data["entropy"]),
)
if not hmac.compare_digest(derived, hash_data["entropy"]):
    raise SystemExit(1)
```

绝不记录密码、salt、entropy 或 derived key。

- [ ] **步骤 4：实施可选 root-keychain 事务**

按顺序搜索：

```text
/var/root/Library/Keychains/login.keychain-db
/var/root/Library/Keychains/login.keychain
```

如果不存在，记录精确的 absent 消息，并且不创建。如果存在且可用新密码解锁，则跳过。否则，如果可用经过验证的旧密码解锁，则就地更新。如果两个密码都无法解锁，则将其移动到受保护的事务 backup，在精确的原路径创建替代项，设置 root 所有权，并用新密码验证。

`rollback_root_keychain` 删除替代项并恢复 backup。`commit_root_keychain_backup` 仅在每个 bootstrap 阶段都成功后永久删除 backup。

- [ ] **步骤 5：将 root 失败连接到外层 rollback**

图形用户成功后调用 `configure_root`。失败时以相反顺序调用 `rollback_root_keychain` 和 `rollback_console_user_transaction`。为意外失败安装 EXIT trap；事务 flag 防止重复 rollback。

- [ ] **步骤 6：验证并提交**

运行 Bash 语法检查、所有 root/transaction/codec 测试以及 `git diff --check`。然后：

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: update disabled root and existing keychain"
```

---

### 任务 5：配置新加坡语言并安全拒绝重启

**文件：**
- 修改：`.github/workflows/apple.sh:4-530`
- 修改：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：`console_uid`、`console_user`、`console_home` 和 `run_in_gui`。
- 输出：`language_settings_match`、`configure_language_and_region` 和 `dismiss_safe_restart_prompt`。

- [ ] **步骤 1：添加失败的 locale-safety 测试**

要求 `zh-Hans-SG`、`zh-Hans-CN`、`en-SG`、`zh_SG` 和 `SG`。要求安全 label `Not Now`、`Later`、`Restart Later`、`稍后`、`暂不` 和 `以后再说`。断言 `Restart Now` 和 `现在重新启动` 不是传给任何 button-press helper 的列表成员。要求 prompt dismissal 嵌套在以下精确 guard 中：

```bash
if [ "$language_or_region_changed" = "1" ]; then
    dismiss_safe_restart_prompt
fi
```

- [ ] **步骤 2：运行并观察失败**

运行 locale 测试 class。预期：language、fallback、prompt-vocabulary 和 conditional-scan assertion 失败。

- [ ] **步骤 3：实施先读后写 preference**

使用 `run_in_gui defaults`，使值属于 console user。写入前读取 `AppleLanguages`、`AppleLocale`、metric unit 和地区。如果已经正确，则记录跳过，并保持 `language_or_region_changed=0`。

首先将 `AppleLanguages` 写为数组 `zh-Hans-SG`、`en-SG`；写入 `AppleLocale=zh_SG`、`AppleMeasurementUnits=Centimeters` 和 `AppleMetricUnits=true`。回读语言数组。仅当 `zh-Hans-SG` 是有效第一值时保留它；否则只将语言数组重写为 `zh-Hans-CN`、`en-SG`。验证精确顺序、locale、metric 设置和新加坡地区语义。

- [ ] **步骤 4：实施窄范围重启提示处理**

检查 `System Settings` 和 `UserNotificationCenter`。确认周围文本表示英文或简体中文的重启或重新登录提示。只按下以下集合中的精确成员：

```applescript
{"Not Now", "Later", "Restart Later", "稍后", "暂不", "以后再说"}
```

如果可见重启相关对话框，但没有精确的安全否定操作，则不点击并失败。如果有界等待期间没有出现相关对话框，则返回成功。仅在真实 preference 更改后调用此 handler。

- [ ] **步骤 5：完成 configure-host 编排**

用以下调用顺序替换临时失败 body：验证非空 `UUREMOTE_ACCOUNT_PASSWORD`；解析 console account；开始事务；配置 console user；配置 root；配置语言和地区；提交 root-keychain backup；结束事务；unset 密码变量。

Locale 或提示失败会先触发 root-keychain rollback，再触发 graphical-user rollback。完全成功时移除事务目录、清除 EXIT trap，并且只打印非 secret 状态。

- [ ] **步骤 6：验证并提交**

运行 Bash 语法检查、完整 Python 套件、codec self-test 和 `git diff --check`。然后：

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: configure Singapore language and region"
```

---

### 任务 6：支持英文和简体中文权限 UI

**文件：**
- 修改：`.github/workflows/apple.sh:151-233,346-1267`
- 修改：`tests/test_uuremote_host_bootstrap.py`

**接口：**
- 输入：现有 `run_permission` kind 和接受的 UU Remote display name。
- 输出：双语 title 列表和 requester `com.netease.uuremote.agent` 的结构匹配。

- [ ] **步骤 1：添加失败的双语测试**

要求配对 `Accessibility`/`辅助功能`、`Screen & System Audio Recording`/`录屏与系统录音`、`Allow`/`允许` 和 `Open System Settings`/`打开系统设置`。

要求 `allowButton`、`openSettingsButton` 和 `com.netease.uuremote.agent`；禁止旧的 `contextText contains "private window picker"` 依赖。提取所有 `run_permission` 调用，并要求精确包含 `accessibility-main`、`screen-capture` 和 `agent-private-picker`。

- [ ] **步骤 2：运行并观察失败**

运行 bilingual-permission 测试 class。预期：中文词汇和结构化 picker 检查失败，同时完整英文短语仍存在。

- [ ] **步骤 3：将权限 title 转换为接受的精确列表**

更改 `ensurePermission` 以接收 `permissionWindowTitles`，并且只在页面 AX title 精确匹配其中一个值时接受页面。传递以下列表：

```applescript
{"Accessibility", "辅助功能"}
{"Screen & System Audio Recording", "录屏与系统录音"}
```

仅在当前算法已经验证 AX role 和 layout 的位置扩展 Password、Open 和 Quit & Reopen 的精确本地化值。本地化不得扩大控件选择范围。

- [ ] **步骤 4：缩窄两个 private-picker handler 并使其双语化**

在 snapshot-time handler 和嵌入式权限 AppleScript 中：

1. 要求对话框 context 中有精确 requester 文本 `com.netease.uuremote.agent`。
2. 仅当 title 或 description 精确为 `Allow` 或 `允许` 时捕获 `allowButton`。
3. 仅当 title 或 description 精确为 `Open System Settings` 或 `打开系统设置` 时捕获 `openSettingsButton`。
4. 仅当两个按钮都存在时匹配。
5. 只按下 `allowButton`。
6. 移除完整英文说明短语依赖。

如果 requester 匹配，但任一结构化操作不存在，则发出诊断并在不点击的情况下失败。

- [ ] **步骤 5：验证并提交**

运行 Bash 语法检查、所有 Python 测试、codec self-test 和 `git diff --check`。然后：

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: support bilingual UU Remote permissions"
```

---

### 任务 7：运行 macOS 集成并重跑验证

**文件：**
- 修改：`.github/workflows/macos.yml`，仅限有证据支持的集成修正。
- 修改：`.github/workflows/apple.sh`，仅限有证据支持的集成修正。
- 测试：GitHub Actions workflow `macOS`。

**接口：**
- 输入：`account_password=john.doe`、`debug_level=0`、`wait_connections_seconds=0`。
- 输出：一次成功的 Actions run，证明无需 reboot 或 logout 即可完成 bootstrap、权限和 client 控制。

- [ ] **步骤 1：运行完整 preflight**

分别运行以下命令：`git status --short`、`/bin/bash -n .github/workflows/apple.sh`、`python3 -m unittest tests/test_uuremote_host_bootstrap.py -v` 和 `git diff --check`。

预期：只更改预期文件，并且每项检查均通过。

- [ ] **步骤 2：推送并分派 workflow**

使用 `account_password=john.doe`、`debug_level=0` 和 `wait_connections_seconds=0` 分派 `macOS`。使用已登录的 GitHub 表单或已屏蔽的 API 机制；不得将密码放入会回显的命令。

- [ ] **步骤 3：要求非 secret 的 bootstrap 证据**

日志必须确认以下全部内容：

```text
console account password verified
console login keychain verified
/etc/kcpassword verified
root password hash verified
root remains disabled
language order verified
Singapore locale and region verified
```

它还必须报告 `root login keychain verified` 或 `No root login keychain exists; leaving it absent`。确认 GUI 会话保持存在，并且没有发生重启或注销。

- [ ] **步骤 4：验证 UU Remote 行为**

确认无人值守访问成功，Accessibility 和 Screen & System Audio Recording 持久化，private-picker 提示仅针对 `com.netease.uuremote.agent` 被接受，并且 mobile client 可以查看和控制 runner。

- [ ] **步骤 5：验证主机幂等性**

在保留的目标上，屏蔽该值并再次运行 `apple.sh configure-host`。在 ephemeral runner 上，在同一次诊断 run 中添加临时的第二次调用，并在捕获证据后移除。要求 user password、user keychain、kcpassword、root keychain、语言、locale 和地区均出现跳过结果；root 必须保持禁用，并且必须跳过提示扫描。

- [ ] **步骤 6：仅应用有证据支持的修复**

对于每个 runtime 失败，保留精确的非 secret 诊断和状态，首先添加失败的 regression assertion，实施最小修正，重跑完整 preflight，然后再次分派。

- [ ] **步骤 7：如有需要，提交最终修正**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_host_bootstrap.py
git commit -m "fix: validate macOS host bootstrap integration"
git push origin main
```

如果没有最终修正，则跳过该 commit。绝不创建空 commit。

- [ ] **步骤 8：记录最终证据**

报告最终 commit hash、成功的 Actions run URL、非 secret 输入值、测试结果、root-disabled 确认、有效第一语言（`zh-Hans-SG` 或 fallback `zh-Hans-CN`），以及 root keychain 是已更新还是正确保持不存在。
