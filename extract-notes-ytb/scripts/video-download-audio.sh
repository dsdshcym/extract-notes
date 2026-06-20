#!/usr/bin/env bash
# Download best audio stream from a video.
#
# Usage: video-download-audio.sh URL PREFIX
#   URL    : video URL
#   PREFIX : output path prefix, e.g. "/tmp/yt-" or "/tmp/bili-"
#
# Output:
#   stdout: absolute path of the downloaded audio file (extension varies: .m4a, .webm, .mp3, ...)
#   file  : {PREFIX}{VIDEO_ID}.{EXT}
#
# Pass the printed path to audio-to-wav.sh.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 URL PREFIX" >&2
  exit 2
fi

URL="$1"
PREFIX="$2"
FIREFOX_PROFILE="${FIREFOX_PROFILE:-firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default}"

COOKIE_ARGS=()
EXTRACTOR_ARGS=()
case "$URL" in
  *youtube.com*|*youtu.be*)
    COOKIE_ARGS=(--cookies-from-browser "$FIREFOX_PROFILE")
    # The default player client often returns "HTTP Error 403: Forbidden" on the
    # audio format (140). Prefer the `tv` client (works with cookies), falling back
    # to web_safari then default. android is skipped automatically (no cookie support).
    EXTRACTOR_ARGS=(--extractor-args "youtube:player_client=tv,web_safari,default")
    ;;
  *bilibili.com*|*b23.tv*)
    COOKIE_ARGS=(--cookies-from-browser "$FIREFOX_PROFILE")
    ;;
esac

VIDEO_ID="$(yt-dlp "${COOKIE_ARGS[@]}" --get-id "$URL" 2>/dev/null | head -1)"

yt-dlp "${COOKIE_ARGS[@]}" "${EXTRACTOR_ARGS[@]}" \
  -f 'bestaudio[ext=m4a]/bestaudio' \
  -o "${PREFIX}%(id)s.%(ext)s" \
  "$URL" >&2

# Find the downloaded file (extension unknown until after download).
ls -1 "${PREFIX}${VIDEO_ID}".* 2>/dev/null | grep -v '\.wav$' | head -1
