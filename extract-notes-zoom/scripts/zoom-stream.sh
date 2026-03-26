#!/usr/bin/env bash
# Stream Zoom transcript to a file as the meeting happens.
# Polls the standalone Transcript window every INTERVAL seconds,
# re-extracting the full transcript each time (handles in-place updates
# from ongoing speech recognition and concurrent speakers).
#
# Usage: zoom-stream.sh [--daemon] [MEETING_ID] [INTERVAL]
#   --daemon: run forever, auto-detecting meetings (for launchd)
#   MEETING_ID: numeric meeting ID (default: from invite link or "unknown")
#   INTERVAL: seconds between polls (default: 1)
#
# Single-meeting mode: requires standalone "Transcript" window popped out.
# Daemon mode: waits for Transcript window, streams, repeats on next meeting.
# TODO: create launchd agent (com.zoom-transcript.daemon.plist) to auto-start on login
#
# Output: continuously updates /tmp/zoom_transcript_{MEETING_ID}_{DATE}_live.txt

set -euo pipefail

DAEMON=false
if [ "${1:-}" = "--daemon" ]; then
    DAEMON=true
    shift
fi

MEETING_ID="${1:-}"
INTERVAL="${2:-1}"
IDLE_INTERVAL=5  # seconds between checks when waiting for a meeting

# --- Shared functions ---

notify() {
    local title="$1" message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

transcript_window_exists() {
    osascript -e '
    tell application "System Events"
        if not (exists process "zoom.us") then return "no"
        tell process "zoom.us"
            if exists window "Transcript" then return "yes"
        end tell
    end tell
    return "no"
    ' 2>/dev/null
}

get_meeting_id() {
    osascript -e '
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
    ' 2>/dev/null | grep -oE '[0-9]{9,}' || echo "unknown"
}

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

# --- Stream one meeting ---

stream_meeting() {
    local mid="$1"
    local date_tag
    date_tag=$(date +%Y%m%d)
    local live_file="/tmp/zoom_transcript_${mid}_${date_tag}_live.txt"
    local curr_raw
    curr_raw=$(mktemp)
    local prev_hash="" prev_line_count=0

    > "$live_file"

    echo "[$(date +%H:%M:%S)] Streaming transcript to: $live_file" >&2
    notify "Zoom Transcript" "Streaming meeting $mid → $live_file"

    while true; do
        if [ "$(transcript_window_exists)" != "yes" ]; then
            echo "[$(date +%H:%M:%S)] Transcript window closed. Meeting ended." >&2
            break
        fi

        fetch_raw > "$curr_raw" 2>/dev/null || true

        local curr_hash
        curr_hash=$(md5 -q "$curr_raw" 2>/dev/null || md5sum "$curr_raw" | cut -d' ' -f1)
        if [ "$curr_hash" != "$prev_hash" ]; then
            local parsed
            parsed=$(parse_full "$curr_raw" || true)
            if [ -n "$parsed" ]; then
                local line_count
                line_count=$(echo "$parsed" | wc -l | tr -d ' ')

                # Detect transcript shrinkage (network disconnect / window reset)
                if [ "$prev_line_count" -gt 0 ] && [ "$line_count" -lt $((prev_line_count / 2)) ]; then
                    local back_file="${live_file}.back"
                    cp "$live_file" "$back_file"
                    echo "[$(date +%H:%M:%S)] ⚠ Transcript shrank from ${prev_line_count} to ${line_count} lines (disconnect?). Backed up to ${back_file}" >&2
                    notify "Zoom Transcript" "⚠ Disconnect detected — backed up ${prev_line_count} lines"
                fi

                echo "$parsed" > "$live_file"
                prev_line_count="$line_count"
                echo "[$(date +%H:%M:%S)] ${line_count} lines (updated)" >&2
            fi
            prev_hash="$curr_hash"
        fi

        sleep "$INTERVAL"
    done

    rm -f "$curr_raw"

    local final_lines
    final_lines=$(wc -l < "$live_file" | tr -d ' ')
    echo "[$(date +%H:%M:%S)] Final transcript: $live_file ($final_lines lines)" >&2
    notify "Zoom Transcript" "Meeting ended — $final_lines lines saved to $live_file"

    # Auto-extract notes in daemon mode (background — don't block next meeting)
    if [ "$DAEMON" = true ] && [ "$final_lines" -gt 0 ]; then
        (
            echo "[$(date +%H:%M:%S)] Extracting notes via claude -p (background) ..." >&2
            notify "Zoom Transcript" "Extracting notes from $live_file ..."

            local session_id
            session_id=$(cd "$HOME/Org" && claude -p "/extract-notes-zoom from $live_file" \
                    --settings "$HOME/.claude/settings.work.json" \
                    --output-format json 2>/dev/null \
                | jq -r '.session_id // empty' 2>/dev/null) || true

            if [ -n "$session_id" ]; then
                echo "[$(date +%H:%M:%S)] Notes extracted. Resume: claude -r $session_id" >&2
                notify "Zoom Notes Ready" "claude -r $session_id"
            else
                echo "[$(date +%H:%M:%S)] Note extraction failed or no session ID" >&2
                notify "Zoom Notes" "Extraction failed — transcript at $live_file"
            fi
        ) &
    fi
}

# --- Main ---

if [ "$DAEMON" = true ]; then
    echo "[$(date +%H:%M:%S)] Daemon mode: waiting for Zoom Transcript window..." >&2

    while true; do
        if [ "$(transcript_window_exists)" = "yes" ]; then
            mid="${MEETING_ID:-$(get_meeting_id)}"
            stream_meeting "$mid"
            # Reset for next meeting
            echo "[$(date +%H:%M:%S)] Waiting for next meeting..." >&2
        fi
        sleep "$IDLE_INTERVAL"
    done
else
    # Single-meeting mode (original behavior)
    if [ "$(transcript_window_exists)" != "yes" ]; then
        echo "No standalone Transcript window found. Please pop out the transcript panel in Zoom." >&2
        exit 1
    fi

    mid="${MEETING_ID:-$(get_meeting_id)}"
    stream_meeting "$mid"
fi
