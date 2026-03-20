---
name: extract-notes:zoom
description: Extract notes from Zoom transcript window
allowed-tools:
  - Bash(bash *zoom-extract.sh*)
  - Bash(wc:*)
  - Read
  - Skill(extract-notes)
  - mcp__browser-control__*
---

# Extract Notes from Zoom Transcript

Extract transcript text from Zoom's standalone Transcript window via AppleScript accessibility APIs.

## Input

```
$ARGUMENTS = [MEETING_ID] [notes-taking-skill]
```

- **MEETING_ID** (optional): numeric meeting ID. If omitted, extracted from invite link automatically.
- **notes-taking-skill** (optional): passed through to extract-notes

## Prerequisites

- Zoom (`zoom.us`) running with a standalone "Transcript" window popped out
- macOS Accessibility permissions granted to the calling process

## Step 1: Extract Transcript

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-extract.sh [MEETING_ID]
```

The script:
1. Verifies the standalone Transcript window exists (exits 1 with message if not)
2. Gets meeting ID from invite link if not provided as argument
3. Bulk-fetches all speaker names and text areas via AppleScript
4. Parses into clean speaker-timestamped blocks via Python

Output is printed to stdout and saved to `/tmp/zoom_transcript_{MEETING_ID}_{DATETIME}.txt`.

### Table structure

Each row in `table 1 of scroll area 1` is one of:

| Row type | Static texts | Text areas | Output |
|----------|-------------|------------|--------|
| Speaker | 1 (name) | 0 | `S:Austin Bernard` |
| Timestamp+text | 0 | 2 (timestamp, first line) | `T:14:01:54Hello there.` |
| Continuation | 0 | 1 (text) | `T:more text here...` |

For rows with 2 text areas, AppleScript's `(item as text)` concatenates them (e.g., `"14:01:54Hello there."`).

### Critical: flush before speaker change

When a new speaker row appears, the previous speaker's text must be flushed **before** `current_speaker` is updated. Otherwise the previous text block gets misattributed to the new speaker.

## Step 2: Prepare Metadata

- **title**: derive from meeting context or ask user
- **participants**: extracted from speaker names
- **date**: today's date
- **source**: Zoom meeting transcript

## Step 3: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.

## Notes

- Always use the standalone Transcript window (pop it out from the Zoom Meeting window)
- Bulk `value of every ... of every row` is critical — row-by-row AppleScript loops time out on 500+ row transcripts
- Cmd+A / Cmd+C does not work in Zoom's native Transcript window
- Window must be named "Transcript" (may differ in non-English Zoom)
- Meeting ID is obtained by clicking "Copy invite link" from the Meeting menu (restores clipboard after)