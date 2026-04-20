---
name: extract-notes:ytb
description: Extract notes from YouTube or Bilibili videos
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/video-metadata.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/video-list-subs.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/video-download-subs.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/video-download-audio.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/audio-to-wav.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/transcribe.sh:*)
  - Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/srt_dedup.py:*)
  - Bash(jq *)
  - Bash(wc *)
  - Bash(head *)
  - Bash(tail *)
  - Read
  - Read(/tmp/*)
  - Skill(extract-notes)
  - Bash(browser-control-cli:*)
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
  - Detect from current browser tab via `browser-control-cli current-tab`
```

## Step 2: Detect Platform

| URL pattern | Platform | Temp prefix |
|-------------|----------|-------------|
| `youtube.com`, `youtu.be` | YouTube | `/tmp/yt-` |
| `bilibili.com`, `b23.tv` | Bilibili | `/tmp/bili-` |

Wrapper scripts auto-apply Firefox cookies for both platforms (Bilibili needs them to avoid HTTP 412).

## Step 3: Fetch Video Metadata

```bash
${CLAUDE_SKILL_DIR}/scripts/video-metadata.sh "{URL}"
```

Returns raw yt-dlp JSON on stdout. Pipe through `jq` to extract fields:

```bash
${CLAUDE_SKILL_DIR}/scripts/video-metadata.sh "{URL}" | jq '{title, channel, uploader, duration_string, chapters, description}'
```

Useful fields: `.title`, `.channel` (YouTube) or `.uploader` (Bilibili), `.duration_string`, `.chapters` (array of `{start_time, end_time, title}` or null), `.description`.

## Step 4: Get Transcript

### 4a: List available subtitles

```bash
${CLAUDE_SKILL_DIR}/scripts/video-list-subs.sh "{URL}"
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
# MODE is "manual" for official subs, "auto" for auto-generated captions.
${CLAUDE_SKILL_DIR}/scripts/video-download-subs.sh "{URL}" "{LANG_CODE}" "{MODE}" "{PREFIX}"
```

Prints the absolute SRT path on stdout (e.g. `/tmp/yt-dQw4w9WgXcQ.en.srt`). Then de-duplicate:

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/srt_dedup.py "{SRT_PATH}"
```

### 4d: Fallback — Whisper transcription (if no usable subtitles)

```bash
# 1. Download audio — prints the audio file path on stdout.
AUDIO=$(${CLAUDE_SKILL_DIR}/scripts/video-download-audio.sh "{URL}" "{PREFIX}")

# 2. Convert to WAV — prints the WAV path on stdout.
WAV=$(${CLAUDE_SKILL_DIR}/scripts/audio-to-wav.sh "$AUDIO" "{PREFIX}{VIDEO_ID}.wav")

# 3. Transcribe — prints the .txt path on stdout.
TXT=$(${CLAUDE_SKILL_DIR}/scripts/transcribe.sh "$WAV" "{PREFIX}{VIDEO_ID}" "{PROMPT}")
```

**Build the prompt** from video metadata (title, channel, description):
- Extract proper nouns, names, technical terms that Whisper might misspell
- Keep prompt concise (key terms only, not full sentences)

Then read the `$TXT` file.

## Step 5: Structure Content

- If video has **chapters**: Use chapter titles and timestamps as top-level sections
- If no chapters: Infer structure from title/description or natural topic breaks; estimate timestamps from transcript
- **Always include timestamps** at top-level sections in `[MM:SS]` format

## Step 6: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.
