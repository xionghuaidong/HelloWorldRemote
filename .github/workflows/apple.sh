#!/bin/bash
set -euo pipefail

PREF_URL='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
console_uid="$(stat -f '%u' /dev/console)"

echo "=== macOS ==="
/usr/bin/sw_vers

echo "=== Console session ==="
echo "UID: $console_uid"

if ! sudo launchctl print "gui/$console_uid" >/dev/null 2>&1; then
    echo "图形桌面会话 gui/$console_uid 不存在" >&2
    exit 1
fi

run_in_gui() {
    sudo launchctl asuser "$console_uid" \
        sudo -u "#$console_uid" \
        "$@"
}

echo "=== Opening System Settings ==="

# 先确保 System Settings 进程启动
run_in_gui /usr/bin/open -a "System Settings"

sleep 1

# 再导航到录屏权限页面
run_in_gui /usr/bin/open "$PREF_URL"

sleep 2

echo "=== Inspecting buttons ==="

run_in_gui /usr/bin/osascript <<'APPLESCRIPT'
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

tell application "System Events"
    set settingsReady to false

    -- 最多等待 15 秒
    repeat 60 times
        if exists application process "System Settings" then
            tell application process "System Settings"
                if exists window 1 then
                    set settingsReady to true
                    exit repeat
                end if
            end tell
        end if

        delay 0.25
    end repeat

    if settingsReady is false then
        set runningProcesses to name of every application process
        error "等待 15 秒后仍未找到 System Settings 窗口。当前 GUI 进程：" & (runningProcesses as text)
    end if

    tell application process "System Settings"
        set outputLines to {}

        set windowTitle to ""
        set windowPositionText to ""
        set windowSizeText to ""

        try
            set windowTitle to name of window 1 as text
        end try

        try
            set windowPosition to position of window 1
            set windowPositionText to ¬
                (item 1 of windowPosition as text) & "," & ¬
                (item 2 of windowPosition as text)
        end try

        try
            set windowSize to size of window 1
            set windowSizeText to ¬
                (item 1 of windowSize as text) & "x" & ¬
                (item 2 of windowSize as text)
        end try

        set end of outputLines to "WINDOW title=[" & windowTitle & "] position=" & windowPositionText & " size=" & windowSizeText

        set allItems to entire contents of window 1
        set end of outputLines to "TOTAL ELEMENTS=" & (count of allItems)

        set buttonNumber to 0

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXButton" then
                    set buttonNumber to buttonNumber + 1

                    set itemX to ""
                    set itemY to ""
                    set itemWidth to ""
                    set itemHeight to ""

                    try
                        set itemPosition to position of uiItem
                        set itemX to item 1 of itemPosition as text
                        set itemY to item 2 of itemPosition as text
                    end try

                    try
                        set itemSize to size of uiItem
                        set itemWidth to item 1 of itemSize as text
                        set itemHeight to item 2 of itemSize as text
                    end try

                    set parentRole to ""
                    set parentDescription to ""
                    set parentX to ""
                    set parentY to ""
                    set parentWidth to ""
                    set parentHeight to ""

                    try
                        set parentItem to parent of uiItem
                        set parentRole to role of parentItem as text
                        set parentDescription to my attributeText(parentItem, "AXDescription")

                        try
                            set parentPosition to position of parentItem
                            set parentX to item 1 of parentPosition as text
                            set parentY to item 2 of parentPosition as text
                        end try

                        try
                            set parentSize to size of parentItem
                            set parentWidth to item 1 of parentSize as text
                            set parentHeight to item 2 of parentSize as text
                        end try
                    end try

                    set itemLine to "#" & buttonNumber
                    set itemLine to itemLine & " position=" & itemX & "," & itemY
                    set itemLine to itemLine & " size=" & itemWidth & "x" & itemHeight
                    set itemLine to itemLine & " enabled=[" & my attributeText(uiItem, "AXEnabled") & "]"
                    set itemLine to itemLine & " title=[" & my attributeText(uiItem, "AXTitle") & "]"
                    set itemLine to itemLine & " description=[" & my attributeText(uiItem, "AXDescription") & "]"
                    set itemLine to itemLine & " help=[" & my attributeText(uiItem, "AXHelp") & "]"
                    set itemLine to itemLine & " identifier=[" & my attributeText(uiItem, "AXIdentifier") & "]"
                    set itemLine to itemLine & " subrole=[" & my attributeText(uiItem, "AXSubrole") & "]"
                    set itemLine to itemLine & " roleDescription=[" & my attributeText(uiItem, "AXRoleDescription") & "]"
                    set itemLine to itemLine & " parentRole=[" & parentRole & "]"
                    set itemLine to itemLine & " parentDescription=[" & parentDescription & "]"
                    set itemLine to itemLine & " parentPosition=" & parentX & "," & parentY
                    set itemLine to itemLine & " parentSize=" & parentWidth & "x" & parentHeight

                    set end of outputLines to itemLine
                end if
            end try
        end repeat

        set end of outputLines to "BUTTON COUNT=" & buttonNumber

        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to previousDelimiters

        return outputText
    end tell
end tell
APPLESCRIPT
