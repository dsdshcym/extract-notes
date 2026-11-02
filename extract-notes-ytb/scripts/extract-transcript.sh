#!/usr/bin/env bash
# High-level orchestrator: URL -> transcript file.
#
# Codifies the deterministic steps of extract-notes:ytb so the LLM only has to
# (1) generate a whisper prompt when asked, (2) turn the final transcript into notes.
#
# Usage:
#   extract-transcript.sh URL [--whisper-prompt "PROMPT"] [--force-whisper]
#
# Flow:
#   1. Detect platform -> pick temp PREFIX.
#   2. Fetch yt-dlp JSON metadata (one shot; includes `.subtitles` and
#      `.automatic_captions` so no separate --list-subs call is needed).
#   3. Pick the best subtitle track algorithmically, in order:
#        a. manual subs (original lang > zh > en)
#        b. auto captions in original lang — prefers `{lang}-orig` over `{lang}`
#           (YouTube exposes `-orig` as the explicitly-original track when both exist).
#           Region tags are normalized (`en-US` → `en`) since caption keys use base lang.
#           If the `-orig` (real ASR) track's language differs from the video's
#           language, all auto tracks are back-translations -> skip to whisper.
#        c. auto-translated captions (zh variants > en)
#   4. If a track is chosen and --force-whisper is not set:
#        download + dedup -> transcript path
#      Else:
#        if --whisper-prompt was provided: download audio -> wav -> whisper -> transcript
#        else: print metadata JSON with needs_whisper_prompt=true and exit 3.
#
# Exit codes:
#   0  success (JSON result on stdout)
#   2  usage error
#   3  needs whisper prompt from LLM (JSON result on stdout with needs_whisper_prompt=true)
#   >0 other failure
#
# Success stdout (JSON):
#   {
#     "video_id":       "dQw4w9WgXcQ",
#     "platform":       "youtube" | "bilibili" | "other",
#     "title":          "...",
#     "channel":        "...",     // YouTube
#     "uploader":       "...",     // Bilibili and fallback
#     "duration_string":"12:34",
#     "chapters":       [...] | null,
#     "description":    "...",
#     "transcript_path":"/tmp/yt-xxx.en.srt.cleaned.txt" | ".../xxx.txt",
#     "transcript_method":"manual_subs" | "auto_subs" | "auto_translated_subs" | "whisper",
#     "transcript_lang":"en" | "zh" | "zh-Hans-zh" | "auto"
#   }
#
# Needs-prompt stdout (exit 3):
#   same shape as above but with:
#     "needs_whisper_prompt": true
#     "transcript_path": null, "transcript_method": null, "transcript_lang": null
#
# Env vars (all have sane defaults):
#   FIREFOX_PROFILE  cookie source for yt-dlp  (default: dev-edition profile)
#   WHISPER_MODEL    whisper.cpp model path    (default: ~/.whisper/ggml-large-v3.bin)
#   TMP_DIR          temp file directory       (default: /tmp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export FIREFOX_PROFILE="${FIREFOX_PROFILE:-firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default}"
export WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.whisper/ggml-large-v3.bin}"
TMP_DIR="${TMP_DIR:-/tmp}"

# ---- arg parsing ---------------------------------------------------------

URL=""
WHISPER_PROMPT=""
FORCE_WHISPER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --whisper-prompt)
      WHISPER_PROMPT="${2:-}"; shift 2 ;;
    --force-whisper)
      FORCE_WHISPER=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    --*)
      echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$URL" ]]; then URL="$1"; else
        echo "Unexpected positional arg: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "Usage: $0 URL [--whisper-prompt PROMPT] [--force-whisper]" >&2
  exit 2
fi

# ---- platform detection --------------------------------------------------

case "$URL" in
  *youtube.com*|*youtu.be*)   PLATFORM="youtube";  PREFIX="$TMP_DIR/yt-" ;;
  *bilibili.com*|*b23.tv*)    PLATFORM="bilibili"; PREFIX="$TMP_DIR/bili-" ;;
  *)                          PLATFORM="other";    PREFIX="$TMP_DIR/vid-" ;;
esac

log() { echo "[extract-transcript] $*" >&2; }

# ---- step 2: metadata ----------------------------------------------------

log "fetching metadata..."
META_JSON="$("$SCRIPT_DIR/video-metadata.sh" "$URL")"

VIDEO_ID="$(jq -r '.id' <<<"$META_JSON")"
if [[ -z "$VIDEO_ID" || "$VIDEO_ID" == "null" ]]; then
  echo "failed to extract video id from metadata" >&2
  exit 1
fi

# Trimmed metadata object for downstream output.
META_TRIMMED="$(jq '{title, channel, uploader, duration_string, chapters, description}' <<<"$META_JSON")"

emit_result() {
  # $1 = transcript_path (or "null")
  # $2 = transcript_method
  # $3 = transcript_lang
  # $4 = extra fields as JSON object (e.g. '{"needs_whisper_prompt":true}' or '{}')
  jq -n \
    --arg video_id "$VIDEO_ID" \
    --arg platform "$PLATFORM" \
    --arg tpath   "$1" \
    --arg tmethod "$2" \
    --arg tlang   "$3" \
    --argjson meta  "$META_TRIMMED" \
    --argjson extra "$4" \
    '{video_id:$video_id, platform:$platform}
     + $meta
     + (if $tpath   == "null" then {transcript_path:   null} else {transcript_path:   $tpath}   end)
     + (if $tmethod == "null" then {transcript_method: null} else {transcript_method: $tmethod} end)
     + (if $tlang   == "null" then {transcript_lang:   null} else {transcript_lang:   $tlang}   end)
     + $extra'
}

# ---- step 3: pick best subtitle track ------------------------------------

pick_subtitle() {
  # Echo "MODE LANG" on stdout, or nothing if no usable track.
  # Priority:
  #   1. manual subs: original lang > zh variants > en
  #   2. auto captions in original lang — prefer `{lang}-orig` over `{lang}`
  #      (YouTube marks the explicitly-original track as `-orig` when both exist;
  #      the plain `{lang}` is often a re-auto-generation of a translation.)
  #   3. auto translated captions — zh variants > en

  # Detect original language. yt-dlp's 'language' can be a region tag (e.g. en-US);
  # caption keys use the base tag (en), so normalize.
  local orig_lang orig_base
  orig_lang="$(jq -r '.language // empty' <<<"$META_JSON" 2>/dev/null)"
  orig_base="${orig_lang%%-*}"

  # Build ordered language list.
  # For Chinese-origin videos, use the fixed zh order (Simplified before Traditional)
  # instead of putting orig_lang first. For other languages, put the normalized
  # base lang first so e.g. Japanese videos prefer ja.
  local -a lang_order=()
  if [[ -n "$orig_base" && "$orig_base" != zh* ]]; then
    lang_order+=("$orig_base")
  fi
  for l in zh zh-Hans zh-CN zh-Hant zh-TW en; do
    [[ "$l" != "$orig_base" ]] && lang_order+=("$l")
  done

  local lang

  # 1. Manual subs
  for lang in "${lang_order[@]}"; do
    if jq -e --arg l "$lang" '.subtitles[$l] // empty' <<<"$META_JSON" >/dev/null 2>&1; then
      echo "manual $lang"; return
    fi
  done

  # 2. Auto captions in original language — prefer the explicit `-orig` variant
  # over the plain key when both exist.
  #
  # When YouTube exposes a `-orig` track, that is the ONLY real ASR track; every
  # other auto key is a machine translation of it. If the ASR language doesn't
  # match the video's language (e.g. a Chinese video with `language: zh-Hant`
  # but only `en-orig`), the "zh-Hans" auto track is Chinese -> English ASR ->
  # Chinese back-translation and loses the speaker's wording. Skip subtitles
  # entirely so the caller falls through to whisper.
  local asr_lang
  asr_lang="$(jq -r '.automatic_captions | keys[]? | select(endswith("-orig"))' <<<"$META_JSON" 2>/dev/null | head -1)"
  asr_lang="${asr_lang%-orig}"
  if [[ -n "$asr_lang" && -n "$orig_base" && "${asr_lang%%-*}" != "$orig_base" ]]; then
    echo "[extract-transcript] ASR track is ${asr_lang}-orig but video language is $orig_lang; skipping translated auto subs" >&2
    return
  fi

  for lang in "${lang_order[@]}"; do
    if jq -e --arg l "${lang}-orig" '.automatic_captions[$l] // empty' <<<"$META_JSON" >/dev/null 2>&1; then
      echo "auto ${lang}-orig"; return
    fi
    if jq -e --arg l "$lang" '.automatic_captions[$l] // empty' <<<"$META_JSON" >/dev/null 2>&1; then
      echo "auto $lang"; return
    fi
  done

  # 3. Auto captions, translated — prefer *-zh over *-en (legacy yt-dlp form
  # where translated tracks are exposed with suffixes like `en-zh`).
  local all_translated translated
  all_translated="$(jq -r '
    .automatic_captions
    | keys[]?
    | select(endswith("-zh") or endswith("-en"))
  ' <<<"$META_JSON" 2>/dev/null)"
  translated="$(grep -m1 -- '-zh$' <<<"$all_translated" || grep -m1 -- '-en$' <<<"$all_translated" || true)"

  if [[ -n "$translated" ]]; then
    echo "auto_translated $translated"
  fi
}

TRACK=""
if [[ "$FORCE_WHISPER" -ne 1 ]]; then
  TRACK="$(pick_subtitle)"
fi

# ---- step 4a: subtitle path ----------------------------------------------

if [[ -n "$TRACK" ]]; then
  read -r TRACK_MODE TRACK_LANG <<<"$TRACK"
  log "using subtitle track: mode=$TRACK_MODE lang=$TRACK_LANG"

  # download-subs wants mode ∈ {manual, auto}; translated still downloads via --write-auto-sub.
  DL_MODE="$TRACK_MODE"
  [[ "$DL_MODE" == "auto_translated" ]] && DL_MODE="auto"

  SRT_PATH="$("$SCRIPT_DIR/video-download-subs.sh" "$URL" "$TRACK_LANG" "$DL_MODE" "$PREFIX")"
  log "srt written: $SRT_PATH"

  CLEANED_PATH="${SRT_PATH}.cleaned.txt"
  python3 "$SCRIPT_DIR/srt_dedup.py" "$SRT_PATH" > "$CLEANED_PATH"
  log "cleaned transcript: $CLEANED_PATH"

  METHOD_OUT="$TRACK_MODE"
  [[ "$METHOD_OUT" == "manual" ]] && METHOD_OUT="manual_subs"
  [[ "$METHOD_OUT" == "auto" ]] && METHOD_OUT="auto_subs"
  [[ "$METHOD_OUT" == "auto_translated" ]] && METHOD_OUT="auto_translated_subs"

  emit_result "$CLEANED_PATH" "$METHOD_OUT" "$TRACK_LANG" '{}'
  exit 0
fi

# ---- step 4b: whisper path -----------------------------------------------

if [[ -z "$WHISPER_PROMPT" ]]; then
  log "no subtitles available; needs whisper prompt from LLM"
  emit_result "null" "null" "null" '{"needs_whisper_prompt": true}'
  exit 3
fi

log "no subtitles; transcribing with whisper..."
AUDIO_PATH="$("$SCRIPT_DIR/video-download-audio.sh" "$URL" "$PREFIX")"
log "audio: $AUDIO_PATH"

WAV_PATH="${PREFIX}${VIDEO_ID}.wav"
"$SCRIPT_DIR/audio-to-wav.sh" "$AUDIO_PATH" "$WAV_PATH" >/dev/null
log "wav: $WAV_PATH"

TXT_PATH="$("$SCRIPT_DIR/transcribe.sh" "$WAV_PATH" "${PREFIX}${VIDEO_ID}" "$WHISPER_PROMPT")"
log "whisper transcript: $TXT_PATH"

emit_result "$TXT_PATH" "whisper" "auto" '{}'
