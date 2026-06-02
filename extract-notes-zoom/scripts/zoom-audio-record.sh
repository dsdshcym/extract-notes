#!/usr/bin/env bash
# Record a Zoom meeting's audio + mute timeline, then transcribe and extract
# notes after it ends. Screenshare-proof alternative to zoom-closed-caption.sh:
# captures audio independently of Zoom's UI tree, so it keeps working while you
# share your screen (when the in-meeting caption table disappears).
#
# Usage: zoom-audio-record.sh [--daemon] [--notes-dir=DIR] [MEETING_ID]
#   --daemon        : run forever, auto-detecting meetings (for launchd)
#   --notes-dir=DIR : save extracted notes as org files in DIR
#   MEETING_ID      : numeric id (default: from invite link or "unknown")
#
# Requires: bin/zoom-audio-capture (compile zoom-audio-capture.swift), whisper-cli,
# ffmpeg, Screen Recording + Accessibility permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_BIN="$SCRIPT_DIR/bin/zoom-audio-capture"
POLLER="$SCRIPT_DIR/zoom-participants-poll.sh"
OPEN_PANEL="$SCRIPT_DIR/zoom-open-participants.sh"
MERGE="$SCRIPT_DIR/zoom-audio-merge.py"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.whisper/ggml-large-v3.bin}"

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
[ -n "$NOTES_DIR" ] && { NOTES_DIR="${NOTES_DIR/#\~/$HOME}"; mkdir -p "$NOTES_DIR"; }
MEETING_ID="${1:-}"
IDLE_INTERVAL=5

notify() { osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true; }

meeting_window_exists() {
  osascript -e '
  tell application "System Events"
    if not (exists process "zoom.us") then return "no"
    tell process "zoom.us"
      if exists window "Zoom Meeting" then return "yes"
    end tell
  end tell
  return "no"' 2>/dev/null
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
  return inviteLink' 2>/dev/null | grep -oE '[0-9]{9,}' || echo "unknown"
}

record_meeting() {
  local mid="$1" date_tag
  date_tag=$(date +%Y%m%d_%H%M%S)
  local base="/tmp/zoom_audio_${mid}_${date_tag}"
  local others_wav="${base}_others.wav" me_wav="${base}_me.wav"
  local start_epoch="${base}_start.txt" timeline="${base}_timeline.tsv"
  local me_prefix="${base}_me" others_prefix="${base}_others"
  local transcript="${base}_transcript.txt"

  echo "[$(date +%H:%M:%S)] Recording meeting $mid → $base" >&2
  notify "Zoom Audio" "Recording meeting $mid"

  # Open the Participants panel so the poller can read roster + mute-state
  # (and keep reading it during screensharing). Idempotent.
  bash "$OPEN_PANEL" || echo "[$(date +%H:%M:%S)] ⚠ could not open Participants panel" >&2

  "$CAPTURE_BIN" "$others_wav" "$me_wav" "$start_epoch" 2>>"${base}.log" &
  local cap_pid=$!
  bash "$POLLER" "$timeline" 0.3 &
  local poll_pid=$!

  while [ "$(meeting_window_exists)" = "yes" ]; do sleep 2; done
  echo "[$(date +%H:%M:%S)] Meeting ended — stopping capture." >&2
  kill -TERM "$cap_pid" 2>/dev/null || true
  kill -TERM "$poll_pid" 2>/dev/null || true
  wait "$cap_pid" 2>/dev/null || true
  wait "$poll_pid" 2>/dev/null || true

  if [ ! -s "$others_wav" ] && [ ! -s "$me_wav" ]; then
    echo "[$(date +%H:%M:%S)] No audio captured — nothing to transcribe." >&2
    return
  fi

  local audio_start; audio_start=$(cat "$start_epoch" 2>/dev/null || echo 0)

  echo "[$(date +%H:%M:%S)] Transcribing (whisper)..." >&2
  [ -s "$me_wav" ] && whisper-cli -m "$WHISPER_MODEL" -l auto -f "$me_wav" \
       -ocsv -of "$me_prefix" --max-context 0 >/dev/null 2>&1 || true
  [ -s "$others_wav" ] && whisper-cli -m "$WHISPER_MODEL" -l auto -f "$others_wav" \
       -ocsv -of "$others_prefix" --max-context 0 >/dev/null 2>&1 || true

  python3 "$MERGE" \
    --me "${me_prefix}.csv" \
    --others "${others_prefix}.csv" \
    --timeline "$timeline" \
    --audio-start "$audio_start" > "$transcript" || true

  echo "[$(date +%H:%M:%S)] Transcript: $transcript" >&2
  notify "Zoom Audio" "Transcript ready: $transcript"

  if [ "$DAEMON" = true ] && [ -s "$transcript" ]; then
    (
      echo "[$(date +%H:%M:%S)] Extracting notes via claude -p ..." >&2
      local json sid notes
      json=$(cd "$HOME/Org" && claude -p "/extract-notes-zoom from $transcript" \
             --settings "$HOME/.claude/settings.work.json" --output-format json 2>/dev/null) || true
      sid=$(echo "$json" | jq -r '.session_id // empty' 2>/dev/null) || true
      notes=$(echo "$json" | jq -r '.result // empty' 2>/dev/null) || true
      if [ -n "$notes" ]; then
        if [ -n "$NOTES_DIR" ]; then
          local nf="${NOTES_DIR}/$(date +%Y-%m-%d)_${mid}.org"
          echo "$notes" > "$nf"
          echo "[$(date +%H:%M:%S)] Notes saved to $nf" >&2
          notify "Zoom Audio Notes Ready" "$nf"
        else
          notify "Zoom Audio Notes Ready" "claude -r $sid"
        fi
      else
        notify "Zoom Audio Notes" "Extraction failed — transcript at $transcript"
      fi
    ) &
  fi
}

if [ "$DAEMON" = true ]; then
  echo "[$(date +%H:%M:%S)] Daemon: waiting for Zoom Meeting window..." >&2
  while true; do
    if [ "$(meeting_window_exists)" = "yes" ]; then
      mid="${MEETING_ID:-$(get_meeting_id)}"
      record_meeting "$mid"
      echo "[$(date +%H:%M:%S)] Waiting for next meeting..." >&2
    fi
    sleep "$IDLE_INTERVAL"
  done
else
  [ "$(meeting_window_exists)" = "yes" ] || { echo "No Zoom Meeting window. Start a meeting first." >&2; exit 1; }
  mid="${MEETING_ID:-$(get_meeting_id)}"
  record_meeting "$mid"
fi
