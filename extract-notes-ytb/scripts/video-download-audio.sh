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

log() { echo "[video-download-audio] $*" >&2; }

COOKIE_ARGS=()
case "$URL" in
  *youtube.com*|*youtu.be*|*bilibili.com*|*b23.tv*)
    COOKIE_ARGS=(--cookies-from-browser "$FIREFOX_PROFILE")
    ;;
esac

VIDEO_ID="$(yt-dlp --no-playlist "${COOKIE_ARGS[@]}" --get-id "$URL" 2>/dev/null | head -1)"

# Returns the downloaded audio file path on stdout (empty if nothing landed).
downloaded_file() {
  ls -1 "${PREFIX}${VIDEO_ID}".* 2>/dev/null | grep -v '\.wav$' | head -1
}

AUDIO_FORMAT='bestaudio[ext=m4a]/bestaudio'

try_download() {
  # $@ = extra yt-dlp args (e.g. --extractor-args ...)
  yt-dlp --no-playlist "${COOKIE_ARGS[@]}" "$@" \
    -f "$AUDIO_FORMAT" \
    -o "${PREFIX}%(id)s.%(ext)s" \
    "$URL" >&2 || true
  [[ -n "$(downloaded_file)" ]]
}

# Same, but with no cookies at all. `--ignore-config` is required because the
# user's ~/.config/yt-dlp/config also pins --cookies-from-browser, which would
# otherwise sneak the cookies back in.
try_download_nocookies() {
  yt-dlp --ignore-config --no-playlist "$@" \
    -f "$AUDIO_FORMAT" \
    -o "${PREFIX}%(id)s.%(ext)s" \
    "$URL" >&2 || true
  [[ -n "$(downloaded_file)" ]]
}

# ---- non-YouTube: single straightforward attempt --------------------------
case "$URL" in
  *youtube.com*|*youtu.be*) ;;
  *)
    # Bilibili's CDN sometimes answers HTTP 567 for one specific audio
    # stream (seen: highest-quality 30280, with AND without cookies) while
    # lower-quality tracks (30232 / 30216) on the same video download fine.
    # So fall back through (quality x cookies), failing fast (--retries 2)
    # instead of burning yt-dlp's default 10 retries per attempt:
    #   1. cookies,    highest quality   (original behavior)
    #   2. no cookies, highest quality
    #   3. cookies,    lower quality
    #   4. no cookies, lower quality
    HIGH_FMT='bestaudio[ext=m4a]/bestaudio'
    LOW_FMT='30232/30216/bestaudio[abr<150]'

    AUDIO_FORMAT="$HIGH_FMT"
    log "attempt: cookies, highest quality"
    if try_download --retries 2; then downloaded_file; exit 0; fi

    log "attempt: no cookies, highest quality"
    if try_download_nocookies --retries 2; then downloaded_file; exit 0; fi

    AUDIO_FORMAT="$LOW_FMT"
    log "attempt: cookies, lower quality"
    if try_download --retries 2; then downloaded_file; exit 0; fi

    log "attempt: no cookies, lower quality"
    if try_download_nocookies --retries 2; then downloaded_file; exit 0; fi

    log "all download strategies failed"
    exit 1
    ;;
esac

# ---- YouTube: defeat the recurring "HTTP Error 403: Forbidden" ------------
#
# Root cause: YouTube binds a GVS *PO Token* (proof-of-origin) to media URLs.
# With no/invalid token, the chosen client's audio format (140) 403s. Two
# observations from testing this, both of which shape the strategy below:
#
#   1. Pinning ONE player_client is whack-a-mole — whichever client is "blessed"
#      rotates over time (e.g. `tv` worked, then started 403ing; `web_embedded`
#      currently works). yt-dlp does NOT auto-retry another client after a
#      download-time 403, so we must loop over clients ourselves.
#   2. The bgutil PO Token provider helps but is NOT reliable on its own — it
#      sometimes mints a token and the download STILL 403s (bgutil's own README
#      warns of this). So it's a passive assist, not the primary mechanism.
#
#   3. Sending cookies can make things WORSE, not better: a signed-in session
#      binds the media URL to a PO token tied to that account, and when that
#      token doesn't satisfy YouTube the audio format 403s — while the very
#      same request without cookies succeeds.
#
# Durable strategy: try cookieless first (public videos, the overwhelming
# majority, need no session), then loop over candidate clients, accepting the
# first attempt that yields a file. The cookie attempts stay as the fallback for
# age-restricted / members-only / private videos, which genuinely need a
# session. If the bgutil plugin is installed (see setup-pot-provider.sh) it
# assists every attempt automatically — but the loops are what actually self-heal
# when YouTube rotates which client works.
#
# Client order: known-good first (web_embedded), then others, then `default` (the
# case where bgutil's PO token is most likely to be the deciding factor).

log "attempt: no cookies, default client"
if try_download_nocookies; then
  downloaded_file
  exit 0
fi

for CLIENT in web_embedded tv web_safari default mweb; do
  log "attempt: no cookies, player_client=$CLIENT"
  if try_download_nocookies --extractor-args "youtube:player_client=$CLIENT"; then
    downloaded_file
    exit 0
  fi
done

for CLIENT in web_embedded tv web_safari default mweb; do
  log "attempt: cookies, player_client=$CLIENT"
  if try_download --extractor-args "youtube:player_client=$CLIENT"; then
    downloaded_file
    exit 0
  fi
done

log "all download strategies failed (likely a new YouTube PO-token change)."
log "try: $(dirname "$0")/setup-pot-provider.sh  to (re)install the bgutil provider,"
log "or update yt-dlp:  brew upgrade yt-dlp"
exit 1
