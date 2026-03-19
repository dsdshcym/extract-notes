# Zoom Transcript Extraction (macOS Native Window)

Extract transcript text from Zoom's standalone Transcript window via AppleScript accessibility APIs.

## Prerequisites

- Zoom (`zoom.us`) running with a standalone "Transcript" window open (pop out the transcript panel)
- macOS Accessibility permissions granted to the calling process

## 1. Verify Transcript Window & Get Meeting ID

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-check.sh
```

Outputs the numeric meeting ID (e.g., `95820521679`). Exit code 1 if no standalone Transcript window found — ask user to pop out the transcript panel in Zoom.

## 2. Extract Transcript

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/zoom-extract.sh [MEETING_ID]
```

Pass the meeting ID from step 1 to skip re-detection. Without args, auto-detects by calling `zoom-check.sh` internally.

Output is printed to stdout and saved to `/tmp/zoom_transcript_{MEETING_ID}_{DATETIME}.txt`.
Raw merged data saved to `/tmp/zoom_merged_{MEETING_ID}_{DATETIME}.txt`.

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

- Always use the standalone Transcript window (not the embedded transcript in the Zoom Meeting window)
- Bulk `value of every ... of every row` is critical — row-by-row AppleScript loops time out on 500+ row transcripts
- Cmd+A / Cmd+C does not work in Zoom's native Transcript window
- Window must be named "Transcript" (may differ in non-English Zoom)
- Meeting ID is obtained by clicking "Copy invite link" from the Meeting menu (restores clipboard after)