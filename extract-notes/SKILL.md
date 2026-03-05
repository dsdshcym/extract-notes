---
name: extract-notes
description: Extract content from any source and format as notes
allowed-tools:
  - Bash(yt-dlp:*)
  - Bash(ffmpeg:*)
  - Bash(whisper-cli:*)
  - Bash(jq:*)
  - Bash(wc:*)
  - Bash(emacsclient:*)
  - Bash(osascript:*)
  - Bash(python3:*)
  - Read
  - Skill(taking-notes)
  - Search
  - mcp__browser-control__*
---

# Extract Notes

Extract content from any source and format as notes.

## Input

```
$ARGUMENTS = [source-or-heading] [notes-taking-skill]
```

- **source-or-heading** (optional): URL, file path, or Org heading
  - URL: `https://youtube.com/watch?v=xxx`
  - File path: `~/Documents/paper.pdf`
  - Org heading with link: `Some Title [[https://example.com][link]]`
  - If omitted, detect from current browser tab
- **notes-taking-skill** (optional): Skill for note formatting
  - If omitted, uses `taking-notes`

**Examples:**
- `/extract-notes` → current browser tab, default format
- `/extract-notes https://youtube.com/watch?v=xxx` → YouTube video
- `/extract-notes ~/Documents/paper.pdf` → PDF file
- `/extract-notes My Podcast Episode [[https://overcast.fm/+xxx][link]]` → Org heading with embedded URL
- `/extract-notes https://example.com taking-notes-in-markdown` → webpage with custom format

## Step 1: Parse Arguments

```
If $ARGUMENTS contains [[url][...]] org link pattern:
  - Extract URL from the link
  - Remaining text = title context
  - source = extracted URL
Else if first arg starts with http://, https://, or ~ or /:
  - First arg = source
  - Second arg (if any) = notes-taking-skill
Else if $ARGUMENTS is non-empty:
  - $ARGUMENTS = notes-taking-skill
  - Detect source from context (Step 2)
Else:
  - No notes-taking-skill (use default)
  - Detect source from context (Step 2)
```

### Extracting URL from Org heading

Org link format: `[[URL][description]]` or `[[URL]]`

Regex to extract: `\[\[([^\]]+)\](?:\[[^\]]*\])?\]`

Example: `My Podcast [[https://overcast.fm/+abc][Episode 123]]`
→ URL: `https://overcast.fm/+abc`

## Step 2: Ensure Source is Accessible

### If source URL was extracted from heading:

1. Check if URL is already open (call concurrently for speed):
   ```
   PARALLEL:
     - mcp__browser-control__get-current-tab
     - mcp__browser-control__get-list-of-open-tabs
   ```

2. If current tab matches URL → proceed directly

3. If found in other tabs → proceed (extractor will fetch content directly)

4. If not found in any tab, open it:
   ```
   Use mcp__browser-control__open-browser-tab with the URL
   ```

### If source is empty:

Detect from current browser tab:
```
Use mcp__browser-control__get-current-tab
```

If browser tab unavailable, prompt user for source.

### Match source against:

| Pattern | Extractor |
|---------|-----------|
| `youtube.com`, `youtu.be` | extractors/youtube.md |
| `bilibili.com`, `b23.tv` | extractors/bilibili.md |
| `overcast.fm`, `ximalaya.com`, `xiaoyuzhoufm.com`, `podcasts.apple.com`, `castro.fm`, `pocketcasts.com` | extractors/podcast.md |
| `libsyn.com`, `anchor.fm`, `podbean.com`, `buzzsprout.com`, `transistor.fm` (audio hosts) | extractors/podcast.md |
| `http://`, `https://` (with embedded `.mp3`/`.m4a` or audio player) | extractors/podcast.md |
| `http://`, `https://` | extractors/webpage.md |
| `.epub`, nov-mode | extractors/ebook.md |
| `.pdf`, pdf-view-mode | extractors/pdf.md |
| `.ppt`, `.pptx`, `.doc`, `.docx` | extractors/office.md |
| `.mp3`, `.m4a`, `.wav`, `.flac` | extractors/audio.md |
| `.mp4`, `.mkv`, `.mov`, `.webm` | extractors/video.md |
| Zoom transcript (macOS native window) | extractors/zoom-transcript.md |

## Step 3: Extract Content

Follow the matched extractor file. Each extractor produces:
- **metadata**: title, author/channel, date, source URL
- **content**: transcript or article text

## Step 3.5: Clean Extracted Content

Before formatting, clean up extraction artifacts:

- **SRT/subtitle transcripts**: De-duplicate repeated lines (auto-captions repeat each line across overlapping time windows), remove timing codes, merge into flowing text while preserving paragraph/topic breaks
- **OCR text**: Fix obvious OCR errors (l/1, O/0 confusion, broken words)
- **HTML artifacts**: Strip remaining tags, navigation chrome, boilerplate footers
- **Whisper Chinese punctuation**: whisper-cpp outputs half-width punctuation in Chinese text — convert to full-width:
  + "," → "，" (comma)
  + "." → "。" (period) — only when surrounded by CJK characters
  + "?" → "？"
  + "!" → "！"
  + ":" → "：" — only when surrounded by CJK characters
  + ";" → "；"
- **General**: Remove ad reads / sponsor segments if clearly marked, normalize whitespace

The goal: clean raw text that reads naturally, ready for note-taking. Do NOT summarize or reorganize — only remove extraction noise.

## Step 4: Format Notes

### If notes-taking-skill is provided:
Invoke the format skill with extracted content.

### If no notes-taking-skill (default):
Use `taking-notes` skill.

**Output:** Print the formatted notes as raw text (user will `/copy` to clipboard).
