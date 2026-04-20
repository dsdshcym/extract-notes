---
name: extract-notes:ytb
description: Extract notes from YouTube or Bilibili videos
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/extract-transcript.sh:*)
  - Bash(jq *)
  - Read
  - Read(/tmp/*)
  - Skill(extract-notes)
  - Bash(browser-control-cli:*)
---

# Extract Notes from YouTube / Bilibili

Extract transcript from YouTube or Bilibili videos and format as notes.
Most steps are codified in `scripts/extract-transcript.sh`; you only do two
things: (1) generate a whisper prompt when asked, (2) take notes from the
final transcript.

## Input

```
$ARGUMENTS = [source-or-heading] [notes-taking-skill]
```

- **source-or-heading**: URL or Org heading with embedded link
  - YouTube: `https://youtube.com/watch?v=xxx`, `https://youtu.be/xxx`
  - Bilibili: `https://bilibili.com/video/BVxxx`, `https://b23.tv/xxx`
  - If omitted, detect from current browser tab via `browser-control-cli current-tab`
- **notes-taking-skill** (optional): passed through to extract-notes

## Step 1: Parse Arguments

```
If $ARGUMENTS contains [[url][...]] org link pattern:
  - Extract URL: regex \[\[([^\]]+)\](?:\[[^\]]*\])?\]
Else if first arg starts with http:// or https://:
  - First arg = URL; second arg (if any) = notes-taking-skill
Else:
  - Detect from current browser tab via `browser-control-cli current-tab`
```

## Step 2: Extract Transcript

```bash
${CLAUDE_SKILL_DIR}/scripts/extract-transcript.sh "{URL}"
```

The orchestrator detects the platform, fetches metadata, picks the best
subtitle track (manual > auto-original > auto-translated), downloads and
de-duplicates it. On success it prints one JSON object on stdout.

### 2a: Success — transcript ready

Exit 0. Stdout JSON:
```json
{
  "video_id": "...",
  "platform": "youtube" | "bilibili" | "other",
  "title": "...",
  "channel": "...",
  "uploader": "...",
  "duration_string": "12:34",
  "chapters": [...] | null,
  "description": "...",
  "transcript_path": "/tmp/yt-xxx.en.srt.cleaned.txt",
  "transcript_method": "manual_subs" | "auto_subs" | "auto_translated_subs",
  "transcript_lang": "en"
}
```

Read `transcript_path` and jump to Step 4.

### 2b: No subtitles — generate a whisper prompt (LLM step)

Exit 3. Stdout JSON same shape as above but with `needs_whisper_prompt: true`
and `transcript_path/method/lang: null`.

Build a whisper prompt from `.title`, `.channel`/`.uploader`, `.description`:
- Extract proper nouns, names, technical terms Whisper might misspell
- Concise — key terms only, not full sentences

Then re-run with the prompt:
```bash
${CLAUDE_SKILL_DIR}/scripts/extract-transcript.sh "{URL}" --whisper-prompt "{PROMPT}"
```

On success: exit 0, `transcript_method: "whisper"`, transcript at `transcript_path`.

## Step 3: Structure Content

- If metadata has `chapters`: use chapter titles and timestamps as top-level sections
- If no chapters: infer structure from title/description or natural topic breaks;
  transcripts from `srt_dedup.py` already include `[MM:SS]` markers every 30s
- **Always include timestamps** at top-level sections in `[MM:SS]` format

## Step 4: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.

## Configuration

Env vars (optional — defaults baked into the scripts):

| Var | Default | Purpose |
|---|---|---|
| `FIREFOX_PROFILE` | `firefox:~/Library/Application Support/Firefox/Profiles/hcmmkzdc.dev-edition-default` | yt-dlp cookie source |
| `WHISPER_MODEL` | `~/.whisper/ggml-large-v3.bin` | whisper.cpp model |
| `TMP_DIR` | `/tmp` | temp file directory |

## Force whisper (rare)

To bypass subtitles even when available — e.g. to get timestamps without the
30s bucketing from srt_dedup:
```bash
${CLAUDE_SKILL_DIR}/scripts/extract-transcript.sh "{URL}" --force-whisper --whisper-prompt "{PROMPT}"
```
