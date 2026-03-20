#!/usr/bin/env bash
# Stream Zoom transcript to a file as the meeting happens.
# Polls the standalone Transcript window every INTERVAL seconds,
# re-extracting the full transcript each time (handles in-place updates
# from ongoing speech recognition and concurrent speakers).
#
# Usage: zoom-stream.sh [MEETING_ID] [INTERVAL]
#   MEETING_ID: numeric meeting ID (default: from invite link or "unknown")
#   INTERVAL: seconds between polls (default: 1)
#
# Requires: standalone "Transcript" window popped out in Zoom.
#
# Output: continuously updates /tmp/zoom_transcript_{MEETING_ID}_live.txt
# Press Ctrl+C to stop.

set -euo pipefail

MEETING_ID="${1:-}"
INTERVAL="${2:-1}"

# Verify standalone Transcript window exists
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

# Get meeting ID from invite link if not provided
if [ -z "$MEETING_ID" ]; then
    MEETING_ID=$(osascript -e '
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
    ' 2>/dev/null | grep -oE '[0-9]{9,}' || echo "unknown")
fi

LIVE_FILE="/tmp/zoom_transcript_${MEETING_ID}_live.txt"
CURR_RAW=$(mktemp)
PREV_HASH=""
trap 'rm -f "$CURR_RAW"' EXIT

> "$LIVE_FILE"

echo "Streaming transcript to: $LIVE_FILE" >&2
echo "Polling every ${INTERVAL}s. Press Ctrl+C to stop." >&2

fetch_raw() {
    osascript << 'ASCRIPT'
set LF to ASCII character 10

tell application "System Events"
    tell process "zoom.us"
        tell window "Transcript"
            tell table 1 of scroll area 1
                set allNames to value of every static text of every UI element of every row
                set allTexts to value of every text area of every UI element of every row
                set rowCount to count of allNames
            end tell
        end tell
    end tell
end tell

set output to ""
repeat with i from 1 to rowCount
    set n to item i of allNames
    set t to item i of allTexts
    if n is not missing value and (n as text) is not "" then
        set output to output & "S:" & (n as text) & LF
    else if t is not missing value and (t as text) is not "" then
        set output to output & "T:" & (t as text) & LF
    end if
end repeat
return output
ASCRIPT
}

parse_full() {
    python3 - "$1" << 'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    lines = [l for l in f.read().strip().split('\n') if l]

if not lines:
    sys.exit(0)

timestamp_re = re.compile(r'^(\d{1,2}:\d{2}:\d{2})(.*)', re.DOTALL)

current_speaker = None
current_timestamp = None
current_lines = []
output_blocks = []

def flush():
    global current_lines
    if current_speaker and current_timestamp and current_lines:
        output_blocks.append(
            f"{current_speaker} [{current_timestamp}]:\n" + " ".join(current_lines)
        )
    current_lines = []

for line in lines:
    if line.startswith('S:'):
        flush()
        current_speaker = line[2:]
    elif line.startswith('T:'):
        text = line[2:]
        m = timestamp_re.match(text)
        if m:
            flush()
            current_timestamp = m.group(1)
            remainder = m.group(2).strip()
            current_lines = [remainder] if remainder else []
        else:
            current_lines.append(text)

flush()

if output_blocks:
    print("\n\n".join(output_blocks))
PYEOF
}

transcript_window_exists() {
    osascript -e '
    tell application "System Events"
        tell process "zoom.us"
            if exists window "Transcript" then return "yes"
        end tell
    end tell
    return "no"
    ' 2>/dev/null
}

while true; do
    # Stop if Transcript window closed (meeting ended)
    if [ "$(transcript_window_exists)" != "yes" ]; then
        echo "[$(date +%H:%M:%S)] Transcript window closed. Stopping." >&2
        break
    fi

    fetch_raw > "$CURR_RAW" 2>/dev/null || true

    # Only re-parse if content changed
    curr_hash=$(md5 -q "$CURR_RAW" 2>/dev/null || md5sum "$CURR_RAW" | cut -d' ' -f1)
    if [ "$curr_hash" != "$PREV_HASH" ]; then
        parsed=$(parse_full "$CURR_RAW" || true)
        if [ -n "$parsed" ]; then
            echo "$parsed" > "$LIVE_FILE"
            line_count=$(echo "$parsed" | wc -l | tr -d ' ')
            echo "[$(date +%H:%M:%S)] ${line_count} lines (updated)" >&2
        fi
        PREV_HASH="$curr_hash"
    fi

    sleep "$INTERVAL"
done

echo "Final transcript: $LIVE_FILE" >&2