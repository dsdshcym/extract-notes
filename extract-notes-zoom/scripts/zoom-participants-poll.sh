#!/usr/bin/env bash
# Poll the popped-out Zoom Participants window for roster + mute-state.
# Appends "epoch<TAB>name<TAB>muted" rows (muted: 1=muted 0=unmuted) to a
# timeline TSV until killed (SIGTERM).
#
# Usage: zoom-participants-poll.sh TIMELINE_TSV [INTERVAL]
#   TIMELINE_TSV : output file (header written if new)
#   INTERVAL     : seconds between polls (default 0.3 → ~3 Hz)
#
# Requires the Participants panel popped out into its own window so the AX
# handle survives screensharing. Names are read from the participants outline.
#
# AX path (verified): window "Participants (N)" → outline 1 of scroll area 1
#   → row → cell → static text (name) + image (desc "...audio muted/unmuted").

set -euo pipefail

TIMELINE="${1:?usage: zoom-participants-poll.sh TIMELINE_TSV [INTERVAL]}"
INTERVAL="${2:-0.3}"

[ -s "$TIMELINE" ] || printf 'epoch\tname\tmuted\n' > "$TIMELINE"

# AppleScript: emit one "name\tMUTED|UNMUTED" line (\r-terminated) per row.
read -r -d '' POLL_AS <<'ASCRIPT' || true
tell application "System Events"
  if not (exists process "zoom.us") then return ""
  tell process "zoom.us"
    if not (exists (window 1 whose name begins with "Participants")) then return ""
    tell (window 1 whose name begins with "Participants")
      if not (exists outline 1 of scroll area 1) then return ""
      tell outline 1 of scroll area 1
        set outText to ""
        repeat with r in rows
          repeat with c in (UI elements of r)
            set personName to ""
            set audioState to "UNKNOWN"
            repeat with sub in (UI elements of c)
              if (class of sub as text) is "static text" then set personName to (value of sub as text)
            end repeat
            repeat with sub in (UI elements of c)
              if (class of sub as text) is "image" then
                set micDesc to (description of sub)
                if micDesc contains "audio muted" then
                  set audioState to "MUTED"
                else if micDesc contains "audio unmuted" then
                  set audioState to "UNMUTED"
                end if
              end if
            end repeat
            if personName is not "" then set outText to outText & personName & (ASCII character 9) & audioState & (ASCII character 13)
          end repeat
        end repeat
        return outText
      end tell
    end tell
  end tell
end tell
ASCRIPT

cleanup() { exit 0; }
trap cleanup TERM INT

while true; do
  epoch=$(date +%s.%N)
  raw=$(osascript -e "$POLL_AS" 2>/dev/null || true)
  if [ -n "$raw" ]; then
    # Rows terminated by \r, fields split on \t.
    printf '%s' "$raw" | tr '\r' '\n' | while IFS=$'\t' read -r name state; do
      [ -z "$name" ] && continue
      case "$state" in
        MUTED)   m=1 ;;
        UNMUTED) m=0 ;;
        *)       continue ;;  # unknown state → don't log a guess
      esac
      printf '%s\t%s\t%s\n' "$epoch" "$name" "$m" >> "$TIMELINE"
    done
  fi
  sleep "$INTERVAL"
done
