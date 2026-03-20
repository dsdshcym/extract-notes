#!/usr/bin/env python3
"""
De-duplicate YouTube auto-caption SRT files.

YouTube auto-captions use a sliding window: each 2-second block shows a running
buffer of ~3 lines, so every phrase appears 2-3 times. This script extracts only
the *new* words introduced in each block and reassembles a clean transcript with
timestamps every 30 seconds.

Usage:
    python3 srt_dedup.py <input.srt>
    python3 srt_dedup.py /tmp/yt-VIDEO_ID.en.srt
"""

import re
import sys


def parse_srt(path):
    with open(path, 'r') as f:
        content = f.read()

    blocks = re.split(r'\n\n+', content.strip())
    entries = []

    for block in blocks:
        parts = block.strip().split('\n')
        if len(parts) < 3:
            continue

        m = re.match(r'(\d+):(\d+):(\d+),(\d+)', parts[1])
        if not m:
            continue

        h, mn, s, ms = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        start_sec = h * 3600 + mn * 60 + s + ms / 1000

        text = ' '.join(l.strip() for l in parts[2:] if l.strip())
        if text:
            entries.append((start_sec, text))

    return entries


def dedup_transcript(entries):
    """Extract clean transcript by finding new words in each sliding window."""
    result = []
    prev_words = []

    for start_sec, text in entries:
        if text.strip() in ('', ' '):
            continue

        words = text.split()

        # Find overlap: how many words from start of 'words' match end of 'prev_words'
        max_overlap = min(len(prev_words), len(words))
        overlap = 0
        for n in range(max_overlap, 0, -1):
            if prev_words[-n:] == words[:n]:
                overlap = n
                break

        new_words = words[overlap:]
        if new_words:
            result.append((start_sec, ' '.join(new_words)))

        prev_words = words

    return result


def format_transcript(cleaned, ts_interval=30):
    output = []
    last_ts_shown = -999

    for start_sec, text in cleaned:
        mins = int(start_sec) // 60
        secs = int(start_sec) % 60
        ts_str = f"[{mins:02d}:{secs:02d}]"

        if start_sec - last_ts_shown >= ts_interval:
            output.append(f"\n{ts_str}")
            last_ts_shown = start_sec

        output.append(text)

    return ' '.join(output)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.srt>", file=sys.stderr)
        sys.exit(1)

    entries = parse_srt(sys.argv[1])
    cleaned = dedup_transcript(entries)
    print(format_transcript(cleaned))