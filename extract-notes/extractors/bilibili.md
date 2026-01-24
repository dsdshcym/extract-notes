# Bilibili Video Extraction

## Cookie Authentication

Bilibili requires authentication to avoid HTTP 412 errors. Always use Firefox Developer Edition cookies:

```
--cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"
```

## 1. Fetch Video Metadata
```bash
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" -j "{URL}" 2>/dev/null | jq '{title, uploader, duration_string, chapters, description}'
```

Output:
- **title**: video title
- **uploader**: creator name
- **chapters**: section markers (if available)
- **description**: may contain structure hints

## 2. Get Transcript

**Step 1: List available subtitles**
```bash
yt-dlp --cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default" --list-subs "{URL}" 2>&1 | head -30
```

**Step 2: Choose best subtitle**

Priority (Chinese-first):
1. Manual subtitles: `zh`
2. Original auto-caption: `zh` (no suffix)
3. Auto-translated: `xx-zh`

**Step 3: Download subtitle**
```bash
COOKIES='--cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"'

# For auto-generated subtitles
yt-dlp $COOKIES --write-auto-sub --sub-lang zh --skip-download --convert-subs srt -o "/tmp/bili-%(id)s" "{URL}"

# For manual subtitles (if available)
yt-dlp $COOKIES --write-subs --sub-lang zh --skip-download --convert-subs srt -o "/tmp/bili-%(id)s" "{URL}"
```

Then read `/tmp/bili-{VIDEO_ID}.zh.srt`.

**Fallback: Whisper transcription** (if no usable subtitles)
```bash
COOKIES='--cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"'

# Download audio
yt-dlp $COOKIES -f 'bestaudio' -o "/tmp/bili-%(id)s.%(ext)s" "{URL}"

# Convert to WAV (16kHz mono for whisper)
ffmpeg -i /tmp/bili-{VIDEO_ID}.* -ar 16000 -ac 1 -c:a pcm_s16le /tmp/bili-{VIDEO_ID}.wav -y

# Transcribe with whisper-cpp
whisper-cli -m ~/.whisper/ggml-large-v3.bin -l zh -f /tmp/bili-{VIDEO_ID}.wav -otxt -of /tmp/bili-{VIDEO_ID} --prompt "{PROPER_NOUNS}"
```

**Build the prompt** from video metadata (title, uploader, description):
- Extract proper nouns, names, technical terms
- Keep prompt concise (key terms only)

Then read `/tmp/bili-{VIDEO_ID}.txt`.

## 3. Structure Content

- If video has **chapters**: Use chapter titles and timestamps as top-level sections
- If no chapters: Infer structure from title/description or natural topic breaks
- **Always include timestamps** at top-level sections in `[MM:SS]` format