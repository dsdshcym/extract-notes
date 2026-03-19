#!/usr/bin/env bash
# Check if Zoom has a Transcript window open.
# Outputs the list of Zoom window names.
# Exit 0 if "Transcript" is found, exit 1 otherwise.

set -euo pipefail

windows=$(osascript -e '
tell application "System Events"
    tell process "zoom.us"
        get name of every window
    end tell
end tell
')

echo "$windows"

if echo "$windows" | grep -q "Transcript"; then
    exit 0
else
    exit 1
fi