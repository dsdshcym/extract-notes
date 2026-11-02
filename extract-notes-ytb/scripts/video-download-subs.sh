#!/usr/bin/env bash
# Download subtitles as SRT.
#
# Usage: video-download-subs.sh URL LANG MODE PREFIX
#   URL    : video URL
#   LANG   : subtitle lang code (e.g. "zh", "en", "zh-Hans-zh") from video-list-subs.sh
#   MODE   : "manual" (official subs) | "auto" (auto-generated captions)
#   PREFIX : output path prefix, e.g. "/tmp/yt-" or "/tmp/bili-"
#
# Output:
#   stdout: absolute path of the written SRT file, e.g. /tmp/yt-dQw4w9WgXcQ.en.srt
#   file  : {PREFIX}{VIDEO_ID}.{LANG}.srt
#
# The caller should then run srt_dedup.py on the printed path.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 URL LANG MODE PREFIX" >&2
  exit 2
fi

URL="$1"
LANG="$2"
MODE="$3"
PREFIX="$4"
FIREFOX_PROFILE="${FIREFOX_PROFILE:-firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default}"

case "$MODE" in
  manual) SUB_FLAG="--write-subs" ;;
  auto)   SUB_FLAG="--write-auto-sub" ;;
  *) echo "MODE must be 'manual' or 'auto', got: $MODE" >&2; exit 2 ;;
esac

COOKIE_ARGS=()
case "$URL" in
  *youtube.com*|*youtu.be*|*bilibili.com*|*b23.tv*)
    COOKIE_ARGS=(--cookies-from-browser "$FIREFOX_PROFILE")
    ;;
esac

# Capture video ID so we can print the final SRT path.
VIDEO_ID="$(yt-dlp --no-playlist "${COOKIE_ARGS[@]}" --get-id "$URL" 2>/dev/null | head -1)"

yt-dlp --no-playlist "${COOKIE_ARGS[@]}" \
  "$SUB_FLAG" \
  --sub-lang "$LANG" \
  --skip-download \
  --convert-subs srt \
  -o "${PREFIX}%(id)s" \
  "$URL" >&2

echo "${PREFIX}${VIDEO_ID}.${LANG}.srt"
