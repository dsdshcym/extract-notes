---
name: extract-notes:ytb
description: Extract notes from YouTube or Bilibili videos
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/extract-transcript.sh:*)
  - Bash(jq *)
  - Read
  - Read(/tmp/*)
  - Skill(driving-browser)
  - Skill(extract-notes)
  - Bash(browser-control-cli:*)
---

# Extract Notes from YouTube / Bilibili

Extract transcript from YouTube or Bilibili videos and format as notes.

**Before using any `browser-control-cli` commands, invoke `Skill(driving-browser)` to load the full CLI reference.**
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

**Goal: capture the speaker's original wording.** A subtitle track that is a
machine translation of the speech is NOT a transcript. For example, a Chinese
video (`language: zh-Hant`) whose only real ASR track is `en-orig`: its
`zh-Hans` auto track is Chinese speech → English ASR → Chinese
back-translation. Notes from it read like a translation ("担任领导职务",
"该片将首先在美国上映") instead of the speaker ("老马也说了搞不定，我们再继续努力").
The orchestrator detects this mismatch (ASR `-orig` language ≠ video language),
skips subtitles, and exits 3 so you run whisper (2b). If
`transcript_method` is `auto_translated_subs`, or the transcript reads like a
translation of the video's language, re-run with `--force-whisper`.

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

## Troubleshooting: YouTube "HTTP Error 403: Forbidden" on audio download

Only the whisper path downloads audio; when it 403s, it's YouTube's **PO Token**
(proof-of-origin) enforcement on the media URL — not a transient error and not
fixed by a single `--extractor-args player_client=` pin (the blessed client
rotates over time).

`scripts/video-download-audio.sh` already handles this by **looping over player
clients** (`web_embedded`, `tv`, `web_safari`, `default`, `mweb`) and accepting
the first that yields a file — yt-dlp does NOT auto-retry another client after a
download-time 403, so the loop is what self-heals.

If the loop ever exhausts all clients:

1. (Re)install the bgutil PO Token provider — it mints a PO token to assist every
   attempt (passive; helps but isn't reliable alone):
   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/setup-pot-provider.sh
   ```
   Requires `deno` (`brew install deno`). Installs to `~/.config/yt-dlp/plugins/`
   (survives `brew upgrade yt-dlp`) + a server checkout at `~/bgutil-ytdlp-pot-provider`.
2. Update yt-dlp: `brew upgrade yt-dlp` (releases track YouTube changes closely).
