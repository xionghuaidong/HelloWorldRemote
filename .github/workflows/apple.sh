#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"

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
sleep 2
run_in_gui /usr/bin/open -a "System Settings"
sleep 2

echo "=== Adding UURemote and enabling privacy permissions ==="

screenshot_dir="${RUNNER_TEMP:-/tmp}/uuremote-permission-screenshots"
/bin/mkdir -p "$screenshot_dir"

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
        *)
            echo "Unsupported permission kind: $permission_kind" >&2
            return 1
            ;;
    esac

    run_in_gui /usr/bin/osascript - "$runner_password" "$screenshot_dir" "$permission_kind" "$permission_target_path" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationPath : ""
property targetApplicationNames : {}

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

on pressSettingsConfirmationButton(settingsProcess, desiredTitles)
    tell application "System Events"
        repeat with settingsWindow in windows of settingsProcess
            set windowTitle to my attributeText(settingsWindow, "AXTitle")
            set allItems to entire contents of settingsWindow

            repeat with uiItem in allItems
                try
                    if (role of uiItem as text) is "AXButton" then
                        set itemTitle to my attributeText(uiItem, "AXTitle")
                        set itemDescription to my attributeText(uiItem, "AXDescription")

                        ignoring case
                            repeat with desiredTitle in desiredTitles
                                set desiredText to contents of desiredTitle as text

                                if itemTitle is desiredText or itemDescription is desiredText then
                                    perform action "AXPress" of uiItem
                                    return "window=[" & windowTitle & "]"
                                end if
                            end repeat
                        end ignoring
                    end if
                end try
            end repeat
        end repeat
    end tell

    return ""
end pressSettingsConfirmationButton

on acceptAllowConfirmation(settingsProcess, permissionLabel)
    set confirmationOwner to ""

    repeat 40 times
        set confirmationOwner to my pressSettingsConfirmationButton(settingsProcess, {"Allow", "允许"})

        if confirmationOwner is not "" then
            my progressMessage(permissionLabel & ": Allow confirmation pressed; " & confirmationOwner)
            delay 2
            return true
        end if

        delay 0.25
    end repeat

    my progressMessage(permissionLabel & ": no Allow confirmation appeared in System Settings")
    return false
end acceptAllowConfirmation

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

on ensurePermission(permissionURL, permissionWindowTitle, permissionLabel, screenshotPrefix, authorizationPassword, screenshotDirectory)
    my progressMessage(permissionLabel & ": restarting System Settings for an isolated permission session")
    do shell script "/usr/bin/killall " & quoted form of "System Settings" & " >/dev/null 2>&1 || true"
    delay 2
    do shell script "/usr/bin/open -a " & quoted form of "System Settings"
    delay 1
    do shell script "/usr/bin/open " & quoted form of permissionURL
    delay 5

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
        delay 2
        set fileChooserReady to my processHasWindowTitle(settingsProcess, "Open")

        if fileChooserReady is false then
            my progressMessage(permissionLabel & ": submitting the default Modify Settings confirmation")
            try
                set frontmost of settingsProcess to true
            end try
            key code 36
            delay 5
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
            delay 1
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
        delay 1
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
        delay 1

        -- macOS 26 may consume a variable number of Returns while accepting
        -- autocomplete, navigating to the app, and submitting it. Keep going
        -- until the top-level Open window is actually gone.
        repeat with submissionNumber from 1 to 12
            key code 36
            delay 1
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
        delay 1
        key code 36
        my progressMessage(permissionLabel & ": accepted the default post-add confirmation, if present")
        delay 3

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
        -- Adding an application can turn the switch on before the separate
        -- Allow confirmation is accepted. Handle a pending dialog before
        -- returning from the already-on path.
        my acceptAllowConfirmation(settingsProcess, permissionLabel)
        return "UURemote " & permissionLabel & " permission is already enabled"
    end if

    my progressMessage(permissionLabel & ": stopping UURemote processes before toggling permission")
    my stopTargetProcesses()
    delay 1
    perform action "AXPress" of targetSwitch
    my progressMessage(permissionLabel & ": permission switch pressed")

    -- macOS 26 shows a second confirmation after the switch is pressed. The
    -- switch can already report "on" while this dialog is still waiting, so
    -- accept it before treating the permission as effective.
    my acceptAllowConfirmation(settingsProcess, permissionLabel)

    repeat 40 times
        if my switchIsEnabled(targetSwitch) then
            my progressMessage(permissionLabel & ": permission switch is on")
            return "UURemote " & permissionLabel & " permission enabled"
        end if

        delay 0.25
    end repeat

        error permissionLabel & ": UURemote switch was pressed but did not turn on. Rows: " & my outlineDiagnostics(permissionOutline)
    end tell
end ensurePermission

on run argv
    if (count of argv) is not 4 then error "Expected the runner login password, screenshot directory, permission kind, and permission target path arguments"
    set authorizationPassword to item 1 of argv as text
    set screenshotDirectory to item 2 of argv as text
    set permissionKind to item 3 of argv as text
    set targetApplicationPath to item 4 of argv as text

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
    end if

    error "Unsupported permission kind: " & permissionKind
end run
APPLESCRIPT
}

run_permission accessibility-main
run_permission accessibility-server
run_permission screen-capture

unset runner_password

echo "=== Restarting UURemote ==="

sleep 2
run_in_gui /usr/bin/open "$APP"

echo "=== Waiting for CLI ==="

if ! cli_status="$(wait_for_cli)"; then
    echo "UURemote started, but its CLI did not recover within 20 seconds" >&2
    exit 1
fi

printf '%s\n' "$cli_status"
echo "UURemote restarted successfully"
