#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"
mode="${1:-configure}"
debug_level="${UUREMOTE_DEBUG:-0}"
evidence_dir="${RUNNER_TEMP:-/tmp}/uuremote-permission-screenshots"
diagnostic_log="$evidence_dir/diagnostics.log"

case "$debug_level" in
    0|1|2|3)
        ;;
    *)
        echo "Invalid UUREMOTE_DEBUG level: $debug_level (expected 0, 1, 2, or 3)" >&2
        exit 2
        ;;
esac

console_uid="$(stat -f '%u' /dev/console)"
console_user="$(stat -f '%Su' /dev/console)"

echo "=== Environment ==="
/usr/bin/sw_vers
echo "Console UID: $console_uid"
echo "Console user: $console_user"

if [ ! -d "$APP" ]; then
    echo "UURemote does not exist: $APP" >&2
    exit 1
fi

if ! sudo launchctl print "gui/$console_uid" >/dev/null 2>&1; then
    echo "GUI session gui/$console_uid does not exist" >&2
    exit 1
fi

run_in_gui() {
    sudo launchctl asuser "$console_uid" \
        sudo -u "#$console_uid" \
        "$@"
}

debug_sleep() {
    local diagnostic_seconds="$1"
    local fast_seconds="$2"

    if [ "$debug_level" -ge 1 ]; then
        sleep "$diagnostic_seconds"
    elif [ "$fast_seconds" != "0" ]; then
        sleep "$fast_seconds"
    fi
}

capture_tcc_database() {
    local database_path="$1"
    local database_label="$2"
    local query

    query="SELECT service, client, client_type, auth_value, auth_reason, flags, last_modified FROM access WHERE service LIKE '%Accessibility%' OR service LIKE '%ScreenCapture%' OR service LIKE '%ListenEvent%' OR service LIKE '%PostEvent%' ORDER BY service, client;"

    echo "--- TCC $database_label: $database_path ---"

    if [ ! -e "$database_path" ]; then
        echo "TCC database unavailable: file does not exist"
        return 0
    fi

    if [ "$database_label" = "system" ]; then
        if ! sudo /usr/bin/sqlite3 -header -tabs "$database_path" "$query"; then
            echo "TCC database unavailable: query failed"
        fi
    elif ! /usr/bin/sqlite3 -header -tabs "$database_path" "$query"; then
        echo "TCC database unavailable: query failed"
    fi
}

capture_snapshot() {
    local requested_label="${1:-manual}"
    local safe_label
    local timestamp
    local png_path
    local jpeg_path
    local user_tcc_database
    local executable

    if [ "$debug_level" -eq 0 ]; then
        echo "Snapshot skipped because UUREMOTE_DEBUG=0"
        return 0
    fi

    safe_label="$(printf '%s' "$requested_label" | /usr/bin/tr -cd 'A-Za-z0-9._-')"
    if [ -z "$safe_label" ]; then
        safe_label="manual"
    fi

    timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    /bin/mkdir -p "$evidence_dir"
    png_path="$evidence_dir/${safe_label}-${timestamp}.png"
    jpeg_path="$evidence_dir/${safe_label}-${timestamp}.jpg"
    user_tcc_database="/Users/$console_user/Library/Application Support/com.apple.TCC/TCC.db"

    case "$safe_label" in
        live-*|final-app*)
            run_in_gui /usr/bin/open "$APP"
            debug_sleep 1 0
            ;;
    esac

    {
        echo
        echo "========== SNAPSHOT $safe_label $timestamp =========="
        echo "--- UU processes ---"
        /bin/ps -axo pid=,ppid=,uid=,user=,comm=,args= | /usr/bin/grep -Ei '[U]URemote|[u]uyc-cli' || echo "No UU process matched"

        echo "--- Code signing ---"
        for executable in \
            "$APP/Contents/MacOS/UURemote" \
            "$APP/Contents/MacOS/UURemoteService" \
            "$APP/Contents/MacOS/UURemoteDaemon" \
            "$APP/Contents/Helpers/UURemoteServer"
        do
            echo "executable=$executable"
            if [ -e "$executable" ]; then
                /usr/bin/codesign -dv --verbose=4 "$executable" 2>&1 | /usr/bin/grep -E '^(Identifier|TeamIdentifier|CodeDirectory)=' || true
                /usr/bin/codesign -dr - "$executable" 2>&1 || true
            else
                echo "missing"
            fi
        done

        capture_tcc_database "$user_tcc_database" "user"
        capture_tcc_database "/Library/Application Support/com.apple.TCC/TCC.db" "system"

        echo "--- CLI status ---"
        run_in_gui "$CLI" status 2>&1 || true
        echo "--- Assist ID ---"
        run_in_gui "$CLI" assist id 2>&1 || true
    } | /usr/bin/tee -a "$diagnostic_log"

    if ! run_in_gui /usr/sbin/screencapture -x -t png "$png_path"; then
        echo "Snapshot failed: $safe_label" | /usr/bin/tee -a "$diagnostic_log" >&2
        return 1
    fi

    /usr/bin/sips -s format jpeg -s formatOptions 70 "$png_path" --out "$jpeg_path" >/dev/null
    /bin/rm -f "$png_path"
    echo "UUREMOTE_SNAPSHOT_SAVED:$jpeg_path" | /usr/bin/tee -a "$diagnostic_log"
}

dismiss_uuremote_private_window_prompt() {
    local prompt_result

    if ! prompt_result="$(run_in_gui /usr/bin/osascript <<'APPLESCRIPT'
on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell

    return ""
end attributeText

on inspectPrompt(shouldPressAllow)
    tell application "System Events"
        if not (exists application process "UserNotificationCenter") then return ""
        set notificationProcess to application process "UserNotificationCenter"

        repeat with promptWindow in windows of notificationProcess
            set contextText to my attributeText(promptWindow, "AXDescription")
            set allowButton to missing value

            repeat with uiText in static texts of promptWindow
                set textValue to my attributeText(uiText, "AXValue")
                if textValue is not "" then set contextText to contextText & " " & textValue
            end repeat

            repeat with uiButton in buttons of promptWindow
                set buttonTitle to my attributeText(uiButton, "AXTitle")
                set buttonDescription to my attributeText(uiButton, "AXDescription")

                -- The action is intentionally restricted to the exact English
                -- Allow label; similarly named buttons are never pressed.
                if buttonTitle is "Allow" or buttonDescription is "Allow" then
                    set allowButton to contents of uiButton
                end if
            end repeat

            ignoring case
                if contextText contains "com.netease.uuremote.agent" and contextText contains "private window picker" then
                    if shouldPressAllow and allowButton is missing value then
                        return "MISSING_ALLOW|context=[" & contextText & "]"
                    end if

                    if shouldPressAllow then perform action "AXPress" of allowButton
                    return "MATCHED|context=[" & contextText & "]"
                end if
            end ignoring
        end repeat
    end tell

    return ""
end inspectPrompt

set promptDetails to ""
repeat 4 times
    set promptDetails to my inspectPrompt(false)
    if promptDetails is not "" then exit repeat
    delay 0.25
end repeat

if promptDetails is "" then return "UURemote private window picker was not present during snapshot"

set pressedDetails to my inspectPrompt(true)
if pressedDetails starts with "MISSING_ALLOW|" then error "Matched the UURemote private window picker but its exact Allow button is missing: " & pressedDetails
if pressedDetails is "" then error "UURemote private window picker disappeared before its Allow button could be pressed"

repeat 20 times
    if my inspectPrompt(false) is "" then return "UURemote private window picker allowed during snapshot; " & pressedDetails
    delay 0.1
end repeat

error "UURemote private window picker remained visible after pressing Allow during snapshot"
APPLESCRIPT
)"; then
        echo "UUREMOTE_PERMISSION: failed to handle the UURemote private window picker during snapshot" >&2
        return 1
    fi

    echo "UUREMOTE_PERMISSION: $prompt_result"
}

case "$mode" in
    configure)
        ;;
    snapshot)
        dismiss_uuremote_private_window_prompt
        capture_snapshot "${2:-manual}"
        exit 0
        ;;
    *)
        echo "Usage: $0 [configure | snapshot LABEL]" >&2
        exit 2
        ;;
esac

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

echo "=== Starting UURemote and enabling unattended access ==="
run_in_gui /usr/bin/open "$APP"

if ! cli_status="$(wait_for_cli)"; then
    echo "UURemote CLI did not become ready within 20 seconds" >&2
    exit 1
fi

printf '%s\n' "$cli_status"

if ! assist_status="$(ensure_assist_allowed)"; then
    echo "Could not enable unattended control within 60 seconds" >&2
    exit 1
fi

printf '%s\n' "$assist_status"
echo "Unattended control is enabled"

if [ ! -f /etc/kcpassword ]; then
    echo "Automatic-login password file /etc/kcpassword does not exist" >&2
    exit 1
fi

runner_password="$(
    sudo /usr/bin/python3 -c '
import sys
key = bytes([0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F])
with open("/etc/kcpassword", "rb") as password_file:
    encoded = password_file.read()
decoded = bytes(value ^ key[index % len(key)] for index, value in enumerate(encoded))
sys.stdout.buffer.write(decoded.rstrip(b"\0"))
'
)"

if [ -z "$runner_password" ]; then
    echo "Could not decode the automatic-login password" >&2
    exit 1
fi

if ! /usr/bin/dscl . -authonly "$console_user" "$runner_password"; then
    echo "The decoded automatic-login password is not valid for $console_user" >&2
    unset runner_password
    exit 1
fi

echo "=== Opening Privacy & Security settings ==="

run_in_gui /usr/bin/killall "System Settings" >/dev/null 2>&1 || true
debug_sleep 2 0.5
run_in_gui /usr/bin/open -a "System Settings"
debug_sleep 2 0.5

echo "=== Adding UURemote and enabling privacy permissions ==="

screenshot_dir="$evidence_dir"
if [ "$debug_level" -ge 1 ]; then
    /bin/mkdir -p "$screenshot_dir"
else
    screenshot_dir=""
fi

run_permission() {
    local permission_kind="$1"
    local permission_target_path

    case "$permission_kind" in
        accessibility-main)
            # The main process checks and reports the keyboard/mouse
            # permission state to the remote client.
            permission_target_path="$APP"
            ;;
        accessibility-server)
            # Keyboard and mouse events are injected by this server process.
            permission_target_path="$APP/Contents/Helpers/UURemoteServer"
            ;;
        screen-capture)
            permission_target_path="$APP"
            ;;
        agent-private-picker)
            permission_target_path="$APP"
            ;;
        *)
            echo "Unsupported permission kind: $permission_kind" >&2
            return 1
            ;;
    esac

    run_in_gui /usr/bin/osascript - "$runner_password" "$screenshot_dir" "$permission_kind" "$permission_target_path" "$debug_level" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationPath : ""
property targetApplicationNames : {}
property activeDebugLevel : 0

on settleDelay(diagnosticSeconds, fastSeconds)
    if activeDebugLevel is greater than or equal to 1 then
        delay diagnosticSeconds
    else if fastSeconds is greater than 0 then
        delay fastSeconds
    end if
end settleDelay

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

on isSwitchControl(uiItem)
    tell application "System Events"
        try
            set itemRole to role of uiItem as text
            set itemSubrole to my attributeText(uiItem, "AXSubrole")

            if itemRole is "AXCheckBox" then return true
            if itemRole is "AXSwitch" then return true
            if itemSubrole is "AXSwitch" then return true
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

on textMatchesTarget(textValue)
    ignoring case
        repeat with candidateName in targetApplicationNames
            set candidateText to contents of candidateName as text

            if textValue is candidateText then return true
        end repeat
    end ignoring

    return false
end textMatchesTarget

on listContainsText(textValues, targetText)
    ignoring case
        repeat with existingText in textValues
            if (contents of existingText as text) is targetText then return true
        end repeat
    end ignoring

    return false
end listContainsText

on getPermissionOutline(settingsProcess)
    tell application "System Events"
        set candidateOutline to missing value
        set candidateTop to 1000000
        set allItems to entire contents of window 1 of settingsProcess

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXOutline" then
                    set itemPosition to position of uiItem
                    set itemSize to size of uiItem
                    set itemWidth to item 1 of itemSize
                    set itemHeight to item 2 of itemSize
                    set itemTop to item 2 of itemPosition

                    -- A privacy permission list is the first wide,
                    -- non-empty outline in the main settings pane.
                    if itemWidth is greater than or equal to 300 and itemHeight is greater than or equal to 40 then
                        if itemTop is less than candidateTop then
                            set candidateOutline to contents of uiItem
                            set candidateTop to itemTop
                        end if
                    end if
                end if
            end try
        end repeat

        return candidateOutline
    end tell
end getPermissionOutline

on getOutlineRows(targetOutline)
    tell application "System Events"
        return rows of targetOutline
    end tell
end getOutlineRows

on getRowTitle(targetRow)
    tell application "System Events"
        set rowItems to entire contents of targetRow

        repeat with uiItem in rowItems
            try
                if (role of uiItem as text) is "AXStaticText" then
                    set rowTitle to my attributeText(uiItem, "AXValue")

                    if rowTitle is not "" then return rowTitle
                end if
            end try
        end repeat
    end tell

    return ""
end getRowTitle

on getRowSwitch(targetRow)
    tell application "System Events"
        set rowItems to entire contents of targetRow

        repeat with uiItem in rowItems
            if my isSwitchControl(uiItem) then return contents of uiItem
        end repeat
    end tell

    return missing value
end getRowSwitch

on getRowTitles(targetOutline)
    set rowTitles to {}
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set rowTitle to my getRowTitle(contents of targetRow)

        if rowTitle is not "" then set end of rowTitles to rowTitle
    end repeat

    return rowTitles
end getRowTitles

on findTargetSwitch(targetOutline)
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)

        if my textMatchesTarget(rowTitle) then
            return my getRowSwitch(actualRow)
        end if
    end repeat

    return missing value
end findTargetSwitch

on findNewSwitch(targetOutline, previousTitles)
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)

        if rowTitle is not "" and not my listContainsText(previousTitles, rowTitle) then
            return my getRowSwitch(actualRow)
        end if
    end repeat

    return missing value
end findNewSwitch

on findAddButton(settingsProcess, targetOutline)
    tell application "System Events"
        set outlinePosition to position of targetOutline
        set outlineSize to size of targetOutline
        set outlineLeft to item 1 of outlinePosition
        set outlineBottom to (item 2 of outlinePosition) + (item 2 of outlineSize)
        set addCandidates to {}
        set allItems to entire contents of window 1 of settingsProcess

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXButton" then
                    set itemPosition to position of uiItem
                    set itemSize to size of uiItem
                    set itemLeft to item 1 of itemPosition
                    set itemTop to item 2 of itemPosition
                    set itemWidth to item 1 of itemSize
                    set itemHeight to item 2 of itemSize

                    -- On macOS 26 this plus button is intentionally unlabeled.
                    -- It is the square AXPress button immediately below the
                    -- first outline. The adjacent minus button is only 2 px high.
                    if itemLeft is greater than or equal to outlineLeft and itemLeft is less than or equal to outlineLeft + 25 then
                        if itemTop is greater than or equal to outlineBottom and itemTop is less than or equal to outlineBottom + 25 then
                            if itemWidth is greater than or equal to 8 and itemWidth is less than or equal to 20 then
                                if itemHeight is greater than or equal to 8 and itemHeight is less than or equal to 20 then
                                    set end of addCandidates to contents of uiItem
                                end if
                            end if
                        end if
                    end if
                end if
            end try
        end repeat

        if (count of addCandidates) is 1 then return item 1 of addCandidates
    end tell

    return missing value
end findAddButton

on pressExactButtonInProcess(targetProcess, candidateTitles)
    tell application "System Events"
        repeat with processWindow in windows of targetProcess
            repeat with uiItem in buttons of processWindow
                try
                    if my attributeText(uiItem, "AXRole") is "AXButton" then
                        set itemTitle to my attributeText(uiItem, "AXTitle")

                        repeat with candidateTitle in candidateTitles
                            if itemTitle is (contents of candidateTitle) then
                                perform action "AXPress" of uiItem
                                return itemTitle
                            end if
                        end repeat
                    end if
                end try
            end repeat
        end repeat
    end tell

    return ""
end pressExactButtonInProcess

on processHasWindowTitle(settingsProcess, desiredTitle)
    tell application "System Events"
        set settingsWindows to windows of settingsProcess

        repeat with settingsWindow in settingsWindows
            ignoring case
                if my attributeText(settingsWindow, "AXTitle") is desiredTitle then return true
            end ignoring
        end repeat
    end tell

    return false
end processHasWindowTitle

on visibleWindowDiagnostics()
    tell application "System Events"
        set diagnosticMessages to {}

        repeat with appProcess in application processes
            try
                if visible of appProcess is true and (count of windows of appProcess) is greater than 0 then
                    set processName to name of appProcess as text
                    set focusedRole to ""
                    set focusedDescription to ""

                    try
                        set focusedItem to value of attribute "AXFocusedUIElement" of appProcess
                        set focusedRole to my attributeText(focusedItem, "AXRole")
                        set focusedDescription to my attributeText(focusedItem, "AXDescription")
                    end try

                    repeat with processWindow in windows of appProcess
                        set windowTitle to my attributeText(processWindow, "AXTitle")
                        set end of diagnosticMessages to "process=" & processName & "; window=[" & windowTitle & "]; focusedRole=" & focusedRole & "; focusedDescription=[" & focusedDescription & "]"
                    end repeat
                end if
            end try
        end repeat

        return my joinText(diagnosticMessages)
    end tell
end visibleWindowDiagnostics

on joinText(textValues)
    set savedDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to ", "
    set joinedText to textValues as text
    set AppleScript's text item delimiters to savedDelimiters
    return joinedText
end joinText

on outlineDiagnostics(targetOutline)
    set diagnosticMessages to {}
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)
        set rowSwitch to my getRowSwitch(actualRow)
        set switchText to "missing"

        if rowSwitch is not missing value then
            if my switchIsEnabled(rowSwitch) then
                set switchText to "on"
            else
                set switchText to "off"
            end if
        end if

        set end of diagnosticMessages to "[" & rowTitle & ":" & switchText & "]"
    end repeat

    return my joinText(diagnosticMessages)
end outlineDiagnostics

on stopTargetProcesses()
    do shell script "/usr/bin/pkill -f '/Applications/UURemote.app/' >/dev/null 2>&1 || true"
end stopTargetProcesses

on progressMessage(messageText)
    log "UUREMOTE_PERMISSION: " & messageText
end progressMessage

on inspectPrivateWindowPickerPrompt(requesterText, shouldPressAllow)
    tell application "System Events"
        if not (exists application process "UserNotificationCenter") then return ""
        set appProcess to application process "UserNotificationCenter"

            try
                if (count of windows of appProcess) is greater than 0 then
                    set processName to name of appProcess as text

                    repeat with processWindow in windows of appProcess
                        set allowButton to missing value
                        set contextText to my attributeText(processWindow, "AXDescription")

                        repeat with uiText in static texts of processWindow
                            set textValue to my attributeText(uiText, "AXValue")
                            if textValue is not "" then set contextText to contextText & " " & textValue
                        end repeat

                        repeat with uiButton in buttons of processWindow
                            set buttonTitle to my attributeText(uiButton, "AXTitle")
                            set buttonDescription to my attributeText(uiButton, "AXDescription")

                            if buttonTitle is "Allow" or buttonDescription is "Allow" then
                                set allowButton to contents of uiButton
                            end if
                        end repeat

                        ignoring case
                            if contextText contains requesterText and contextText contains "private window picker" then
                                if shouldPressAllow and allowButton is missing value then
                                    return "MISSING_ALLOW|process=" & processName & "; context=[" & contextText & "]"
                                end if

                                if shouldPressAllow then
                                perform action "AXPress" of allowButton
                                end if

                                return "process=" & processName & "; context=[" & contextText & "]"
                            end if
                        end ignoring
                    end repeat
                end if
            end try
    end tell

    return ""
end inspectPrivateWindowPickerPrompt

on dismissPrivateWindowScreenshotPrompt()
    set promptDetails to my inspectPrivateWindowPickerPrompt("bash", true)
    if promptDetails starts with "MISSING_ALLOW|" then error "Matched the bash private window picker but its exact Allow button is missing: " & promptDetails
    return promptDetails
end dismissPrivateWindowScreenshotPrompt

on dismissUURemotePrivateWindowPrompt(screenshotDirectory)
    set waitAttempts to 12
    if activeDebugLevel is greater than or equal to 1 then set waitAttempts to 40

    set promptDetails to ""
    repeat waitAttempts times
        set promptDetails to my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false)
        if promptDetails is not "" then exit repeat
        delay 0.25
    end repeat

    if promptDetails is "" then
        my progressMessage("UURemote private window picker did not appear")
        return "UURemote private window picker was not present"
    end if

    my progressMessage("UURemote private window picker detected; " & promptDetails)

    if activeDebugLevel is greater than or equal to 1 then
        try
            my emitScreenshot("agent-private-picker-before", screenshotDirectory)
        on error screenshotError
            my progressMessage("UURemote private window picker pre-Allow screenshot failed: " & screenshotError)
        end try
    end if

    set pressedDetails to my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", true)
    if pressedDetails is "" then error "UURemote private window picker disappeared before its Allow button could be pressed"
    if pressedDetails starts with "MISSING_ALLOW|" then error "Matched the UURemote private window picker but its exact Allow button is missing: " & pressedDetails
    my progressMessage("UURemote private window picker Allow pressed; " & pressedDetails)

    repeat 40 times
        if my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false) is "" then
            if activeDebugLevel is greater than or equal to 1 then
                my settleDelay(1, 0)
                try
                    my emitScreenshot("agent-private-picker-after", screenshotDirectory)
                on error screenshotError
                    my progressMessage("UURemote private window picker post-Allow screenshot failed: " & screenshotError)
                end try
            end if

            return "UURemote private window picker allowed"
        end if

        delay 0.25
    end repeat

    error "UURemote private window picker remained visible after pressing Allow"
end dismissUURemotePrivateWindowPrompt

on emitScreenshot(captureLabel, screenshotDirectory)
    if activeDebugLevel is 0 then return ""

    tell application "System Events"
        tell process settingsProcessName
            set windowPosition to position of window 1
            set windowSize to size of window 1
        end tell
    end tell

    set captureRegion to (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
    set captureTimestamp to do shell script "/bin/date '+%Y%m%d-%H%M%S'"
    set pngPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-" & captureTimestamp & ".png"
    set jpegPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-" & captureTimestamp & ".jpg"
    do shell script "/usr/sbin/screencapture -x -t png -R" & quoted form of captureRegion & " " & quoted form of pngPath & " && /usr/bin/sips -s format jpeg -s formatOptions 55 " & quoted form of pngPath & " --out " & quoted form of jpegPath & " >/dev/null"
    log "UUREMOTE_SCREENSHOT_SAVED:" & jpegPath
    do shell script "/bin/rm -f " & quoted form of pngPath

    -- macOS 26 protects Privacy & Security windows with a separate prompt.
    -- Dismiss only the exact bash/private-window-picker prompt, then capture
    -- an unobscured copy. Any other Allow button is left untouched.
    set promptOwner to ""
    repeat 20 times
        set promptOwner to my dismissPrivateWindowScreenshotPrompt()
        if promptOwner is not "" then exit repeat
        delay 0.25
    end repeat

    if promptOwner is not "" then
        my progressMessage("Screenshot prerequisite allowed; " & promptOwner)
        delay 1
        set confirmedPngPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-confirmed-" & captureTimestamp & ".png"
        set confirmedJpegPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-confirmed-" & captureTimestamp & ".jpg"
        do shell script "/usr/sbin/screencapture -x -t png -R" & quoted form of captureRegion & " " & quoted form of confirmedPngPath & " && /usr/bin/sips -s format jpeg -s formatOptions 55 " & quoted form of confirmedPngPath & " --out " & quoted form of confirmedJpegPath & " >/dev/null"
        log "UUREMOTE_SCREENSHOT_SAVED:" & confirmedJpegPath
        do shell script "/bin/rm -f " & quoted form of confirmedPngPath
    end if
end emitScreenshot

on ensurePermission(permissionURL, permissionWindowTitle, permissionLabel, screenshotPrefix, authorizationPassword, screenshotDirectory)
    my progressMessage(permissionLabel & ": restarting System Settings for an isolated permission session")
    do shell script "/usr/bin/killall " & quoted form of "System Settings" & " >/dev/null 2>&1 || true"
    my settleDelay(2, 0.5)
    do shell script "/usr/bin/open -a " & quoted form of "System Settings"
    my settleDelay(1, 0.25)
    do shell script "/usr/bin/open " & quoted form of permissionURL
    my settleDelay(5, 0.5)

    tell application "System Events"
    my progressMessage(permissionLabel & ": waiting for the permission window")
    set pageReady to false

    repeat 120 times
        if exists application process settingsProcessName then
            set settingsProcess to application process settingsProcessName

            if exists window 1 of settingsProcess then
                if my attributeText(window 1 of settingsProcess, "AXTitle") is permissionWindowTitle then
                    set pageReady to true
                    exit repeat
                end if
            end if
        end if

        delay 0.25
    end repeat

    if pageReady is false then
        my progressMessage(permissionLabel & ": permission window timeout; visible windows: " & my visibleWindowDiagnostics())

        try
            my emitScreenshot(screenshotPrefix & "-page-timeout", screenshotDirectory)
        on error screenshotError
            my progressMessage(permissionLabel & ": timeout screenshot failed: " & screenshotError)
        end try

        error permissionLabel & " window did not become ready within 30 seconds"
    end if

    my progressMessage(permissionLabel & ": waiting for the primary permission outline")
    set settingsReady to false
    set permissionOutline to missing value

    repeat 120 times
        set permissionOutline to my getPermissionOutline(settingsProcess)

        if permissionOutline is not missing value then
            set settingsReady to true
            exit repeat
        end if

        delay 0.25
    end repeat

    if settingsReady is false then
        error permissionLabel & " list did not become ready within 30 seconds"
    end if

    set initialRows to my getOutlineRows(permissionOutline)
    my progressMessage(permissionLabel & ": primary outline ready; rows=" & (count of initialRows))
    my progressMessage(permissionLabel & ": state before action: " & my outlineDiagnostics(permissionOutline))
    my emitScreenshot(screenshotPrefix & "-before", screenshotDirectory)
    set targetSwitch to my findTargetSwitch(permissionOutline)

    if targetSwitch is missing value then
        set previousTitles to my getRowTitles(permissionOutline)
        my progressMessage(permissionLabel & ": UURemote row absent; existing rows=" & my joinText(previousTitles))
        set addButton to my findAddButton(settingsProcess, permissionOutline)

        if addButton is missing value then
            error permissionLabel & ": could not identify the add button. Rows: " & my outlineDiagnostics(permissionOutline)
        end if

        my progressMessage(permissionLabel & ": add button identified")
        perform action "AXPress" of addButton
        my settleDelay(2, 0.5)
        set fileChooserReady to my processHasWindowTitle(settingsProcess, "Open")

        if fileChooserReady is false then
            my progressMessage(permissionLabel & ": submitting the default Modify Settings confirmation")
            try
                set frontmost of settingsProcess to true
            end try
            key code 36
            my settleDelay(5, 0.5)
            my progressMessage(permissionLabel & ": windows after Modify Settings: " & my visibleWindowDiagnostics())

            set authenticationField to value of attribute "AXFocusedUIElement" of settingsProcess

            if my attributeText(authenticationField, "AXRole") is not "AXTextField" or my attributeText(authenticationField, "AXDescription") is not "Password" then
                error permissionLabel & ": the system authentication password field does not have keyboard focus"
            end if

            set value of authenticationField to authorizationPassword

            if my attributeText(authenticationField, "AXValue") is "" then
                error permissionLabel & ": the system authentication password field remained empty"
            end if

            my progressMessage(permissionLabel & ": administrator password field populated")
            my settleDelay(1, 0.25)
            key code 36
            my progressMessage(permissionLabel & ": administrator authorization submitted with the default button")
        end if

        repeat 80 times
            if my processHasWindowTitle(settingsProcess, "Open") then
                set fileChooserReady to true
                exit repeat
            end if

            delay 0.25
        end repeat

        if fileChooserReady is false then
            error permissionLabel & ": the file chooser did not appear after administrator authorization. Windows: " & my visibleWindowDiagnostics()
        end if

        my progressMessage(permissionLabel & ": file chooser ready")
        my emitScreenshot(screenshotPrefix & "-file-chooser-ready", screenshotDirectory)

        -- Use the standard macOS file chooser's Go to Folder command.
        keystroke "g" using {command down, shift down}
        my settleDelay(1, 0.25)
        set goToFolderField to value of attribute "AXFocusedUIElement" of settingsProcess

        if my attributeText(goToFolderField, "AXRole") is not "AXTextField" then
            error permissionLabel & ": the Go to Folder text field does not have keyboard focus"
        end if

        -- Assign the accessibility value directly. Sending a long path as
        -- synthetic keystrokes is intermittent on hosted macOS runners and
        -- can leave this sheet open forever with an incomplete path.
        set value of goToFolderField to targetApplicationPath

        if my attributeText(goToFolderField, "AXValue") is not targetApplicationPath then
            error permissionLabel & ": the Go to Folder path was not populated completely"
        end if

        my progressMessage(permissionLabel & ": Go to Folder path populated: " & targetApplicationPath)
        my settleDelay(1, 0.25)

        -- macOS 26 may consume a variable number of Returns while accepting
        -- autocomplete, navigating to the app, and submitting it. Keep going
        -- until the top-level Open window is actually gone.
        repeat with submissionNumber from 1 to 12
            key code 36
            my settleDelay(1, 0.25)
            set openWindowPresent to my processHasWindowTitle(settingsProcess, "Open")
            my progressMessage(permissionLabel & ": file chooser submission " & submissionNumber & "; openWindowPresent=" & openWindowPresent)

            if openWindowPresent is false then exit repeat
        end repeat

        if my processHasWindowTitle(settingsProcess, "Open") then
            error permissionLabel & ": the file chooser remained open after 12 submissions. Windows: " & my visibleWindowDiagnostics()
        end if

        my emitScreenshot(screenshotPrefix & "-file-chooser-selected", screenshotDirectory)

        -- The application has been submitted. Accept a possible default
        -- Quit & Reopen prompt before traversing the permission list again.
        my settleDelay(1, 0.25)
        key code 36
        my progressMessage(permissionLabel & ": accepted the default post-add confirmation, if present")
        my settleDelay(3, 0.5)

        set settingsProcess to application process settingsProcessName
        set permissionOutline to missing value

        repeat 40 times
            set permissionOutline to my getPermissionOutline(settingsProcess)

            if permissionOutline is not missing value then exit repeat
            delay 0.25
        end repeat

        if permissionOutline is missing value then
            error permissionLabel & ": the permission list disappeared after adding UURemote"
        end if

        -- The newly added row is unambiguous even if a future release
        -- changes the localized bundle display name.
        set targetSwitch to my findNewSwitch(permissionOutline, previousTitles)
    end if

    if targetSwitch is missing value then
        error permissionLabel & ": UURemote was not added to the permission list. Rows: " & my outlineDiagnostics(permissionOutline)
    end if

    my progressMessage(permissionLabel & ": UURemote switch identified")

    if my switchIsEnabled(targetSwitch) then
        my progressMessage(permissionLabel & ": state after action: " & my outlineDiagnostics(permissionOutline))
        my emitScreenshot(screenshotPrefix & "-after-already-enabled", screenshotDirectory)
        return "UURemote " & permissionLabel & " permission is already enabled"
    end if

    -- Killing every process inside the app bundle also kills the launch agent.
    -- launchd immediately relaunches UU Remote in the foreground, interrupting
    -- the TCC transaction and leaving the row denied. Keep the app stable while
    -- System Settings commits the switch, then accept its exact restart prompt.
    try
        set frontmost of settingsProcess to true
    end try
    my settleDelay(1, 0.25)
    perform action "AXPress" of targetSwitch
    my progressMessage(permissionLabel & ": permission switch pressed")

    -- On macOS 26 the switch can appear on before the administrator sheet is
    -- completed. Treating that transient visual state as success leaves the
    -- TCC row denied (auth_value=0), so explicitly complete the sheet first.
    my settleDelay(2, 0.5)
    my emitScreenshot(screenshotPrefix & "-after-switch-pressed", screenshotDirectory)

    set restartButtonTitle to ""
    repeat 20 times
        set restartButtonTitle to my pressExactButtonInProcess(settingsProcess, {"Quit & Reopen", "Quit and Reopen"})
        if restartButtonTitle is not "" then exit repeat
        delay 0.25
    end repeat

    if restartButtonTitle is not "" then
        my progressMessage(permissionLabel & ": accepted post-toggle button: " & restartButtonTitle)
        my settleDelay(3, 0.5)
        my emitScreenshot(screenshotPrefix & "-after-quit-and-reopen", screenshotDirectory)
    else
        my progressMessage(permissionLabel & ": no Quit & Reopen button appeared after toggling permission")
    end if

    set authenticationField to missing value

    repeat 40 times
        try
            set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

            if my attributeText(focusedItem, "AXRole") is "AXTextField" and my attributeText(focusedItem, "AXDescription") is "Password" then
                set authenticationField to focusedItem
                exit repeat
            end if
        end try

        delay 0.25
    end repeat

    if authenticationField is not missing value then
        my progressMessage(permissionLabel & ": administrator authorization required after toggling permission")
        set value of authenticationField to authorizationPassword

        if my attributeText(authenticationField, "AXValue") is "" then
            error permissionLabel & ": the post-toggle authentication password field remained empty"
        end if

        my settleDelay(1, 0.25)
        key code 36
        my progressMessage(permissionLabel & ": administrator authorization submitted after toggling permission")

        repeat 80 times
            try
                set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

                if my attributeText(focusedItem, "AXRole") is not "AXTextField" or my attributeText(focusedItem, "AXDescription") is not "Password" then
                    exit repeat
                end if
            on error
                exit repeat
            end try

            delay 0.25
        end repeat

        try
            set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

            if my attributeText(focusedItem, "AXRole") is "AXTextField" and my attributeText(focusedItem, "AXDescription") is "Password" then
                error permissionLabel & ": administrator authorization remained open after password submission"
            end if
        end try

        my emitScreenshot(screenshotPrefix & "-after-authentication", screenshotDirectory)
    else
        my progressMessage(permissionLabel & ": no administrator authorization sheet appeared after toggling permission")
    end if

    repeat 40 times
        if my switchIsEnabled(targetSwitch) then
            my progressMessage(permissionLabel & ": permission switch is on")
            my progressMessage(permissionLabel & ": state after action: " & my outlineDiagnostics(permissionOutline))
            my emitScreenshot(screenshotPrefix & "-after-enabled", screenshotDirectory)
            exit repeat
        end if

        delay 0.25
    end repeat

    if my switchIsEnabled(targetSwitch) is false then
        error permissionLabel & ": UURemote switch was pressed but did not turn on. Rows: " & my outlineDiagnostics(permissionOutline)
    end if

    -- A visual on-state is not sufficient: restart System Settings and read
    -- the row again so the script only succeeds after TCC has persisted it.
    my progressMessage(permissionLabel & ": reopening System Settings to verify persistence")
    my progressMessage(permissionLabel & ": stopping System Settings")
    do shell script "/usr/bin/killall " & quoted form of "System Settings" & " >/dev/null 2>&1 || true"
    my progressMessage(permissionLabel & ": System Settings stop command completed")
    my settleDelay(2, 0.5)
    my progressMessage(permissionLabel & ": launching System Settings")
    do shell script "/usr/bin/open -a " & quoted form of "System Settings"
    my progressMessage(permissionLabel & ": System Settings launch command completed")
    my settleDelay(1, 0.25)
    my progressMessage(permissionLabel & ": opening permission URL for persistence verification")
    do shell script "/usr/bin/open " & quoted form of permissionURL
    my progressMessage(permissionLabel & ": permission URL open command completed")
    my settleDelay(5, 0.5)

    set persistedPageReady to false
    my progressMessage(permissionLabel & ": waiting for the persistence verification page")

    repeat 120 times
        if exists application process settingsProcessName then
            set settingsProcess to application process settingsProcessName

            if exists window 1 of settingsProcess then
                if my attributeText(window 1 of settingsProcess, "AXTitle") is permissionWindowTitle then
                    set persistedPageReady to true
                    exit repeat
                end if
            end if
        end if

        delay 0.25
    end repeat

    if persistedPageReady is false then
        error permissionLabel & ": could not reopen the permission page for persistence verification"
    end if

    set persistedOutline to missing value

    repeat 120 times
        set persistedOutline to my getPermissionOutline(settingsProcess)
        if persistedOutline is not missing value then exit repeat
        delay 0.25
    end repeat

    if persistedOutline is missing value then
        error permissionLabel & ": permission list did not reappear for persistence verification"
    end if

    set persistedSwitch to my findTargetSwitch(persistedOutline)

    if persistedSwitch is missing value then
        my emitScreenshot(screenshotPrefix & "-persistence-row-missing", screenshotDirectory)
        error permissionLabel & ": UURemote row disappeared after reopening System Settings"
    end if

    if my switchIsEnabled(persistedSwitch) is false then
        my progressMessage(permissionLabel & ": state after reopening: " & my outlineDiagnostics(persistedOutline))
        my emitScreenshot(screenshotPrefix & "-persistence-failed", screenshotDirectory)
        error permissionLabel & ": permission did not persist after reopening System Settings"
    end if

    my progressMessage(permissionLabel & ": permission persisted after reopening System Settings")
    my progressMessage(permissionLabel & ": persisted state: " & my outlineDiagnostics(persistedOutline))
    my emitScreenshot(screenshotPrefix & "-after-reopened", screenshotDirectory)
    return "UURemote " & permissionLabel & " permission enabled and persisted"
    end tell
end ensurePermission

on run argv
    if (count of argv) is not 5 then error "Expected the runner login password, screenshot directory, permission kind, permission target path, and debug level arguments"
    set authorizationPassword to item 1 of argv as text
    set screenshotDirectory to item 2 of argv as text
    set permissionKind to item 3 of argv as text
    set targetApplicationPath to item 4 of argv as text
    set activeDebugLevel to item 5 of argv as integer

    if permissionKind is "accessibility-main" then
        set targetApplicationNames to {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}
        return my ensurePermission(¬
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", ¬
            "Accessibility", ¬
            "Accessibility (UURemote)", ¬
            "accessibility-main", ¬
            authorizationPassword, ¬
            screenshotDirectory)
    else if permissionKind is "accessibility-server" then
        set targetApplicationNames to {"UURemoteServer", "com.netease.uuremote.server"}
        return my ensurePermission(¬
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", ¬
            "Accessibility", ¬
            "Accessibility (UURemoteServer)", ¬
            "accessibility-server", ¬
            authorizationPassword, ¬
            screenshotDirectory)
    else if permissionKind is "screen-capture" then
        set targetApplicationNames to {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}
        return my ensurePermission(¬
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", ¬
            "Screen & System Audio Recording", ¬
            "Screen & System Audio Recording", ¬
            "screen-capture", ¬
            authorizationPassword, ¬
            screenshotDirectory)
    else if permissionKind is "agent-private-picker" then
        return my dismissUURemotePrivateWindowPrompt(screenshotDirectory)
    end if

    error "Unsupported permission kind: " & permissionKind
end run
APPLESCRIPT
}

run_permission accessibility-main
run_permission accessibility-server
run_permission screen-capture

echo "=== Restarting UURemote ==="

debug_sleep 2 0.5
run_in_gui /usr/bin/open "$APP"

echo "=== Waiting for CLI ==="

if ! cli_status="$(wait_for_cli)"; then
    echo "UURemote started, but its CLI did not recover within 20 seconds" >&2
    exit 1
fi

printf '%s\n' "$cli_status"
echo "UURemote restarted successfully"

echo "=== Handling UURemote screen-sharing confirmation ==="
run_permission agent-private-picker

unset runner_password

if [ "$debug_level" -ge 1 ]; then
    capture_snapshot "final-app"
fi
