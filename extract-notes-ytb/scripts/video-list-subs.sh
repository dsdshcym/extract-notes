#!/usr/bin/env bash
# List available subtitles for a video.
#
# Usage: video-list-subs.sh URL
#
# Output: yt-dlp --list-subs output (first 30 lines) on stdout. Two sections:
#   "Available subtitles"         = manual/official (human-created, highest quality)
#   "Available automatic captions" = auto-generated
#
# Within auto-generated, lang codes tell you translation status:
#   zh, en (no suffix)            = original auto-caption
#   zh-Hans-zh, en-zh (suffix)    = auto-TRANSLATED (lower quality, last resort)
#
# Pick a LANG_CODE from this output and pass it to video-download-subs.sh.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 URL" >&2
  exit 2
fi

URL="$1"
FIREFOX_PROFILE="firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"

case "$URL" in
  *youtube.com*|*youtu.be*|*bilibili.com*|*b23.tv*)
    yt-dlp --cookies-from-browser "$FIREFOX_PROFILE" --list-subs "$URL" 2>&1 | head -30
    ;;
  *)
    yt-dlp --list-subs "$URL" 2>&1 | head -30
    ;;
esac
