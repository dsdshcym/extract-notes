# YouTube Video Extraction

## 1. Fetch Video Metadata
```bash
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" -j "{URL}" 2>/dev/null | jq '{title, channel, duration_string, chapters, description}'
```

Output:
- **title**: video title
- **channel**: creator name
- **chapters**: section markers (if available)
- **description**: may contain structure hints

## 2. Get Transcript

**Step 1: List available subtitles**
```bash
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" --list-subs "{URL}" 2>&1 | head -30
```

**Step 2: Choose best subtitle**

The output shows two sections:
- "Available subtitles" = manual/official (human-created)
- "Available automatic captions" = auto-generated

Within auto-generated, note the naming:
- `zh` or `en` (no suffix) = original auto-caption in that language
- `xx-zh` or `xx-en` (with suffix like `af-zh`) = auto-TRANSLATED from another language

Priority:
1. Manual/official subtitles: `zh` or `en`
2. Original auto-caption: plain `zh` or `en` (NO suffix like `-zh`)
3. Auto-translated: `zh-Hans-zh`, `en-zh`, etc. (LAST resort - lower quality)

**Step 3: Download chosen subtitle**
```bash
# For auto-generated subtitles (most common case)
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" --write-auto-sub --sub-lang {LANG_CODE} --skip-download --convert-subs srt -o "/tmp/yt-%(id)s" "{URL}"

# For manual/official subtitles (if available)
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" --write-subs --sub-lang {LANG_CODE} --skip-download --convert-subs srt -o "/tmp/yt-%(id)s" "{URL}"
```

Then read `/tmp/yt-{VIDEO_ID}.{LANG_CODE}.srt`.

**Fallback: Whisper transcription** (if no usable subtitles)
```bash
# Download audio (video ID in filename for concurrent runs)
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" -f 'bestaudio[ext=m4a]/bestaudio' -o "/tmp/yt-%(id)s.%(ext)s" "{URL}"

# Convert to WAV (16kHz mono for whisper) - use the actual downloaded file
ffmpeg -i /tmp/yt-{VIDEO_ID}.* -ar 16000 -ac 1 -c:a pcm_s16le /tmp/yt-{VIDEO_ID}.wav -y

# Transcribe with whisper-cpp (use --prompt for proper noun accuracy)
whisper-cli -m ~/.whisper/ggml-large-v3.bin -l auto -f /tmp/yt-{VIDEO_ID}.wav -otxt -of /tmp/yt-{VIDEO_ID} --prompt "{PROMPT}"
```

**Build the prompt** from video metadata (title, channel, description):
- Extract proper nouns, names, technical terms that Whisper might misspell
- Example: title "顶尖赛车方向盘有多重？" + description mentions "叶一飞"
  => `--prompt "叶一飞, 勒芒, Chester117"`
- Keep prompt concise (key terms only, not full sentences)

Then read `/tmp/yt-{VIDEO_ID}.txt`.

## 3. Structure Content

- If video has **chapters**: Use chapter titles and timestamps as top-level sections
- If no chapters: Infer structure from title/description or natural topic breaks; estimate timestamps from transcript
- **Always include timestamps** at top-level sections in `[MM:SS]` format