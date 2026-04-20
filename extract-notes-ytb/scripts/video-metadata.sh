#!/usr/bin/env bash
# Fetch video metadata as JSON.
#
# Usage: video-metadata.sh URL
#
# Output: Raw yt-dlp JSON on stdout. Useful fields for notes:
#   .title           string
#   .channel         string (YouTube)
#   .uploader        string (Bilibili uses this)
#   .duration_string string, e.g. "12:34"
#   .chapters        array of {start_time, end_time, title} or null
#   .description     string
#
# Pipe into jq to extract only what you need, e.g.:
#   video-metadata.sh URL | jq '{title, channel, uploader, duration_string, chapters, description}'

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 URL" >&2
  exit 2
fi

URL="$1"
FIREFOX_PROFILE="${FIREFOX_PROFILE:-firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default}"

case "$URL" in
  *youtube.com*|*youtu.be*|*bilibili.com*|*b23.tv*)
    exec yt-dlp --cookies-from-browser "$FIREFOX_PROFILE" -j "$URL" 2>/dev/null
    ;;
  *)
    exec yt-dlp -j "$URL" 2>/dev/null
    ;;
esac
