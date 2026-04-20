---
name: extract-notes:podcast
description: Extract notes from podcast episodes
allowed-tools:
  - Bash(yt-dlp:*)
  - Bash(ffmpeg:*)
  - Bash(whisper-cli:*)
  - Bash(jq:*)
  - Bash(python3:*)
  - Bash(curl:*)
  - Bash(wc:*)
  - Read
  - Skill(extract-notes)
  - Bash(browser-control-cli:*)
---

# Extract Notes from Podcast

Extract transcript from podcast episodes and format as notes.

## Input

```
$ARGUMENTS = [source-or-heading] [notes-taking-skill]
```

- **source-or-heading**: URL or Org heading with embedded link
  - Overcast: `https://overcast.fm/+xxx`
  - Ximalaya: `https://ximalaya.com/...`
  - Xiaoyuzhoufm: `https://xiaoyuzhoufm.com/...`
  - Apple Podcasts: `https://podcasts.apple.com/...`
  - Direct audio URL: `https://example.com/episode.mp3`
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

## Step 2: Fetch Page Content & Metadata

```bash
browser-control-cli get-content {TAB_ID}
```

Extract from page:
- **title**: Episode title
- **podcast**: Show name
- **description**: Episode description / show notes
- **outline**: Look for timestamps, chapter markers, or structured sections in show notes

## Step 3: Get Audio URL

Use a unique {ID} per episode (e.g. episode number, slug, or hash) in ALL temp file names so multiple extractions can run in parallel.

### Overcast.fm
Look for `<audio>` tag or `data-audio-src` attribute in page content.

### Ximalaya
Extract audio URL from page — look for m4a/mp3 in page source or API response.

### Apple Podcasts
Look for `assetUrl` in page metadata or embedded JSON.

### Xiaoyuzhoufm
Audio URL often in page data or requires inspecting network requests.

### Blog/Website with Embedded Audio
Look for direct audio links in page content:
- `.mp3`, `.m4a` URLs (often from libsyn, anchor.fm, podbean, etc.)
- `<audio>` tags or audio player elements

```bash
curl -L -o /tmp/podcast-{ID}.mp3 "{AUDIO_URL}"
```

### Fallback: yt-dlp
Many podcast sites are supported:
```bash
yt-dlp -j "{URL}" 2>/dev/null | jq '{title, uploader, duration_string, description}'
yt-dlp -f 'bestaudio' -o "/tmp/podcast-%(id)s.%(ext)s" "{URL}"
```

## Step 4: Transcribe Audio

```bash
# Convert to WAV (16kHz mono)
ffmpeg -i /tmp/podcast-{ID}.* -ar 16000 -ac 1 -c:a pcm_s16le /tmp/podcast-{ID}.wav -y

# Transcribe with whisper-cpp
whisper-cli -m ~/.whisper/ggml-large-v3.bin -l auto -f /tmp/podcast-{ID}.wav -otxt -of /tmp/podcast-{ID}-transcript --prompt "{PROMPT}"
```

**Build the prompt** from metadata:
- Extract proper nouns, guest names, technical terms from title/description
- Example: Episode "对话张三：AI的未来" => `--prompt "张三, AI, 人工智能"`

Then read `/tmp/podcast-{ID}-transcript.txt`.

## Step 5: Structure Content

Priority for structure:
1. **Show notes with timestamps**: Use as section headers `[MM:SS]`
2. **Chapter markers from page**: If podcast app shows chapters
3. **Description outline**: If show notes have bullet points or numbered sections
4. **Natural topic breaks**: Infer from transcript content

**Always include timestamps** at top-level sections in `[MM:SS]` format when available.

## Step 6: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.