# Zoom Transcript Extraction (macOS Native Window)

Extract transcript text from Zoom's native macOS Transcript window via AppleScript accessibility APIs.

## Prerequisites

- Zoom (`zoom.us`) running with a "Transcript" window open
- macOS Accessibility permissions granted to the calling process

## 1. Verify Transcript Window

```bash
osascript -e '
tell application "System Events"
    tell process "zoom.us"
        get name of every window
    end tell
end tell
'
```

Look for `window "Transcript"`. If absent, ask user to open the Zoom transcript panel.

## 2. Extract and Merge Names + Texts

Single AppleScript call. Bulk-fetches all names and texts, then zips them row-by-row with `S:` (speaker) or `T:` (text) prefixes, one per line.

```bash
osascript << 'ASCRIPT' > /tmp/zoom_merged.txt
set LF to ASCII character 10

tell application "System Events"
    tell process "zoom.us"
        tell window "Transcript"
            tell table 1 of scroll area 1
                set allNames to value of every static text of every UI element of every row
                set allTexts to value of every text area of every UI element of every row
                set rowCount to count of allNames
            end tell
        end tell
    end tell
end tell

set output to ""
repeat with i from 1 to rowCount
    set n to item i of allNames
    set t to item i of allTexts
    if n is not missing value and (n as text) is not "" then
        set output to output & "S:" & (n as text) & LF
    else if t is not missing value and (t as text) is not "" then
        set output to output & "T:" & (t as text) & LF
    end if
end repeat
return output
ASCRIPT
```

### Table structure

Each row in `table 1 of scroll area 1` is one of:

| Row type | Static texts | Text areas | Output |
|----------|-------------|------------|--------|
| Speaker | 1 (name) | 0 | `S:Austin Bernard` |
| Timestamp+text | 0 | 2 (timestamp, first line) | `T:14:01:54Hello there.` |
| Continuation | 0 | 1 (text) | `T:more text here...` |

For rows with 2 text areas, AppleScript's `(item as text)` concatenates them (e.g., `"14:01:54Hello there."`).

## 3. Parse into Transcript

```python
python3 << 'PYEOF'
import re

with open('/tmp/zoom_merged.txt') as f:
    lines = [l for l in f.read().strip().split('\n') if l]

timestamp_re = re.compile(r'^(\d{1,2}:\d{2}:\d{2})(.*)', re.DOTALL)

current_speaker = None
current_timestamp = None
current_lines = []
output_blocks = []

def flush():
    global current_lines
    if current_speaker and current_timestamp and current_lines:
        output_blocks.append(
            f"{current_speaker} [{current_timestamp}]:\n" + " ".join(current_lines)
        )
    current_lines = []

for line in lines:
    if line.startswith('S:'):
        flush()  # flush BEFORE updating speaker
        current_speaker = line[2:]
    elif line.startswith('T:'):
        text = line[2:]
        m = timestamp_re.match(text)
        if m:
            flush()
            current_timestamp = m.group(1)
            remainder = m.group(2).strip()
            current_lines = [remainder] if remainder else []
        else:
            current_lines.append(text)

flush()

result = "\n\n".join(output_blocks)
with open('/tmp/zoom_transcript_clean.txt', 'w') as f:
    f.write(result)
print(result)
PYEOF
```

### Critical: flush before speaker change

When a new speaker row appears, the previous speaker's text must be flushed **before** `current_speaker` is updated. Otherwise the previous text block gets misattributed to the new speaker.

## 4. Output

Clean transcript at `/tmp/zoom_transcript_clean.txt`:

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