---
name: extract-notes
description: Extract content from any source and format as notes
allowed-tools:
  - Bash(yt-dlp:*)
  - Bash(ffmpeg:*)
  - Bash(whisper-cli:*)
  - Bash(pbcopy:*)
  - Bash(jq:*)
  - Bash(emacsclient:*)
  - Read
  - Skill(taking-notes)
  - mcp__browser-control__*
---

# Extract Notes

Extract content from any source and format as notes.

## Input

```
$ARGUMENTS = [source] [notes-taking-skill]
```

- **source** (optional): URL or file path
  - If omitted, uses current browser tab
- **notes-taking-skill** (optional): Skill for note formatting
  - If omitted, uses `taking-notes`

**Examples:**
- `/extract-notes` → current tab, default format
- `/extract-notes https://youtube.com/watch?v=xxx` → YouTube video
- `/extract-notes ~/Documents/paper.pdf` → PDF file
- `/extract-notes https://example.com taking-notes-in-markdown` → webpage with custom format

## Step 1: Parse Arguments

```
If first arg starts with http://, https://, or ~ or /:
  - First arg = source
  - Second arg (if any) = notes-taking-skill
Else if $ARGUMENTS is non-empty:
  - $ARGUMENTS = notes-taking-skill
  - Use current browser tab for source
Else:
  - No notes-taking-skill (use default)
  - Use current browser tab for source
```

## Step 2: Detect Source Type

If source is empty, detect from context:

### Context Cascade

1. **Check Emacs buffer** (via emacsclient):
   ```bash
   emacsclient --eval '(with-current-buffer (window-buffer) major-mode)'
   ```
   - `nov-mode` → extractors/ebook.md
   - `eww-mode` → extract URL, treat as webpage
   - `pdf-view-mode` → extract file path, treat as PDF

2. **Check working directory**:
   - If in Calibre Library → prompt: "Extract from current e-book chapter?"

3. **Fall back to browser tab**:
   ```
   Use mcp__browser-control__get-current-tab
   ```

4. **If ambiguous** (e.g., nov-mode buffer exists but not focused, or multiple sources available):
   - Prompt user to choose source

### Match source against:

| Pattern | Extractor |
|---------|-----------|
| `youtube.com`, `youtu.be` | extractors/youtube.md |
| `bilibili.com`, `b23.tv` | extractors/bilibili.md |
| `overcast.fm`, `ximalaya.com`, `xiaoyuzhoufm.com`, `podcasts.apple.com`, `castro.fm`, `pocketcasts.com` | extractors/podcast.md |
| `libsyn.com`, `anchor.fm`, `podbean.com`, `buzzsprout.com` (audio hosts) | extractors/podcast.md |
| `http://`, `https://` (with embedded `.mp3`/`.m4a` or audio player) | extractors/podcast.md |
| `http://`, `https://` | extractors/webpage.md |
| `.epub`, nov-mode | extractors/ebook.md |
| `.pdf`, pdf-view-mode | extractors/pdf.md |
| `.ppt`, `.pptx`, `.doc`, `.docx` | extractors/office.md |
| `.mp3`, `.m4a`, `.wav`, `.flac` | extractors/audio.md |
| `.mp4`, `.mkv`, `.mov`, `.webm` | extractors/video.md |

## Step 3: Extract Content

Follow the matched extractor file. Each extractor produces:
- **metadata**: title, author/channel, date, source URL
- **content**: transcript or article text

## Step 4: Format Notes

### If notes-taking-skill is provided:
Invoke the format skill with extracted content.

### If no notes-taking-skill (default):
Use `taking-notes` skill.

**Output:** Copy to clipboard
```bash
pbcopy <<'EOF'
- Notes here
EOF
```