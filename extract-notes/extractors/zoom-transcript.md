# Zoom Transcript Extraction (macOS Native Window)

Extract transcript text from Zoom's native macOS Transcript window via AppleScript accessibility APIs.

## Prerequisites

- Zoom (`zoom.us`) running with a "Transcript" window open
- macOS Accessibility permissions granted to the calling process

## 1. Verify Transcript Window

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-check.sh
```

Look for `window "Transcript"` in the output. If absent (exit code 1), ask user to open the Zoom transcript panel.

## 2. Extract Transcript

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-extract.sh
```

This single command:
1. Bulk-fetches all speaker names and text areas from the Transcript window via AppleScript
2. Parses the raw `S:`/`T:` prefixed lines into clean speaker-timestamped blocks via Python

Output is printed to stdout and saved to `/tmp/zoom_transcript_clean.txt`.

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

## 3. Output

Clean transcript format:

```
Austin Bernard [14:01:54]:
I'm a Senior Software Engineer at the Home Depot...

Yiming Chen [14:03:02]:
That's cool, yeah
```

Metadata:
- **title**: derive from meeting context or ask user
- **participants**: extracted from speaker names
- **date**: today's date
- **source**: Zoom meeting transcript

## Notes

- Bulk `value of every ... of every row` is critical — row-by-row AppleScript loops time out on 500+ row transcripts
- Cmd+A / Cmd+C does not work in Zoom's native Transcript window
- Window must be named "Transcript" (may differ in non-English Zoom)
- Temp files in `/tmp/` can be cleaned up after use