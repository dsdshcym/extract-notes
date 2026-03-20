---
name: extract-notes
description: Extract content from any source and format as notes
allowed-tools:
  - Skill(extract-notes-ytb)
  - Skill(extract-notes-podcast)
  - Skill(extract-notes-zoom)
  - Skill(extract-notes-ebook)
  - Skill(extract-notes-browser)
  - Skill(taking-notes)
  - mcp__browser-control__*
---

# Extract Notes

Shared pipeline for cleaning extracted content and formatting as notes. Also serves as entry point for source detection.

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

## Mode 1: Called from a sub-skill (extracted content in context)

If extracted content and metadata are already in the conversation (from extract-notes-zoom, extract-notes-ytb, etc.), skip to **Clean Content** below.

## Mode 2: Called directly

### Step 1: Parse Arguments

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

#### Extracting URL from Org heading

Org link format: `[[URL][description]]` or `[[URL]]`

Regex to extract: `\[\[([^\]]+)\](?:\[[^\]]*\])?\]`

Example: `My Podcast [[https://overcast.fm/+abc][Episode 123]]`
=> URL: `https://overcast.fm/+abc`

### Step 2: Detect Source & Route

If no source provided, detect from current browser tab:
```
Use mcp__browser-control__get-current-tab
```

Then invoke the appropriate sub-skill directly:

| Pattern | Sub-skill |
|---------|-----------|
| `youtube.com`, `youtu.be`, `bilibili.com`, `b23.tv` | `extract-notes-ytb` |
| `overcast.fm`, `ximalaya.com`, `xiaoyuzhoufm.com`, `podcasts.apple.com`, `castro.fm`, `pocketcasts.com`, `libsyn.com`, `anchor.fm`, `podbean.com`, `buzzsprout.com`, `transistor.fm` | `extract-notes-podcast` |
| Zoom transcript window | `extract-notes-zoom` |
| `.epub`, nov-mode | `extract-notes-ebook` |
| `http://`, `https://` (general webpage) | `extract-notes-browser` |

Use the Skill tool to invoke the matched sub-skill, passing the source URL/path as the argument. The sub-skill will handle extraction and call back into this skill for formatting.

## Clean Content

Before formatting, clean up extraction artifacts:

- **SRT/subtitle transcripts**: De-duplicate repeated lines (auto-captions repeat each line across overlapping time windows), remove timing codes, merge into flowing text while preserving paragraph/topic breaks
- **OCR text**: Fix obvious OCR errors (l/1, O/0 confusion, broken words)
- **HTML artifacts**: Strip remaining tags, navigation chrome, boilerplate footers
- **Whisper Chinese punctuation**: whisper-cpp outputs half-width punctuation in Chinese text — convert to full-width:
  + "," => "，" (comma)
  + "." => "。" (period) — only when surrounded by CJK characters
  + "?" => "？"
  + "!" => "！"
  + ":" => "：" — only when surrounded by CJK characters
  + ";" => "；"
- **General**: Remove ad reads / sponsor segments if clearly marked, normalize whitespace

The goal: clean raw text that reads naturally, ready for note-taking. Do NOT summarize or reorganize — only remove extraction noise.

## Format Notes

### If notes-taking-skill is provided:
Invoke the format skill with extracted content.

### If no notes-taking-skill (default):
Use `taking-notes` skill.

**Output:** Print the formatted notes as raw text (user will `/copy` to clipboard).