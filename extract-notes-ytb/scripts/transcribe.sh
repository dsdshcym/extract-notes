#!/usr/bin/env bash
# Transcribe a WAV file with whisper.cpp.
#
# Usage: transcribe.sh WAV_FILE OUTPUT_PREFIX [PROMPT]
#   WAV_FILE      : 16kHz mono WAV (from audio-to-wav.sh)
#   OUTPUT_PREFIX : path prefix without extension, e.g. "/tmp/yt-abc123"
#                   (whisper-cli will write {OUTPUT_PREFIX}.txt)
#   PROMPT        : optional comma-separated proper nouns / technical terms
#                   to help whisper spell them correctly
#
# Output:
#   stdout: absolute path of the transcript .txt file
#   file  : {OUTPUT_PREFIX}.txt  (plain text, no timestamps)
#
# Model: hardcoded to ~/.whisper/ggml-large-v3.bin.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 WAV_FILE OUTPUT_PREFIX [PROMPT]" >&2
  exit 2
fi

WAV_FILE="$1"
OUTPUT_PREFIX="$2"
PROMPT="${3:-}"

MODEL="$HOME/.whisper/ggml-large-v3.bin"

PROMPT_ARGS=()
if [[ -n "$PROMPT" ]]; then
  PROMPT_ARGS=(--prompt "$PROMPT")
fi

whisper-cli \
  -m "$MODEL" \
  -l auto \
  -f "$WAV_FILE" \
  -otxt \
  -of "$OUTPUT_PREFIX" \
  "${PROMPT_ARGS[@]}" >&2

echo "${OUTPUT_PREFIX}.txt"
