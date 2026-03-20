---
name: extract-notes:zoom
description: Extract notes from Zoom transcript window
allowed-tools:
  - Bash(bash *zoom-stream.sh*)
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
$ARGUMENTS = from FILE1 [++ FILE2 ...] [notes-taking-skill]
```

- **MEETING_ID** (optional): numeric meeting ID. If omitted, extracted from invite link automatically.
- **notes-taking-skill** (optional): passed through to extract-notes
- **from FILE1 [++ FILE2]**: read transcript files directly (e.g. from a previous streaming session).
  Concatenate multiple files in order if `++` is used.
  Skip Step 1 (extraction) — go directly to Step 3 (clean and format).

## Prerequisites

- Zoom (`zoom.us`) running with a standalone "Transcript" window popped out
- macOS Accessibility permissions granted to the calling process

## Step 1: Extract Transcript

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-stream.sh [MEETING_ID] [INTERVAL]
```

The script:
1. Verifies the standalone Transcript window exists (exits 1 with message if not)
2. Gets meeting ID from invite link if not provided as argument
3. Polls the Transcript window every INTERVAL seconds (default: 1)
4. Re-extracts the full transcript each poll — handles in-place updates from ongoing speech recognition and concurrent speakers
5. Only re-parses when content hash changes (avoids redundant writes)
6. Overwrites `/tmp/zoom_transcript_{MEETING_ID}_{YYYYMMDD}_live.txt` with the latest full transcript
7. Prints progress to stderr (e.g., `[12:45:30] 283 lines (updated)`)
8. Stops automatically when the Transcript window closes (meeting ended), or press Ctrl+C

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

### Disconnect Recovery

If Zoom disconnects and reconnects mid-meeting, the Transcript window resets — the new
transcript only contains text from after the reconnect. The script detects this
(line count drops by >50%) and automatically backs up the pre-disconnect transcript to
`{LIVE_FILE}.back` before overwriting.

When reading a transcript file (either from `from FILE` arguments or after extraction),
**always check for `.back` files**. If `{FILE}.back` exists, read it first and prepend
its content before the main file. This handles disconnect recovery automatically without
the user needing to specify both files.

Multiple `.back` files (e.g. `.back.1`, `.back.2`) are read in order if they exist.

The `++` syntax (`from FILE1 ++ FILE2`) is also supported for explicit concatenation.

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