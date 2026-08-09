#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"
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

echo "=== Opening Screen & System Audio Recording ==="

run_in_gui /usr/bin/open -a "System Settings"
sleep 1
run_in_gui /usr/bin/open "$PREF_URL"
sleep 3

echo "=== UI elements in right/lower content area ==="

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
        error "System Settings window not found after 15 seconds"
    end if

    tell application process "System Settings"
        set outputLines to {}
        set allItems to entire contents of window 1

        set end of outputLines to "WINDOW=[" & (name of window 1 as text) & "]"
        set end of outputLines to "TOTAL ELEMENTS=" & (count of allItems)
        set elementNumber to 0

        repeat with uiItem in allItems
            try
                set itemPosition to position of uiItem
                set itemX to item 1 of itemPosition
                set itemY to item 2 of itemPosition

                -- 窗口位于 150,57，右侧内容区域大约从 x=370 开始。
                -- 输出右侧且 y>=300 的所有控件，包含列表和底部工具区。
                if itemX is greater than or equal to 370 and itemY is greater than or equal to 300 then
                    set elementNumber to elementNumber + 1

                    set itemSize to size of uiItem
                    set itemWidth to item 1 of itemSize
                    set itemHeight to item 2 of itemSize

                    set itemRole to my attributeText(uiItem, "AXRole")
                    set itemSubrole to my attributeText(uiItem, "AXSubrole")
                    set itemTitle to my attributeText(uiItem, "AXTitle")
                    set itemDescription to my attributeText(uiItem, "AXDescription")
                    set itemHelp to my attributeText(uiItem, "AXHelp")
                    set itemIdentifier to my attributeText(uiItem, "AXIdentifier")
                    set itemRoleDescription to my attributeText(uiItem, "AXRoleDescription")
                    set itemValue to my attributeText(uiItem, "AXValue")
                    set itemEnabled to my attributeText(uiItem, "AXEnabled")

                    set itemLine to "#" & elementNumber
                    set itemLine to itemLine & " role=[" & itemRole & "]"
                    set itemLine to itemLine & " subrole=[" & itemSubrole & "]"
                    set itemLine to itemLine & " position=" & itemX & "," & itemY
                    set itemLine to itemLine & " size=" & itemWidth & "x" & itemHeight
                    set itemLine to itemLine & " enabled=[" & itemEnabled & "]"
                    set itemLine to itemLine & " title=[" & itemTitle & "]"
                    set itemLine to itemLine & " description=[" & itemDescription & "]"
                    set itemLine to itemLine & " help=[" & itemHelp & "]"
                    set itemLine to itemLine & " identifier=[" & itemIdentifier & "]"
                    set itemLine to itemLine & " roleDescription=[" & itemRoleDescription & "]"
                    set itemLine to itemLine & " value=[" & itemValue & "]"

                    set end of outputLines to itemLine
                end if
            end try
        end repeat

        set end of outputLines to "FILTERED ELEMENT COUNT=" & elementNumber

        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to previousDelimiters

        return outputText
    end tell
end tell
APPLESCRIPT

echo
echo "=== UU processes ==="

/bin/ps -axo user=,pid=,command= |
    /usr/bin/grep -E '[U]URemote|[u]uyc' ||
    true

echo
echo "=== CLI status ==="

if [ -x "$CLI" ]; then
    run_in_gui "$CLI" status || true
else
    echo "CLI not found: $CLI"
fi

check_binary() {
    binary="$1"

    echo
    echo "=== Binary: $binary ==="

    if [ ! -f "$binary" ]; then
        echo "NOT FOUND"
        return
    fi

    /bin/ls -l "$binary"

    echo "--- Imported permission/capture symbols ---"

    if /usr/bin/nm -u "$binary" 2>/dev/null |
        /usr/bin/grep -E \
        'CG(Request|Preflight)ScreenCaptureAccess|ScreenCaptureKit|SCShareableContent|SCScreenshotManager|CGDisplayStream'
    then
        :
    else
        echo "No matching imported symbols reported by nm"
    fi

    echo "--- Relevant embedded strings ---"

    /usr/bin/strings -a "$binary" 2>/dev/null |
        /usr/bin/grep -E \
        'CGRequestScreenCaptureAccess|CGPreflightScreenCaptureAccess|ScreenCapture|AudioCapture|Accessibility|PermissionCategory|request.*permission|permission.*request' |
        /usr/bin/head -n 80 ||
        true
}

check_binary "$APP/Contents/MacOS/UURemote"
check_binary "$APP/Contents/MacOS/UURemoteService"
check_binary "$APP/Contents/MacOS/UURemoteDaemon"
check_binary "$APP/Contents/XPCServices/UURemoteHelper.xpc/Contents/MacOS/UURemoteHelper"
check_binary "$APP/Contents/Helpers/UURemoteUpdater.app/Contents/XPCServices/UURemoteHelper.xpc/Contents/MacOS/UURemoteHelper"

echo
echo "=== Recent TCC records ==="

sudo /usr/bin/log show \
    --last 30m \
    --style compact \
    --info \
    --debug \
    --predicate 'subsystem == "com.apple.TCC"' |
    /usr/bin/grep -Ei \
    'UURemote|UURemoteHelper|com\.netease\.uuremote|ScreenCapture|AudioCapture|AttributionChain|deny|request' |
    /usr/bin/tail -n 200 ||
    true
