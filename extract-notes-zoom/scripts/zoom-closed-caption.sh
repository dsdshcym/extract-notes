#!/usr/bin/env bash
# Stream Zoom closed captions to a file while a meeting is happening.
# Use this for meetings WITHOUT host-side transcription enabled (no Transcript
# panel available) — captions are read from the in-window CC overlay instead.
#
# Usage: zoom-closed-caption.sh [--daemon] [--notes-dir=DIR] [MEETING_ID] [INTERVAL]
#   --daemon: run forever, auto-detecting meetings (for launchd)
#   --notes-dir=DIR: save extracted notes as org files in DIR (default: no file output)
#   MEETING_ID: numeric meeting ID (default: from invite link or "unknown")
#   INTERVAL: seconds between polls (default: 1)
#
# Output: continuously updates /tmp/zoom_cc_{MEETING_ID}_{DATE}_live.txt
#
# Accessibility path:
#   window "Zoom Meeting" → scroll area 1 → table 1 (desc="Closed caption subtitles")
#   each row → cell 1 → image 1 (desc=speaker) + static text 1 (value=running text)
#
# Heads-up: Zoom may move the CC overlay above the viewport in a near-term release.
# When that happens the locator at line 60 (find_cc_table) is the only thing that
# should need updating.

set -euo pipefail

DAEMON=false
NOTES_DIR=""

while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --daemon) DAEMON=true; shift ;;
        --notes-dir=*) NOTES_DIR="${1#--notes-dir=}"; shift ;;
        --notes-dir) NOTES_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$NOTES_DIR" ]; then
    NOTES_DIR="${NOTES_DIR/#\~/$HOME}"
    mkdir -p "$NOTES_DIR"
fi

MEETING_ID="${1:-}"
INTERVAL="${2:-1}"
IDLE_INTERVAL=5

# --- Shared functions ---

notify() {
    local title="$1" message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

meeting_window_exists() {
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

cc_visible() {
    # "Hide captions" button is present only when CC is currently shown.
    # Zoom buttons have no name; match on AX description instead.
    osascript -e '
    tell application "System Events"
        tell process "zoom.us"
            tell window "Zoom Meeting"
                if (count of (every button whose description is "Hide captions")) > 0 then return "yes"
            end tell
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
        tell window "Zoom Meeting"
            tell table 1 of scroll area 1
                set speakers to description of every image of every UI element of every row
                set texts to value of every static text of every UI element of every row
                set rowCount to count of speakers
            end tell
        end tell
    end tell
end tell

set output to ""
repeat with i from 1 to rowCount
    set sp to item i of speakers
    set tx to item i of texts
    set spStr to ""
    set txStr to ""
    if sp is not missing value then set spStr to sp as text
    if tx is not missing value then set txStr to tx as text
    -- Use a delimiter unlikely to appear in CC text. \t separates speaker/text;
    -- \r terminates each row so embedded newlines in CC don't break parsing.
    set output to output & spStr & (ASCII character 9) & txStr & (ASCII character 13)
end repeat
return output
ASCRIPT
}

# --- Stream one meeting ---

stream_meeting() {
    local mid="$1"
    local date_tag
    date_tag=$(date +%Y%m%d)
    local live_file="/tmp/zoom_cc_${mid}_${date_tag}_live.txt"
    local state_file="/tmp/zoom_cc_${mid}_${date_tag}_state.tsv"
    local curr_raw
    curr_raw=$(mktemp)
    local prev_hash="" had_missing=0

    : > "$live_file"
    : > "$state_file"

    echo "[$(date +%H:%M:%S)] Streaming CC to: $live_file" >&2
    notify "Zoom Closed Caption" "Streaming meeting $mid → $live_file"

    while true; do
        if [ "$(meeting_window_exists)" != "yes" ]; then
            echo "[$(date +%H:%M:%S)] Zoom Meeting window closed. Meeting ended." >&2
            break
        fi

        if [ "$(cc_visible)" != "yes" ]; then
            echo "[$(date +%H:%M:%S)] Captions hidden — turn them back on (or meeting ended)." >&2
            sleep "$INTERVAL"
            continue
        fi

        if ! fetch_raw > "$curr_raw" 2>/dev/null; then
            sleep "$INTERVAL"
            continue
        fi

        # Detect virtualized rows scrolled out of view.
        if grep -q "missing value" "$curr_raw"; then
            if [ "$had_missing" -eq 0 ]; then
                echo "[$(date +%H:%M:%S)] ⚠ Some CC rows are virtualized — scroll caption area to refresh" >&2
                notify "Zoom CC ⚠" "Scroll caption area — some rows are off-viewport"
                had_missing=1
            fi
        else
            had_missing=0
        fi

        local curr_hash
        curr_hash=$(md5 -q "$curr_raw" 2>/dev/null || md5sum "$curr_raw" | cut -d' ' -f1)
        if [ "$curr_hash" != "$prev_hash" ]; then
            python3 - "$curr_raw" "$state_file" "$live_file" << 'PYEOF'
import sys, os, time

raw_path, state_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(raw_path, newline='') as f:
    raw = f.read()

# Each row is terminated by \r; fields within a row split on \t.
rows = [r for r in raw.split('\r') if r]
current = []
for r in rows:
    parts = r.split('\t', 1)
    sp = parts[0].strip() if parts else ''
    tx = parts[1].strip() if len(parts) > 1 else ''
    current.append((sp, tx))

# Load prior state: index<TAB>first_seen<TAB>speaker<TAB>text
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line: continue
            parts = line.split('\t', 3)
            if len(parts) < 4: continue
            idx, ts, sp, tx = parts
            state[int(idx)] = {'ts': ts, 'speaker': sp, 'text': tx}

now = time.strftime('%H:%M:%S')

# Update state: keep the longest non-empty text we've seen per row index.
# If a row reappears with a different speaker, we treat it as the same slot
# and overwrite (Zoom rotating its row buffer would surface here).
for i, (sp, tx) in enumerate(current, start=1):
    if not sp and not tx:
        continue  # virtualized / missing
    if sp == 'missing value': sp = ''
    if tx == 'missing value': tx = ''
    prev = state.get(i)
    if prev is None:
        state[i] = {'ts': now, 'speaker': sp, 'text': tx}
    else:
        # Speaker name from the row might initially be empty if the image
        # hadn't rendered; backfill if we now have one.
        if sp and not prev['speaker']:
            prev['speaker'] = sp
        # Keep the longer/newer text. CC text monotonically grows per row.
        if len(tx) >= len(prev['text']):
            prev['text'] = tx

# Persist state, ordered by row index.
with open(state_path, 'w') as f:
    for i in sorted(state):
        r = state[i]
        f.write(f"{i}\t{r['ts']}\t{r['speaker']}\t{r['text']}\n")

# Render human-readable output.
blocks = []
for i in sorted(state):
    r = state[i]
    speaker = r['speaker'] or 'Unknown'
    blocks.append(f"{speaker} [{r['ts']}]:\n{r['text']}")

with open(out_path, 'w') as f:
    f.write("\n\n".join(blocks))
    if blocks:
        f.write("\n")
PYEOF
            local row_count
            row_count=$(wc -l < "$state_file" 2>/dev/null | tr -d ' ' || echo 0)
            echo "[$(date +%H:%M:%S)] ${row_count} CC rows (updated)" >&2
            prev_hash="$curr_hash"
        fi

        sleep "$INTERVAL"
    done

    rm -f "$curr_raw"

    local final_rows=0
    [ -f "$state_file" ] && final_rows=$(wc -l < "$state_file" | tr -d ' ')
    echo "[$(date +%H:%M:%S)] Final CC: $live_file ($final_rows rows)" >&2
    notify "Zoom CC" "Meeting ended — $final_rows rows saved to $live_file"

    if [ "$DAEMON" = true ] && [ "$final_rows" -gt 0 ]; then
        (
            echo "[$(date +%H:%M:%S)] Extracting notes via claude -p (background) ..." >&2
            notify "Zoom CC" "Extracting notes from $live_file ..."

            local json_output
            json_output=$(cd "$HOME/Org" && claude -p "/extract-notes-zoom from $live_file" \
                    --settings "$HOME/.claude/settings.work.json" \
                    --output-format json 2>/dev/null) || true

            local session_id notes_text
            session_id=$(echo "$json_output" | jq -r '.session_id // empty' 2>/dev/null) || true
            notes_text=$(echo "$json_output" | jq -r '.result // empty' 2>/dev/null) || true

            if [ -n "$session_id" ] && [ -n "$notes_text" ]; then
                echo "[$(date +%H:%M:%S)] Notes extracted. Resume: claude -r $session_id" >&2
                if [ -n "$NOTES_DIR" ]; then
                    local notes_file="${NOTES_DIR}/$(date +%Y-%m-%d)_${mid}.org"
                    echo "$notes_text" > "$notes_file"
                    echo "[$(date +%H:%M:%S)] Notes saved to $notes_file" >&2
                    notify "Zoom CC Notes Ready" "$notes_file"
                else
                    notify "Zoom CC Notes Ready" "claude -r $session_id"
                fi
            else
                echo "[$(date +%H:%M:%S)] Note extraction failed or no session ID" >&2
                notify "Zoom CC Notes" "Extraction failed — CC at $live_file"
            fi
        ) &
    fi
}

# --- Main ---

if [ "$DAEMON" = true ]; then
    echo "[$(date +%H:%M:%S)] Daemon mode: waiting for Zoom Meeting window with captions..." >&2

    while true; do
        if [ "$(meeting_window_exists)" = "yes" ] && [ "$(cc_visible)" = "yes" ]; then
            mid="${MEETING_ID:-$(get_meeting_id)}"
            stream_meeting "$mid"
            echo "[$(date +%H:%M:%S)] Waiting for next meeting..." >&2
        fi
        sleep "$IDLE_INTERVAL"
    done
else
    if [ "$(meeting_window_exists)" != "yes" ]; then
        echo "No Zoom Meeting window found. Start a meeting first." >&2
        exit 1
    fi

    if [ "$(cc_visible)" != "yes" ]; then
        echo "Closed captions are not visible. Click 'Show captions' in the meeting toolbar." >&2
        exit 1
    fi

    mid="${MEETING_ID:-$(get_meeting_id)}"
    stream_meeting "$mid"
fi
