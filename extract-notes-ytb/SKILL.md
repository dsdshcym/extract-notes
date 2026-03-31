---
name: extract-notes:ytb
description: Extract notes from YouTube or Bilibili videos
allowed-tools:
  - Bash(yt-dlp *)
  - Bash(ffmpeg *)
  - Bash(whisper-cli *)
  - Bash(jq *)
  - Bash(python3 *)
  - Bash(wc *)
  - Bash(head *)
  - Bash(tail *)
  - Read
  - Read(/tmp/*)
  - Skill(extract-notes)
  - mcp__browser-control__*
---

# Extract Notes from YouTube / Bilibili

Extract transcript from YouTube or Bilibili videos and format as notes.

## Input

```
$ARGUMENTS = [source-or-heading] [notes-taking-skill]
```

- **source-or-heading**: URL or Org heading with embedded link
  - YouTube: `https://youtube.com/watch?v=xxx`, `https://youtu.be/xxx`
  - Bilibili: `https://bilibili.com/video/BVxxx`, `https://b23.tv/xxx`
  - If omitted, detect from current browser tab
- **notes-taking-skill** (optional): passed through to extract-notes

## Step 1: Parse Arguments

```
If $ARGUMENTS contains [[url][...]] org link pattern:
  - Extract URL: regex \[\[([^\]]+)\](?:\[[^\]]*\])?\]
  - Remaining text = title context
Else if first arg starts with http://, https://:
  - First arg = URL
  - Second arg (if any) = notes-taking-skill
Else:
  - Detect from current browser tab via mcp__browser-control__get-current-tab
```

## Step 2: Detect Platform

| URL pattern | Platform | Temp prefix | Cookie flag |
|-------------|----------|-------------|-------------|
| `youtube.com`, `youtu.be` | YouTube | `/tmp/yt-` | `--cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"` |
| `bilibili.com`, `b23.tv` | Bilibili | `/tmp/bili-` | `--cookies-from-browser "firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default"` |

Bilibili requires cookie authentication to avoid HTTP 412 errors.

## Step 3: Fetch Video Metadata

```bash
yt-dlp {COOKIES} -j "{URL}" 2>/dev/null | jq '{title, channel, uploader, duration_string, chapters, description}'
```

Output: title, channel/uploader, chapters (if any), description.

## Step 4: Get Transcript

### 4a: List available subtitles

```bash
yt-dlp {COOKIES} --list-subs "{URL}" 2>&1 | head -30
```

The output shows two sections:
- "Available subtitles" = manual/official (human-created)
- "Available automatic captions" = auto-generated

Within auto-generated:
- `zh` or `en` (no suffix) = original auto-caption
- `xx-zh` or `xx-en` (with suffix) = auto-TRANSLATED (lower quality)

### 4b: Choose best subtitle

Priority:
1. Manual/official subtitles: `zh` or `en`
2. Original auto-caption: plain `zh` or `en` (NO suffix)
3. Auto-translated: `zh-Hans-zh`, `en-zh`, etc. (LAST resort)

### 4c: Download subtitle

```bash
# For auto-generated subtitles
yt-dlp {COOKIES} --write-auto-sub --sub-lang {LANG_CODE} --skip-download --convert-subs srt -o "{PREFIX}%(id)s" "{URL}"

# For manual/official subtitles
yt-dlp {COOKIES} --write-subs --sub-lang {LANG_CODE} --skip-download --convert-subs srt -o "{PREFIX}%(id)s" "{URL}"
```

Then clean the SRT using the de-duplication script:
```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/srt_dedup.py {PREFIX}{VIDEO_ID}.{LANG_CODE}.srt
```

### 4d: Fallback — Whisper transcription (if no usable subtitles)

```bash
# Download audio
yt-dlp {COOKIES} -f 'bestaudio[ext=m4a]/bestaudio' -o "{PREFIX}%(id)s.%(ext)s" "{URL}"

# Convert to WAV (16kHz mono)
ffmpeg -i {PREFIX}{VIDEO_ID}.* -ar 16000 -ac 1 -c:a pcm_s16le {PREFIX}{VIDEO_ID}.wav -y

# Transcribe with whisper-cpp
whisper-cli -m ~/.whisper/ggml-large-v3.bin -l auto -f {PREFIX}{VIDEO_ID}.wav -otxt -of {PREFIX}{VIDEO_ID} --prompt "{PROMPT}"
```

**Build the prompt** from video metadata (title, channel, description):
- Extract proper nouns, names, technical terms that Whisper might misspell
- Keep prompt concise (key terms only, not full sentences)

Then read `{PREFIX}{VIDEO_ID}.txt`.

## Step 5: Structure Content

- If video has **chapters**: Use chapter titles and timestamps as top-level sections
- If no chapters: Infer structure from title/description or natural topic breaks; estimate timestamps from transcript
- **Always include timestamps** at top-level sections in `[MM:SS]` format

## Step 6: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.