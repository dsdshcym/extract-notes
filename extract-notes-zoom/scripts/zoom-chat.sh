#!/usr/bin/env bash
# Save Zoom in-meeting chat using Zoom's built-in "Save chat" feature.
# Uses AppleScript to: open Chat window (Cmd+Shift+H), click "More" menu,
# arrow-down to "Save chat", press Enter.
#
# Usage: zoom-chat.sh
#
# Requires: Zoom meeting in progress with chat messages.
#
# Output: path to saved chat file printed to stdout.
# Zoom saves to ~/Documents/Zoom/<meeting-folder>/meeting_saved_new_chat.txt

set -euo pipefail

ZOOM_DIR="$HOME/Documents/Zoom"

# --- Ensure Chat window is open ---

chat_window_exists() {
    osascript -e '
    tell application "System Events"
        if not (exists process "zoom.us") then return "no"
        tell process "zoom.us"
            set wins to name of every window
            repeat with w in wins
                set wLower to do shell script "echo " & quoted form of (w as text) & " | tr A-Z a-z"
                if wLower starts with "chat" or wLower is "meeting chat" then return "yes"
            end repeat
        end tell
    end tell
    return "no"
    ' 2>/dev/null
}

zoom_meeting_exists() {
    osascript -e '
    tell application "System Events"
        if not (exists process "zoom.us") then return "no"
        tell process "zoom.us"
            if exists window "Zoom Meeting" then return "yes"
        end tell
    end tell
    return "no"
    ' 2>/dev/null
}

if [ "$(chat_window_exists)" != "yes" ]; then
    if [ "$(zoom_meeting_exists)" != "yes" ]; then
        echo "No Zoom meeting in progress." >&2
        exit 1
    fi
    echo "Opening Chat window (Cmd+Shift+H)..." >&2
    osascript -e '
    tell application "System Events"
        tell process "zoom.us"
            set frontmost to true
            delay 0.3
            perform action "AXRaise" of window "Zoom Meeting"
            delay 0.3
            keystroke "h" using {command down, shift down}
        end tell
    end tell
    '
    sleep 1

    if [ "$(chat_window_exists)" != "yes" ]; then
        echo "Failed to open Chat window." >&2
        exit 1
    fi
fi

# --- Create timestamp marker before save ---

MARKER=$(mktemp)
sleep 1  # ensure marker is older than any file Zoom creates

# --- Click More > Save chat ---

osascript << 'ASCRIPT'
tell application "System Events"
    tell process "zoom.us"
        set wins to name of every window
        repeat with w in wins
            set wLower to do shell script "echo " & quoted form of (w as text) & " | tr A-Z a-z"
            if wLower starts with "chat" or wLower is "meeting chat" then
                tell window (w as text)
                    set allBtns to every button
                    repeat with b in allBtns
                        if description of b is "More" then
                            click b
                            exit repeat
                        end if
                    end repeat
                end tell
            end if
        end repeat

        delay 0.5
        key code 125 -- arrow down (select "Save chat")
        delay 0.2
        key code 36 -- return
    end tell
end tell
ASCRIPT

# --- Find the saved chat file (newer than our marker) ---

sleep 1

NEW_FILE=$(find "$ZOOM_DIR" -name "meeting_saved_new_chat.txt" -newer "$MARKER" 2>/dev/null | head -1 || true)
rm -f "$MARKER"

if [ -z "$NEW_FILE" ]; then
    echo "Save chat may have failed — no new file found in $ZOOM_DIR" >&2
    echo "Check Zoom settings for save location." >&2
    exit 1
fi

echo "$NEW_FILE"