#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"
PREF_URL='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
EXTENSION_PROCESS="SecurityPrivacyExtension"

console_uid="$(stat -f '%u' /dev/console)"

echo "=== Environment ==="
/usr/bin/sw_vers
echo "Console UID: $console_uid"

if [ ! -d "$APP" ]; then
    echo "UURemote 不存在：$APP" >&2
    exit 1
fi

if ! sudo launchctl print "gui/$console_uid" >/dev/null 2>&1; then
    echo "图形桌面会话 gui/$console_uid 不存在" >&2
    exit 1
fi

run_in_gui() {
    sudo launchctl asuser "$console_uid" \
        sudo -u "#$console_uid" \
        "$@"
}

echo "=== Opening permission page ==="

run_in_gui /usr/bin/open -a "System Settings"
sleep 1
run_in_gui /usr/bin/open "$PREF_URL"
sleep 4

echo "=== Adding UURemote and enabling permission ==="

run_in_gui /usr/bin/osascript <<'APPLESCRIPT'
property extensionProcessName : "SecurityPrivacyExtension"
property targetApplicationPath : "/Applications/UURemote.app"

on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem

            if attributeValue is not missing value then
                return attributeValue as text
            end if
        end try
    end tell

    return ""
end attributeText

on controlText(uiItem)
    set combinedText to ""
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXTitle")
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXDescription")
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXHelp")
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXIdentifier")
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXRoleDescription")
    set combinedText to combinedText & " " & my attributeText(uiItem, "AXValue")
    return combinedText
end controlText

on isSwitchControl(uiItem)
    tell application "System Events"
        try
            set itemRole to role of uiItem as text

            if itemRole is "AXCheckBox" or itemRole is "AXSwitch" then
                return true
            end if

            if itemRole is "AXButton" then
                set itemText to my controlText(uiItem)

                if itemText contains "switch" or itemText contains "Switch" then
                    return true
                end if
            end if
        end try
    end tell

    return false
end isSwitchControl

on switchIsEnabled(uiItem)
    tell application "System Events"
        try
            set itemValue to value of uiItem

            if itemValue is true then return true
            if itemValue is 1 then return true
            if (itemValue as text) is "1" then return true
            if (itemValue as text) is "true" then return true
        end try
    end tell

    return false
end switchIsEnabled

on getSwitches(extensionProcess)
    tell application "System Events"
        set switchControls to {}
        set allItems to entire contents of extensionProcess

        repeat with uiItem in allItems
            if my isSwitchControl(uiItem) then
                set end of switchControls to contents of uiItem
            end if
        end repeat

        return switchControls
    end tell
end getSwitches

on getAddControls(extensionProcess)
    tell application "System Events"
        set addControls to {}
        set allItems to entire contents of extensionProcess

        repeat with uiItem in allItems
            try
                set itemRole to role of uiItem as text

                if itemRole is "AXButton" or itemRole is "AXMenuButton" or itemRole is "AXPopUpButton" then
                    set itemText to my controlText(uiItem)

                    if itemText contains "Add" or itemText contains "add" or itemText contains "+" then
                        set end of addControls to contents of uiItem
                    end if
                end if
            end try
        end repeat

        return addControls
    end tell
end getAddControls

on diagnosticControls(extensionProcess)
    tell application "System Events"
        set diagnosticLines to {}
        set diagnosticProcessName to name of extensionProcess as text
        set diagnosticWindows to windows of extensionProcess
        set diagnosticWindowCount to count of diagnosticWindows
        set allItems to entire contents of extensionProcess
        set diagnosticItemCount to count of allItems
        set lineCount to 0

        set end of diagnosticLines to "PROCESS=[" & diagnosticProcessName & "] WINDOWS=" & diagnosticWindowCount & " ELEMENTS=" & diagnosticItemCount

        repeat with uiItem in allItems
            try
                set itemRole to role of uiItem as text
                set itemSubrole to my attributeText(uiItem, "AXSubrole")
                set itemActionsText to ""

                try
                    set diagnosticActionNames to name of every action of uiItem
                    set savedDelimiters to AppleScript's text item delimiters
                    set AppleScript's text item delimiters to ","
                    set itemActionsText to diagnosticActionNames as text
                    set AppleScript's text item delimiters to savedDelimiters
                end try

                if itemRole is not "" then
                    set itemPositionText to ""
                    set itemSizeText to ""

                    try
                        set itemPosition to position of uiItem
                        set itemPositionText to (item 1 of itemPosition as text) & "," & (item 2 of itemPosition as text)
                    end try

                    try
                        set itemSize to size of uiItem
                        set itemSizeText to (item 1 of itemSize as text) & "x" & (item 2 of itemSize as text)
                    end try

                    set end of diagnosticLines to itemRole & " subrole=[" & itemSubrole & "] position=" & itemPositionText & " size=" & itemSizeText & " actions=[" & itemActionsText & "] text=[" & my controlText(uiItem) & "]"
                    set lineCount to lineCount + 1

                    if lineCount is greater than or equal to 160 then
                        exit repeat
                    end if
                end if
            end try
        end repeat

        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set outputText to diagnosticLines as text
        set AppleScript's text item delimiters to previousDelimiters

        return outputText
    end tell
end diagnosticControls

tell application "System Events"
    set extensionReady to false

    -- 等待权限设置扩展进程启动
    repeat 80 times
        if exists application process extensionProcessName then
            set extensionReady to true
            exit repeat
        end if

        delay 0.25
    end repeat

    if extensionReady is false then
        set processNames to name of every application process
        error "等待 20 秒后仍未找到 " & extensionProcessName & "。GUI 进程：" & (processNames as text)
    end if

    set extensionProcess to application process extensionProcessName
    set existingSwitches to my getSwitches(extensionProcess)
    set existingSwitchCount to count of existingSwitches

    if existingSwitchCount is greater than 1 then
        error "权限页面当前已有 " & existingSwitchCount & " 个开关，为避免误操作已停止。" & linefeed & my diagnosticControls(extensionProcess)
    end if

    -- 列表为空时添加 UURemote.app
    if existingSwitchCount is 0 then
        set addControls to my getAddControls(extensionProcess)
        set addCount to count of addControls

        if addCount is 0 then
            set extensionDiagnostics to my diagnosticControls(extensionProcess)
            set settingsDiagnostics to "System Settings process not found"

            if exists application process "System Settings" then
                set settingsProcess to application process "System Settings"
                set settingsDiagnostics to my diagnosticControls(settingsProcess)
            end if

            error "在 SecurityPrivacyExtension 中仍找不到 Add 控件。" & linefeed & extensionDiagnostics & linefeed & settingsDiagnostics
        end if

        if addCount is not 1 then
            error "找到 " & addCount & " 个 Add 控件，为避免误操作已停止。" & linefeed & my diagnosticControls(extensionProcess)
        end if

        perform action "AXPress" of item 1 of addControls
        delay 2

        -- 标准文件选择器：前往指定路径
        keystroke "g" using {command down, shift down}
        delay 1

        keystroke targetApplicationPath
        delay 1

        -- 确认路径
        key code 36
        delay 2

        -- 点击 Open
        key code 36
        delay 4
    end if

    -- 添加过程中扩展进程可能重载，因此重新取得对象
    set switchControls to {}

    repeat 40 times
        if exists application process extensionProcessName then
            set extensionProcess to application process extensionProcessName
            set switchControls to my getSwitches(extensionProcess)

            if (count of switchControls) is greater than 0 then
                exit repeat
            end if
        end if

        delay 0.5
    end repeat

    set switchCount to count of switchControls

    if switchCount is 0 then
        error "选择 UURemote.app 后仍未出现权限开关。" & linefeed & my diagnosticControls(extensionProcess)
    end if

    if switchCount is not 1 then
        error "添加后出现 " & switchCount & " 个权限开关，为避免误操作已停止。" & linefeed & my diagnosticControls(extensionProcess)
    end if

    set targetSwitch to item 1 of switchControls

    -- 避免系统弹出 Quit & Reopen 对话框
    do shell script "/usr/bin/killall UURemote >/dev/null 2>&1 || true"
    delay 1

    if my switchIsEnabled(targetSwitch) then
        return "UURemote 已在权限列表中，录屏权限已经开启"
    end if

    perform action "AXPress" of targetSwitch
    delay 3

    if my switchIsEnabled(targetSwitch) then
        return "UURemote 录屏权限已成功开启"
    end if

    error "已经点击 UURemote 权限开关，但状态仍未开启，可能出现了认证窗口"
end tell
APPLESCRIPT

echo "=== Restarting UURemote ==="

sleep 2
run_in_gui /usr/bin/open "$APP"

echo "=== Waiting for CLI ==="

for ((i=1; i<=40; i++)); do
    if cli_status="$(run_in_gui "$CLI" status 2>/dev/null)"; then
        if printf '%s' "$cli_status" |
            /usr/bin/grep -q '"success" : true'
        then
            printf '%s\n' "$cli_status"
            echo "UURemote 已重新启动"
            exit 0
        fi
    fi

    sleep 0.5
done

echo "UURemote 已启动，但 CLI 在 20 秒内没有恢复" >&2
exit 1
