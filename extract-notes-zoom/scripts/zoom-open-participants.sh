#!/usr/bin/env bash
# Ensure the Zoom Participants panel is open as its own window, so the AX
# poller can read the roster + mute-state (and keep reading it during
# screensharing). Idempotent: does nothing if the window is already present.
#
# Usage: zoom-open-participants.sh
# Exit: 0 if the Participants window exists afterward, 1 otherwise.
#
# Note: the "Show participants" / "Close participants" menu item is a TOGGLE,
# so we must check for the window before clicking, never click blindly.

set -euo pipefail

participants_window_exists() {
  osascript -e '
  tell application "System Events"
    if not (exists process "zoom.us") then return "no"
    tell process "zoom.us"
      if exists (window 1 whose name begins with "Participants") then return "yes"
    end tell
  end tell
  return "no"' 2>/dev/null
}

if [ "$(participants_window_exists)" = "yes" ]; then
  exit 0
fi

# Click the (toggle) menu item to open it. Its label is "Show participants"
# when closed; match by prefix in case Zoom relabels it.
osascript -e '
tell application "System Events"
  tell process "zoom.us"
    repeat with mi in menu items of menu 1 of (menu bar item "View" of menu bar 1)
      try
        if (name of mi) is "Show participants" then
          click mi
          exit repeat
        end if
      end try
    end repeat
  end tell
end tell' 2>/dev/null || true

# Give the window a moment to appear.
for _ in 1 2 3 4 5 6; do
  [ "$(participants_window_exists)" = "yes" ] && exit 0
  sleep 0.25
done

echo "Could not open Participants window." >&2
exit 1
