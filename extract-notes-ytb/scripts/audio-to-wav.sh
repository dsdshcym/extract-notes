#!/usr/bin/env bash
# Convert audio to 16kHz mono PCM WAV (format whisper-cli expects).
#
# Usage: audio-to-wav.sh INPUT OUTPUT
#   INPUT  : any ffmpeg-readable audio file
#   OUTPUT : destination .wav path
#
# Output:
#   stdout: OUTPUT path on success
#   file  : {OUTPUT} (16kHz, mono, s16le PCM)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 INPUT OUTPUT" >&2
  exit 2
fi

INPUT="$1"
OUTPUT="$2"

ffmpeg -i "$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "$OUTPUT" -y >&2

echo "$OUTPUT"
