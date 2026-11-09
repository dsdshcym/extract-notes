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
#   window "Zoom Meeting" or "Zoom Webinar" → scroll area 1 → table 1
#   (desc="Closed caption subtitles"). Meeting rows: avatar image (desc=speaker)
#   + 1 static text. Webinar rows: no avatar, 2 static texts (speaker, caption).
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

# Every AppleScript call MUST go through osa() so a wedged Accessibility server
# can't hang the stream forever. A single unguarded `entire contents` query on a
# Zoom window has been observed to wedge System Events *globally* (even Finder
# queries hang) until it's force-restarted — so: always time out, and never use
# `entire contents` anywhere in this script.
OSA_TIMEOUT="${OSA_TIMEOUT:-8}"
_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

# Run an AppleScript (from stdin, or via -e) under a hard timeout.
# Prints the script's stdout; returns 124 if it timed out.
osa() {
    if [ -n "$_TIMEOUT_BIN" ]; then
        "$_TIMEOUT_BIN" "$OSA_TIMEOUT" osascript "$@" 2>/dev/null
    else
        osascript "$@" 2>/dev/null
    fi
}

# Titles Zoom gives the main in-call window. A regular meeting is "Zoom Meeting";
# a webinar is "Zoom Webinar". Both hold the same toolbar and CC table, so the
# script treats them identically. Add a title here if Zoom introduces another.
# (AppleScript list literal, interpolated into the scripts below.)
CC_WINDOW_TITLES='{"Zoom Meeting", "Zoom Webinar"}'

notify() {
    local title="$1" message="$2"
    osa -e "display notification \"$message\" with title \"$title\"" || true
}

# Is a meeting still in progress? Returns: yes | no | timeout
#
# Detect via the "Meeting" menu-bar item, NOT the "Zoom Meeting" window: while
# the user is screen sharing, Zoom destroys the "Zoom Meeting" window (replacing
# it with share toolbars + a floating overlay), but the "Meeting" menu persists
# the whole time. Keying meeting-presence off the window made the stream think
# the meeting had ended the moment sharing started.
meeting_active() {
    local out rc=0
    out=$(osa <<ASCRIPT
tell application "System Events"
    if not (exists process "zoom.us") then return "no"
    tell process "zoom.us"
        repeat with n in ${CC_WINDOW_TITLES}
            if exists window (n as text) then return "yes"
        end repeat
        try
            if exists menu bar item "Meeting" of menu bar 1 then return "yes"
        end try
    end tell
end tell
return "no"
ASCRIPT
) || rc=$?
    if [ "$rc" -eq 124 ]; then echo "timeout"; return 0; fi
    [ "$out" = "yes" ] && echo "yes" || echo "no"
}

# Is the in-meeting CC table available to capture? Returns: yes | no | timeout
#
# Requires the "Zoom Meeting" window AND its "Hide captions" button (present only
# when captions are showing). Returns "no" during screen share (window gone) or
# when the user has hidden captions — in both cases we pause capture but keep the
# accumulated transcript. Zoom buttons have no AX name, so match on description.
cc_capture_ready() {
    local out rc=0
    out=$(osa <<ASCRIPT
tell application "System Events"
    tell process "zoom.us"
        repeat with n in ${CC_WINDOW_TITLES}
            if exists window (n as text) then
                tell window (n as text)
                    if (count of (every button whose description is "Hide captions")) > 0 then return "yes"
                end tell
            end if
        end repeat
    end tell
end tell
return "no"
ASCRIPT
) || rc=$?
    if [ "$rc" -eq 124 ]; then echo "timeout"; return 0; fi
    [ "$out" = "yes" ] && echo "yes" || echo "no"
}

get_meeting_id() {
    osa -e '
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
    ' | grep -oE '[0-9]{9,}' || echo "unknown"
}

fetch_raw() {
    osa << ASCRIPT
set LF to ASCII character 10

set winName to ""
tell application "System Events"
    tell process "zoom.us"
        repeat with n in ${CC_WINDOW_TITLES}
            if exists window (n as text) then
                set winName to n as text
                exit repeat
            end if
        end repeat
        if winName is "" then error "no Zoom call window"
        tell window winName
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
    set spStr to ""
    if sp is not missing value then set spStr to sp as text

    -- A row is a list of cells, each a list of static texts. Meeting rows have
    -- one text (the caption; speaker is the avatar image's description). Webinar
    -- rows have no avatar and two texts: speaker name, then caption. Keep the
    -- texts separate (unit separator, ASCII 31) so the parser can tell them apart
    -- instead of getting them glued together.
    set txParts to {}
    repeat with cellTexts in (item i of texts)
        repeat with t in cellTexts
            if t is missing value then
                set end of txParts to "missing value"
            else
                set end of txParts to (t as text)
            end if
        end repeat
    end repeat
    set AppleScript's text item delimiters to (ASCII character 31)
    set txStr to txParts as text
    set AppleScript's text item delimiters to ""

    -- ASCII 9 (tab) separates speaker from texts; ASCII 13 (CR) terminates each
    -- row so newlines inside CC text don't break parsing.
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
    local ended_strikes=0 share_notified=0 timeout_notified=0
    # Require several consecutive "not in a meeting" reads before declaring the
    # meeting over, so a transient AX hiccup (or a brief window flip during a
    # share transition) can't end the stream prematurely.
    local ended_threshold=3

    : > "$live_file"
    : > "$state_file"

    echo "[$(date +%H:%M:%S)] Streaming CC to: $live_file" >&2
    notify "Zoom Closed Caption" "Streaming meeting $mid → $live_file"

    while true; do
        local active
        active=$(meeting_active)

        if [ "$active" = "timeout" ]; then
            # Accessibility server busy/wedged — transient. Never treat as
            # "ended": keep the accumulated transcript and retry.
            if [ "$timeout_notified" -eq 0 ]; then
                echo "[$(date +%H:%M:%S)] ⚠ AX query timed out — retrying (transcript preserved)" >&2
                timeout_notified=1
            fi
            sleep "$INTERVAL"
            continue
        fi
        timeout_notified=0

        if [ "$active" != "yes" ]; then
            ended_strikes=$((ended_strikes + 1))
            if [ "$ended_strikes" -ge "$ended_threshold" ]; then
                echo "[$(date +%H:%M:%S)] Meeting ended (no Zoom Meeting window or Meeting menu)." >&2
                break
            fi
            sleep "$INTERVAL"
            continue
        fi
        ended_strikes=0

        if [ "$(cc_capture_ready)" != "yes" ]; then
            # Screen share active (Zoom Meeting window destroyed) or captions
            # hidden. The CC overlay shown during a share is GPU-rendered and not
            # in the accessibility tree, so there's nothing to capture. Pause —
            # but keep the accumulated transcript; Zoom resets its own caption
            # table across a share, so our state file is the only record of
            # pre-share captions. Capture auto-resumes when the window returns.
            if [ "$share_notified" -eq 0 ]; then
                echo "[$(date +%H:%M:%S)] CC table unavailable (screen share or captions hidden) — pausing capture, transcript preserved" >&2
                notify "Zoom CC" "Captions paused (screen share?) — transcript preserved"
                share_notified=1
            fi
            sleep "$INTERVAL"
            continue
        fi
        if [ "$share_notified" -eq 1 ]; then
            echo "[$(date +%H:%M:%S)] CC table available again — resuming capture" >&2
            share_notified=0
        fi

        if ! fetch_raw > "$curr_raw"; then
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

# State is an append-only chronological history. Identity is by content
# (speaker + text-prefix), not by AX table position — Zoom virtualizes the
# table and rotates row indices once the meeting exceeds ~100 turns, so
# index-based identity scrambles order and overwrites earlier turns.
#
# State file format (TSV):
#   seq <TAB> started_at <TAB> finalized <TAB> speaker <TAB> text
# - finalized: "1" once a newer row has appeared after it (text frozen);
#   "0" for the still-growing tail row.

with open(raw_path, newline='') as f:
    raw = f.read()

# Each row is terminated by \r; fields within a row split on \t.
visible = []
for r in (r for r in raw.split('\r') if r):
    parts = r.split('\t', 1)
    sp = parts[0].strip() if parts else ''
    texts = [t.strip() for t in (parts[1] if len(parts) > 1 else '').split('\x1f')]
    texts = [t for t in texts if t and t != 'missing value']
    if sp == 'missing value': sp = ''
    # Webinar rows carry no avatar, so the speaker is the first static text and
    # the caption is whatever follows it. Meeting rows have one text (caption).
    if not sp and len(texts) >= 2:
        sp, texts = texts[0], texts[1:]
    tx = ' '.join(texts)
    if not sp and not tx:
        continue  # virtualized / off-viewport
    visible.append({'speaker': sp, 'text': tx})

# Load existing history.
history = []
if os.path.exists(state_path):
    with open(state_path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line: continue
            parts = line.split('\t', 4)
            if len(parts) < 5: continue
            seq, ts, fin, sp, tx = parts
            history.append({
                'seq': int(seq), 'ts': ts, 'finalized': fin == '1',
                'speaker': sp, 'text': tx,
            })

now = time.strftime('%H:%M:%S')

def matches_live(stored, vis):
    # Stored speaker may be empty if image hadn't rendered when first seen —
    # in that case match purely on text-prefix and backfill the name later.
    if stored['speaker'] and vis['speaker'] and stored['speaker'] != vis['speaker']:
        return False
    if not stored['text']:
        return True
    # Use a 30-char prefix as the fingerprint: stable enough that mid-row ASR
    # corrections don't break identity, distinctive enough to disambiguate.
    n = min(30, len(stored['text']))
    return vis['text'].startswith(stored['text'][:n])

if not visible:
    pass  # nothing to do
elif not history:
    # First poll with content: take everything; finalize all but the tail.
    for i, v in enumerate(visible):
        history.append({
            'seq': i + 1, 'ts': now, 'finalized': i < len(visible) - 1,
            'speaker': v['speaker'], 'text': v['text'],
        })
else:
    live = history[-1]
    # Locate our live row in visible. Search from the bottom — the live row
    # is always the latest at the time it was last seen, so ties prefer the
    # most recent visible match.
    live_pos = -1
    for j in range(len(visible) - 1, -1, -1):
        if matches_live(live, visible[j]):
            live_pos = j
            break

    if live_pos < 0:
        # Lost continuity — live row scrolled out, or polling was too slow
        # and Zoom rotated its buffer past it. Append everything visible as
        # new history with a warning marker. Better duplication than loss.
        sys.stderr.write(
            f"[{now}] ⚠ live row not found in visible "
            f"(last seq {live['seq']}); appending {len(visible)} rows\n"
        )
        live['finalized'] = True
        next_seq = live['seq'] + 1
        for i, v in enumerate(visible):
            history.append({
                'seq': next_seq + i, 'ts': now,
                'finalized': i < len(visible) - 1,
                'speaker': v['speaker'], 'text': v['text'],
            })
    else:
        # Update live row from current snapshot.
        if not live['speaker'] and visible[live_pos]['speaker']:
            live['speaker'] = visible[live_pos]['speaker']
        live['text'] = visible[live_pos]['text']

        # Append rows after live_pos as new history entries.
        next_seq = live['seq'] + 1
        new_rows = visible[live_pos + 1:]
        if new_rows:
            live['finalized'] = True
            for i, v in enumerate(new_rows):
                history.append({
                    'seq': next_seq + i, 'ts': now,
                    'finalized': i < len(new_rows) - 1,
                    'speaker': v['speaker'], 'text': v['text'],
                })

# Persist state.
with open(state_path, 'w') as f:
    for r in history:
        fin = '1' if r['finalized'] else '0'
        f.write(f"{r['seq']}\t{r['ts']}\t{fin}\t{r['speaker']}\t{r['text']}\n")

# Render output in chronological order.
with open(out_path, 'w') as f:
    blocks = [
        f"{r['speaker'] or 'Unknown'} [{r['ts']}]:\n{r['text']}"
        for r in history
    ]
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
        if [ "$(meeting_active)" = "yes" ] && [ "$(cc_capture_ready)" = "yes" ]; then
            mid="${MEETING_ID:-$(get_meeting_id)}"
            stream_meeting "$mid"
            echo "[$(date +%H:%M:%S)] Waiting for next meeting..." >&2
        fi
        sleep "$IDLE_INTERVAL"
    done
else
    if [ "$(meeting_active)" != "yes" ]; then
        echo "No Zoom meeting in progress. Start a meeting first." >&2
        exit 1
    fi

    if [ "$(cc_capture_ready)" != "yes" ]; then
        echo "Closed captions are not visible. Click 'Show captions' in the meeting toolbar." >&2
        exit 1
    fi

    mid="${MEETING_ID:-$(get_meeting_id)}"
    stream_meeting "$mid"
fi
