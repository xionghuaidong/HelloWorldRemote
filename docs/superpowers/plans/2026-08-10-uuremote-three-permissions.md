# UU远程 macOS 三项被控权限 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `apple.sh` 独立完成“允许本设备被控”、辅助功能、录屏与系统录音，并在 GitHub Actions 同一 runner 上验证首次执行和幂等执行均成功。

**Architecture:** Shell 层负责启动 UU远程、CLI 重试和最终状态验证；嵌入式 AppleScript 提供一个参数化权限处理器，依次处理 Accessibility 与 Screen Capture。workflow 只负责安装、调用两次脚本、上传诊断截图和成功后的保活。

**Tech Stack:** Bash、AppleScript/System Events、UU远程 CLI、GitHub Actions、`actions/upload-artifact@v4`、macOS 26 System Settings。

## Global Constraints

- 目标应用固定为 `/Applications/UURemote.app`，CLI 固定为 `/Applications/UURemote.app/Contents/Helpers/uuyc-cli`。
- 系统权限页面为 `Privacy_Accessibility` 和 `Privacy_ScreenCapture`。
- 不直接修改 TCC 数据库、AuthorizationDB，不关闭 SIP。
- 管理员密码从 `/etc/kcpassword` 解码，提交前必须通过 `dscl -authonly`，不得写入日志。
- GUI 操作必须通过 `/dev/console` 对应 UID 的 `launchctl asuser` 会话执行。
- 只修改 `.github/workflows/apple.sh` 和 `.github/workflows/macos.yml`；诊断文件只写入 `${RUNNER_TEMP}`。

---

### Task 1: 将“允许本设备被控”收拢到 apple.sh

**Files:**
- Modify: `.github/workflows/apple.sh`
- Modify: `.github/workflows/macos.yml`

**Interfaces:**
- Consumes: `run_in_gui()`、`CLI`、当前图形桌面 UID。
- Produces: Bash 函数 `wait_for_cli()` 和 `ensure_assist_allowed()`；后续权限处理可假定 UU远程进程和 CLI 已就绪。

- [ ] **Step 1: 记录当前失败基线**

运行：

```bash
grep -n "assist allow on" .github/workflows/apple.sh
grep -n "assist allow on" .github/workflows/macos.yml
```

预期：第一条没有匹配，第二条显示设置逻辑仍散落在 workflow，证明 `apple.sh` 不能独立完成三项设置。

- [ ] **Step 2: 在 apple.sh 增加 CLI 就绪和允许被控函数**

在 `run_in_gui()` 后增加以下接口，调用者通过返回码判断成功：

```bash
wait_for_cli() {
    local output
    local attempt

    for ((attempt=1; attempt<=40; attempt++)); do
        if output="$(run_in_gui "$CLI" status 2>/dev/null)" &&
            printf '%s' "$output" | /usr/bin/grep -q '"success" : true'
        then
            printf '%s\n' "$output"
            return 0
        fi
        sleep 0.5
    done

    return 1
}

ensure_assist_allowed() {
    local output
    local attempt

    for ((attempt=1; attempt<=120; attempt++)); do
        if output="$(run_in_gui "$CLI" assist allow on 2>/dev/null)" &&
            printf '%s' "$output" | /usr/bin/grep -q '"enabled" : true'
        then
            printf '%s\n' "$output"
            return 0
        fi
        sleep 0.5
    done

    return 1
}
```

启动 UU远程后先调用 `wait_for_cli`，再调用 `ensure_assist_allowed`；任一失败都输出不含敏感值的明确错误并退出 1。

- [ ] **Step 3: 删除 workflow 中重复的 allow 循环**

从 `.github/workflows/macos.yml` 的 `Launch GameViewer` 中删除整个 `Waiting allow` 循环，保留设备 ID、验证码设置和 `.github/workflows/apple.sh` 调用。

- [ ] **Step 4: 运行静态验证**

运行：

```bash
bash -n .github/workflows/apple.sh
git diff --check
test "$(grep -R -l "assist allow on" .github/workflows/apple.sh .github/workflows/macos.yml | wc -l | tr -d ' ')" = "1"
```

预期：全部退出 0，且 `assist allow on` 只存在于 `apple.sh`。

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml
git commit -m "centralize uuremote unattended access"
```

---

### Task 2: 抽取可复用的系统权限处理器

**Files:**
- Modify: `.github/workflows/apple.sh`

**Interfaces:**
- Consumes: `authorizationPassword`、`screenshotDirectory`、`settingsProcessName`、`targetApplicationPath` 和现有 UI 辅助函数。
- Produces: AppleScript 处理器 `ensurePermission(permissionURL, permissionWindowTitle, permissionLabel, screenshotPrefix, authorizationPassword, screenshotDirectory)`，成功返回文本结果，失败抛出包含 `permissionLabel` 的错误。

- [ ] **Step 1: 用当前 workflow 记录辅助功能失败基线**

运行现有 `macOS` workflow，并在手机客户端连接后尝试键鼠控制。

预期：录屏可用，但客户端提示“该设备未开启辅助设备系统权限”，证明 Accessibility 尚未处理。

- [ ] **Step 2: 把单权限主流程移动到 ensurePermission**

将当前 AppleScript `on run argv` 中从打开页面、等待窗口、查找 outline、添加应用、处理管理员认证、状态驱动确认 Go to Folder、处理 `Quit & Reopen`、定位并确认开关的逻辑移动到：

```applescript
on ensurePermission(permissionURL, permissionWindowTitle, permissionLabel, screenshotPrefix, authorizationPassword, screenshotDirectory)
    -- 打开 permissionURL。
    -- 等待 window 1 的 AXTitle 等于 permissionWindowTitle。
    -- 查找目标行；已开启时直接返回。
    -- 不存在时添加 UURemote.app 并处理认证/文件选择/重启提示。
    -- 最终重新定位目标行并确认开关值为 true。
end ensurePermission
```

所有原本写死 `Screen & System Audio Recording` 的进度与错误文本改用 `permissionLabel`；截图文件名使用 `screenshotPrefix`，避免两项权限互相覆盖。

- [ ] **Step 3: 让 on run 依次处理两项权限**

`on run argv` 保留参数校验，然后严格按以下顺序调用：

```applescript
my ensurePermission(¬
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", ¬
    "Accessibility", ¬
    "Accessibility", ¬
    "accessibility", ¬
    authorizationPassword, ¬
    screenshotDirectory)

my ensurePermission(¬
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", ¬
    "Screen & System Audio Recording", ¬
    "Screen & System Audio Recording", ¬
    "screen-capture", ¬
    authorizationPassword, ¬
    screenshotDirectory)
```

权限处理器不得在单项完成后重启应用；两项全部成功后由 Bash 统一停止、打开 UU远程并调用 `wait_for_cli`。

- [ ] **Step 4: 使行和按钮搜索不依赖权限页面名称**

保留以下通用规则：

- 权限列表是当前窗口中第一个宽度至少 300、高度至少 40 的 `AXOutline`。
- 加号是该 outline 左下方 25 像素范围内、尺寸 8–20 像素的方形 `AXButton`。
- 应用名称匹配 `UU远程`、`UURemote`、`UU Remote`、`网易UU远程`、`网易 UU 远程`。
- 首次添加通过添加前后标题差集寻找新行。
- 文件选择器 Return 次数由 `AXFocusedUIElement` 是否仍为 `AXTextField` 决定，最多 6 次。

- [ ] **Step 5: 加入权限级截图和错误信息**

每项权限生成：

```text
${RUNNER_TEMP}/uuremote-permission-screenshots/
  uuremote-permission-accessibility-file-chooser-ready.jpg
  uuremote-permission-accessibility-file-chooser-selected.jpg
  uuremote-permission-screen-capture-file-chooser-ready.jpg
  uuremote-permission-screen-capture-file-chooser-selected.jpg
```

任一超时错误必须包含 `Accessibility` 或 `Screen & System Audio Recording`，使 Actions 日志能定位具体失败页面。

- [ ] **Step 6: 运行语法和差异检查**

运行：

```bash
bash -n .github/workflows/apple.sh
git diff --check
grep -n "Privacy_Accessibility" .github/workflows/apple.sh
grep -n "Privacy_ScreenCapture" .github/workflows/apple.sh
grep -n "on ensurePermission" .github/workflows/apple.sh
```

预期：命令全部成功，两项 URL 和复用处理器各有明确匹配。

- [ ] **Step 7: 提交**

```bash
git add .github/workflows/apple.sh
git commit -m "enable uuremote macos privacy permissions"
```

---

### Task 3: GitHub Actions 首次执行、幂等和远程控制验收

**Files:**
- Modify: `.github/workflows/macos.yml`（仅在现有验证步骤需要调整时）

**Interfaces:**
- Consumes: Task 1 的完整 CLI 设置和 Task 2 的 `ensurePermission(...)`。
- Produces: 一次可复核的 workflow 成功运行、截图 artifact，以及手机客户端画面和键鼠均可用的验收结果。

- [ ] **Step 1: 校验 workflow 结构**

确认步骤顺序为：

```text
Install GameViewer
Launch GameViewer
Verify permission idempotency
Upload permission screenshots (if: always())
Keep runner alive (if: success())
```

运行：

```bash
git diff --check
grep -n "Verify permission idempotency\|Upload permission screenshots\|Keep runner alive" .github/workflows/macos.yml
```

- [ ] **Step 2: 推送并启动 macOS workflow**

```bash
git push
```

在已登录 GitHub 的 Actions 页面触发 `macOS` workflow。一次只运行一个 workflow，避免多个 GUI 自动化任务竞争 runner。

- [ ] **Step 3: 验证首次执行日志**

`Launch GameViewer` 必须包含以下证据并以退出码 0 完成：

```text
enabled : true
Accessibility ... enabled/already enabled
Screen & System Audio Recording ... enabled/already enabled
UURemote restarted successfully
```

若失败，先下载 `uuremote-permission-screenshots` artifact，根据具体权限页面截图修复；不得绕过失败继续保活。

- [ ] **Step 4: 验证同机第二次执行**

`Verify permission idempotency` 必须以退出码 0 完成，日志同时表明：

```text
Accessibility permission is already enabled
Screen & System Audio Recording permission is already enabled
enabled : true
```

不得出现再次添加应用、再次要求管理员密码或关闭任何开关。

- [ ] **Step 5: 验证 artifact 和手机客户端**

确认 `Upload permission screenshots` 成功并能下载 JPEG。进入 `Keep runner alive` 后，用手机客户端验证：

1. 可以看到 macOS 画面。
2. 可以移动鼠标并点击。
3. 可以向被控端输入键盘字符。
4. 客户端不再显示录屏或辅助设备权限缺失提示。

- [ ] **Step 6: 最终仓库验证**

```bash
bash -n .github/workflows/apple.sh
git diff --check
git status --short
git log -3 --oneline
```

预期：脚本语法通过、工作区干净，最新提交对应三项权限实现和验证。
