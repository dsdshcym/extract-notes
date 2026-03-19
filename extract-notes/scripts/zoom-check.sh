#!/usr/bin/env bash
# Check if Zoom has a standalone Transcript window open and output meeting info.
#
# Output: MEETING_ID (numeric, e.g., 95820521679)
#
# Exit 0 if standalone Transcript window found, exit 1 otherwise.

set -euo pipefail

windows=$(osascript -e '
tell application "System Events"
    tell process "zoom.us"
        get name of every window
    end tell
end tell
')

if ! echo "$windows" | grep -q "Transcript"; then
    echo "No standalone Transcript window found. Please pop out the transcript panel in Zoom." >&2
    exit 1
fi

# Get meeting ID from invite link
meeting_id=$(osascript -e '
set oldClip to the clipboard

tell application "System Events"
    tell process "zoom.us"
        click menu item "Copy invite link" of menu 1 of menu bar item "Meeting" of menu bar 1
    end tell
end tell

delay 0.3
set inviteLink to the clipboard as text

set the clipboard to oldClip

return inviteLink
' 2>/dev/null | grep -oE '[0-9]{9,}' || echo "")

if [ -z "$meeting_id" ]; then
    meeting_id="unknown"
fi

echo "$meeting_id"