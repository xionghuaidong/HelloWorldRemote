#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"
PREF_URL='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'

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

echo "=== Opening Screen & System Audio Recording settings ==="

run_in_gui /usr/bin/killall "System Settings" >/dev/null 2>&1 || true
sleep 2
run_in_gui /usr/bin/open -a "System Settings"
sleep 1
run_in_gui /usr/bin/open "$PREF_URL"
sleep 5

echo "=== Adding UURemote and enabling permission ==="

screenshot_dir="${RUNNER_TEMP:-/tmp}/uuremote-permission-screenshots"
/bin/mkdir -p "$screenshot_dir"

run_in_gui /usr/bin/osascript - "$runner_password" "$screenshot_dir" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationPath : "/Applications/UURemote.app"
property targetApplicationNames : {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}

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
            if textValue contains candidateText then return true
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

on getScreenCaptureOutline(settingsProcess)
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

                    -- The Screen & System Audio Recording list is the first
                    -- wide, non-empty outline in the main settings pane.
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
end getScreenCaptureOutline

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

on findProcessButton(settingsProcess, desiredTitle)
    tell application "System Events"
        set settingsWindows to windows of settingsProcess

        repeat with settingsWindow in settingsWindows
            set actualWindow to contents of settingsWindow
            set windowItems to entire contents of actualWindow

            repeat with uiItem in windowItems
                try
                    if (role of uiItem as text) is "AXButton" then
                        set buttonTitle to my attributeText(uiItem, "AXTitle")

                        ignoring case
                            if buttonTitle is desiredTitle then return contents of uiItem
                        end ignoring
                    end if
                end try
            end repeat
        end repeat
    end tell

    return missing value
end findProcessButton

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

on emitScreenshot(captureLabel, screenshotDirectory)
    tell application "System Events"
        tell process settingsProcessName
            set windowPosition to position of window 1
            set windowSize to size of window 1
        end tell
    end tell

    set captureRegion to (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
    set pngPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & ".png"
    set jpegPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & ".jpg"
    do shell script "/usr/sbin/screencapture -x -t png -R" & quoted form of captureRegion & " " & quoted form of pngPath & " && /usr/bin/sips -s format jpeg -s formatOptions 55 " & quoted form of pngPath & " --out " & quoted form of jpegPath & " >/dev/null"
    log "UUREMOTE_SCREENSHOT_SAVED:" & jpegPath
    do shell script "/bin/rm -f " & quoted form of pngPath
end emitScreenshot

on run argv
    if (count of argv) is not 2 then error "Expected the runner login password and screenshot directory arguments"
    set authorizationPassword to item 1 of argv as text
    set screenshotDirectory to item 2 of argv as text

    tell application "System Events"
    my progressMessage("waiting for the Screen & System Audio Recording window")
    set pageReady to false

    repeat 120 times
        if exists application process settingsProcessName then
            set settingsProcess to application process settingsProcessName

            if exists window 1 of settingsProcess then
                if my attributeText(window 1 of settingsProcess, "AXTitle") is "Screen & System Audio Recording" then
                    set pageReady to true
                    exit repeat
                end if
            end if
        end if

        delay 0.25
    end repeat

    if pageReady is false then
        error "Screen & System Audio Recording window did not become ready within 30 seconds"
    end if

    my progressMessage("waiting for the primary screen-capture outline")
    set settingsReady to false
    set screenCaptureOutline to missing value

    repeat 120 times
        set screenCaptureOutline to my getScreenCaptureOutline(settingsProcess)

        if screenCaptureOutline is not missing value then
            set settingsReady to true
            exit repeat
        end if

        delay 0.25
    end repeat

    if settingsReady is false then
        error "Screen & System Audio Recording list did not become ready within 30 seconds"
    end if

    set initialRows to my getOutlineRows(screenCaptureOutline)
    my progressMessage("primary outline ready; rows=" & (count of initialRows))
    set targetSwitch to my findTargetSwitch(screenCaptureOutline)

    if targetSwitch is missing value then
        set previousTitles to my getRowTitles(screenCaptureOutline)
        my progressMessage("UURemote row absent; existing rows=" & my joinText(previousTitles))
        set addButton to my findAddButton(settingsProcess, screenCaptureOutline)

        if addButton is missing value then
            error "Could not identify the add button. Rows: " & my outlineDiagnostics(screenCaptureOutline)
        end if

        my progressMessage("add button identified")
        perform action "AXPress" of addButton
        set modifySettingsButton to missing value
        set openButton to missing value

        repeat 40 times
            set modifySettingsButton to my findProcessButton(settingsProcess, "Modify Settings")

            if modifySettingsButton is not missing value then exit repeat

            -- Some managed images have already authorized this settings
            -- change and go straight to the file chooser.
            set openButton to my findProcessButton(settingsProcess, "Open")

            if openButton is not missing value then exit repeat
            delay 0.5
        end repeat

        if modifySettingsButton is not missing value then
            my progressMessage("administrator authorization sheet identified")
            try
                set frontmost of settingsProcess to true
            end try

            -- The first sheet is only a confirmation sheet. Pressing Modify
            -- Settings opens the separate system authentication dialog. This
            -- order and timing matches actions/runner-images' official helper.
            click modifySettingsButton
            delay 5
            my progressMessage("windows after Modify Settings: " & my visibleWindowDiagnostics())

            set authenticationField to value of attribute "AXFocusedUIElement" of settingsProcess

            if my attributeText(authenticationField, "AXRole") is not "AXTextField" or my attributeText(authenticationField, "AXDescription") is not "Password" then
                error "The system authentication password field does not have keyboard focus"
            end if

            set value of authenticationField to authorizationPassword

            if my attributeText(authenticationField, "AXValue") is "" then
                error "The system authentication password field remained empty"
            end if

            my progressMessage("administrator password field populated")
            delay 1

            set authorizationSubmitButton to my findProcessButton(settingsProcess, "Modify Settings")

            if authorizationSubmitButton is missing value then
                error "The administrator authorization submit button disappeared"
            end if

            my progressMessage("authorization submit enabled=" & my attributeText(authorizationSubmitButton, "AXEnabled"))
            perform action "AXPress" of authorizationSubmitButton
            delay 2
            my progressMessage("windows after authorization submit: " & my visibleWindowDiagnostics())
            my progressMessage("administrator authorization submitted")
        end if

        if modifySettingsButton is missing value and openButton is missing value then
            error "Neither administrator authorization nor the file chooser appeared"
        end if

        if openButton is missing value then
            repeat 40 times
                set openButton to my findProcessButton(settingsProcess, "Open")

                if openButton is not missing value then exit repeat
                delay 0.5
            end repeat
        end if

        if openButton is missing value then
            error "The file chooser did not appear after administrator authorization"
        end if

        my progressMessage("file chooser ready")
        my emitScreenshot("file-chooser-ready", screenshotDirectory)

        -- Use the standard macOS file chooser's Go to Folder command.
        keystroke "g" using {command down, shift down}
        delay 1
        keystroke targetApplicationPath
        delay 2

        -- macOS 26 may consume a variable number of Returns while accepting
        -- autocomplete, navigating to the app, and closing Go to Folder.
        -- Continue only while the Go to Folder text field keeps focus.
        repeat with confirmationNumber from 1 to 6
            key code 36
            delay 2

            set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess
            set focusedRole to my attributeText(focusedItem, "AXRole")
            set focusedDescription to my attributeText(focusedItem, "AXDescription")
            my progressMessage("Go to Folder confirmation " & confirmationNumber & "; focusedRole=" & focusedRole & "; focusedDescription=[" & focusedDescription & "]")

            if focusedRole is not "AXTextField" then exit repeat
        end repeat

        my emitScreenshot("file-chooser-selected", screenshotDirectory)

        -- The third Return may submit the application directly. When it does,
        -- macOS immediately asks to restart the running application.
        set quitAndReopenButton to my findProcessButton(settingsProcess, "Quit & Reopen")

        if quitAndReopenButton is not missing value then
            my progressMessage("Quit & Reopen prompt identified")
            perform action "AXPress" of quitAndReopenButton
            my progressMessage("Quit & Reopen submitted")
            delay 3
        else
            set openButton to my findProcessButton(settingsProcess, "Open")

            if openButton is missing value then
                error "Neither Quit & Reopen nor the file chooser Open button appeared after selecting UURemote.app"
            end if

            if my attributeText(openButton, "AXEnabled") is not "true" then
                error "The file chooser Open button remained disabled after selecting UURemote.app"
            end if

            my progressMessage("file chooser Open button identified")
            perform action "AXPress" of openButton
            my progressMessage("file chooser submitted UURemote.app")
            delay 3
        end if

        set settingsProcess to application process settingsProcessName
        set screenCaptureOutline to my getScreenCaptureOutline(settingsProcess)

        if screenCaptureOutline is missing value then
            error "The screen-capture list disappeared after adding UURemote"
        end if

        -- The newly added row is unambiguous even if a future release
        -- changes the localized bundle display name.
        set targetSwitch to my findNewSwitch(screenCaptureOutline, previousTitles)
    end if

    if targetSwitch is missing value then
        error "UURemote was not added to the permission list. Rows: " & my outlineDiagnostics(screenCaptureOutline)
    end if

    my progressMessage("UURemote switch identified")

    if my switchIsEnabled(targetSwitch) then
        return "UURemote Screen & System Audio Recording permission is already enabled"
    end if

    my progressMessage("stopping UURemote processes before toggling permission")
    my stopTargetProcesses()
    delay 1
    perform action "AXPress" of targetSwitch
    my progressMessage("permission switch pressed")

    repeat 40 times
        if my switchIsEnabled(targetSwitch) then
            my progressMessage("permission switch is on")
            return "UURemote Screen & System Audio Recording permission enabled"
        end if

        delay 0.25
    end repeat

        error "UURemote switch was pressed but did not turn on. Rows: " & my outlineDiagnostics(screenCaptureOutline)
    end tell
end run
APPLESCRIPT

unset runner_password

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
            echo "UURemote restarted successfully"
            exit 0
        fi
    fi

    sleep 0.5
done

echo "UURemote started, but its CLI did not recover within 20 seconds" >&2
exit 1
