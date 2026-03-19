#!/usr/bin/env bash
# Extract Zoom transcript from the standalone Transcript window.
# Uses AppleScript to bulk-fetch all rows, then Python to parse into
# clean speaker-timestamped blocks.
#
# Usage: zoom-extract.sh [MEETING_ID]
#   MEETING_ID: numeric meeting ID (default: from invite link or "unknown")
#
# Output: clean transcript printed to stdout.
# Also saved to /tmp/zoom_transcript_{MEETING_ID}_{DATE}.txt
# Raw merged data at /tmp/zoom_merged_{MEETING_ID}_{DATE}.txt

set -euo pipefail

MEETING_ID="${1:-}"
DATE=$(date +%Y%m%d_%H%M%S)

# Auto-detect meeting ID if not provided
if [ -z "$MEETING_ID" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    MEETING_ID=$("$SCRIPT_DIR/zoom-check.sh")
fi

MERGED_FILE="/tmp/zoom_merged_${MEETING_ID}_${DATE}.txt"
CLEAN_FILE="/tmp/zoom_transcript_${MEETING_ID}_${DATE}.txt"

# Step 1: Bulk-fetch all names and texts via AppleScript
osascript << 'ASCRIPT' > "$MERGED_FILE"
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

# Step 2: Parse merged S:/T: lines into clean transcript
python3 - "$MERGED_FILE" "$CLEAN_FILE" << 'PYEOF'
import re, sys

merged_file = sys.argv[1]
clean_file = sys.argv[2]

with open(merged_file) as f:
    lines = [l for l in f.read().strip().split('\n') if l]

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
        flush()  # flush BEFORE updating speaker
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

result = "\n\n".join(output_blocks)
with open(clean_file, 'w') as f:
    f.write(result)
print(result)
PYEOF

echo "" >&2
echo "Saved: $CLEAN_FILE" >&2