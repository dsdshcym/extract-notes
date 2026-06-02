# Zoom Audio Notes (v1, AX-only) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Capture a Zoom meeting's audio (others + mic) and AX mute-state timeline, transcribe locally, and produce a speaker-attributed transcript that survives screensharing — then feed it to `/extract-notes-zoom`.

**Architecture:** A bash daemon (`zoom-audio-record.sh`) detects a meeting, launches a Swift helper (`zoom-audio-capture` — ScreenCaptureKit app audio + AVAudioEngine mic → two WAVs) and an AX poller (`zoom-participants-poll.sh` — roster + binary mute-state → TSV timeline). On meeting end it transcribes each WAV with whisper.cpp (`-ocsv`), then a Python merge (`zoom-audio-merge.py`) aligns segments against the timeline and emits `Me` / single-name / `[Alice|Bob]` candidate-set / `Others` labels. The result goes to the existing `/extract-notes-zoom from FILE` flow.

**Tech Stack:** bash, AppleScript (osascript) for AX, Swift 6 (ScreenCaptureKit + AVAudioEngine), whisper.cpp (`whisper-cli`), ffmpeg, Python 3 stdlib.

**Key conventions (from existing repo):**
- Whisper model: `${WHISPER_MODEL:-$HOME/.whisper/ggml-large-v3.bin}` (already present).
- WAV format: 16 kHz mono s16le (see `extract-notes-ytb/scripts/audio-to-wav.sh`).
- Scripts live in `extract-notes-zoom/scripts/`, compiled binaries in `extract-notes-zoom/scripts/bin/`.
- Reuse osascript helpers (`meeting_window_exists`, `get_meeting_id`, `notify`) from `zoom-closed-caption.sh`.

**Time-alignment invariant (critical):** whisper CSV offsets are relative to audio start. The recorder writes its **start epoch** (seconds since 1970) to a sidecar file the instant capture begins. Segment wall-clock = `audio_start_epoch + csv_offset_seconds`. The poller logs wall-clock epochs. The merge aligns on this shared origin.

---

## Task 1: Mute-state merge logic (TDD — the testable core)

This is pure data transformation: given two whisper CSVs, a timeline TSV, and an audio-start epoch, produce a labelled transcript. No I/O to Zoom, fully deterministic.

**Files:**
- Create: `extract-notes-zoom/scripts/zoom-audio-merge.py`
- Test: `extract-notes-zoom/scripts/test_zoom_audio_merge.py`

**Data formats:**

whisper `-ocsv` output (`start_ms,end_ms,text`), header row present:
```
start,end,text
0,2000," Hello everyone"
2000,4500," thanks for joining"
```

timeline TSV (one row per poll per participant; `epoch` is float seconds):
```
epoch	name	muted
1717243000.0	Alice	0
1717243000.0	Bob	1
1717243000.5	Alice	0
```

**Step 1: Write failing tests**

```python
# test_zoom_audio_merge.py
import subprocess, sys, os, tempfile, textwrap, json
HERE = os.path.dirname(os.path.abspath(__file__))
MERGE = os.path.join(HERE, "zoom-audio-merge.py")

def run(me_csv, others_csv, timeline, audio_start):
    d = tempfile.mkdtemp()
    paths = {}
    for name, content in [("me.csv", me_csv), ("others.csv", others_csv), ("tl.tsv", timeline)]:
        p = os.path.join(d, name); open(p, "w").write(content); paths[name] = p
    out = subprocess.run(
        [sys.executable, MERGE, "--me", paths["me.csv"], "--others", paths["others.csv"],
         "--timeline", paths["tl.tsv"], "--audio-start", str(audio_start)],
        capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout

CSV_HEADER = "start,end,text\n"

def test_me_segments_labelled_me():
    me = CSV_HEADER + '0,2000," I will present now"\n'
    others = CSV_HEADER
    out = run(me, others, "epoch\tname\tmuted\n", 1000.0)
    assert "Me" in out
    assert "I will present now" in out

def test_single_unmuted_gets_name():
    others = CSV_HEADER + '0,2000," sounds good to me"\n'  # 1000.0-1002.0 wallclock
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n" + "1001.0\tBob\t1\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "Alice" in out
    assert "Bob" not in out
    assert "sounds good to me" in out

def test_multiple_unmuted_gets_candidate_set():
    others = CSV_HEADER + '0,2000," lets discuss"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n" + "1001.0\tBob\t0\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "[Alice|Bob]" in out or "[Bob|Alice]" in out

def test_none_unmuted_falls_back_to_others():
    others = CSV_HEADER + '0,2000," background noise"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t1\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "Others" in out

def test_chronological_interleave():
    me = CSV_HEADER + '3000,4000," my reply"\n'
    others = CSV_HEADER + '0,2000," their question"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n"
    out = run(me, others, tl, 1000.0)
    assert out.index("their question") < out.index("my reply")
```

**Step 2: Run tests, verify they fail**

Run: `cd extract-notes-zoom/scripts && python3 -m pytest test_zoom_audio_merge.py -v`
Expected: FAIL (file not found / nonzero exit — `zoom-audio-merge.py` doesn't exist yet).

**Step 3: Implement `zoom-audio-merge.py`**

```python
#!/usr/bin/env python3
"""Merge whisper CSVs (me + others) with an AX mute-state timeline into a
speaker-attributed transcript.

Labels per "others" segment, by who was unmuted during it:
  exactly one  -> that name
  several      -> [Name1|Name2] candidate set (agent disambiguates)
  none         -> Others
"me" segments are always labelled "Me".
Segments are emitted in chronological (wall-clock) order.
"""
import argparse, csv, sys

def read_segments(path):
    segs = []
    try:
        with open(path, newline="") as f:
            r = csv.reader(f)
            for i, row in enumerate(r):
                if i == 0 and row and row[0].strip() == "start":
                    continue  # header
                if len(row) < 3:
                    continue
                try:
                    start = float(row[0]) / 1000.0
                    end = float(row[1]) / 1000.0
                except ValueError:
                    continue
                text = row[2].strip()
                if text:
                    segs.append((start, end, text))
    except FileNotFoundError:
        pass
    return segs

def read_timeline(path):
    rows = []
    try:
        with open(path, newline="") as f:
            for i, line in enumerate(f):
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                if i == 0 and parts[0] == "epoch":
                    continue  # header
                try:
                    epoch = float(parts[0])
                except ValueError:
                    continue
                rows.append((epoch, parts[1], parts[2] == "0"))  # (epoch, name, unmuted)
    except FileNotFoundError:
        pass
    return rows

def unmuted_during(timeline, start_wc, end_wc):
    """Names unmuted in any poll sample overlapping [start_wc, end_wc].
    Widen the window by half a poll interval each side so a segment between
    samples still catches the relevant state."""
    PAD = 0.75  # generous vs ~3-4 Hz polling
    names = set()
    for epoch, name, unmuted in timeline:
        if start_wc - PAD <= epoch <= end_wc + PAD and unmuted:
            names.add(name)
    return names

def label_others(timeline, start_wc, end_wc):
    names = sorted(unmuted_during(timeline, start_wc, end_wc))
    if len(names) == 1:
        return names[0]
    if len(names) > 1:
        return "[" + "|".join(names) + "]"
    return "Others"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--me", required=True)
    ap.add_argument("--others", required=True)
    ap.add_argument("--timeline", required=True)
    ap.add_argument("--audio-start", type=float, required=True)
    args = ap.parse_args()

    timeline = read_timeline(args.timeline)
    blocks = []  # (wallclock_start, speaker, text)

    for start, end, text in read_segments(args.me):
        blocks.append((args.audio_start + start, "Me", text))

    for start, end, text in read_segments(args.others):
        wc_start = args.audio_start + start
        wc_end = args.audio_start + end
        speaker = label_others(timeline, wc_start, wc_end)
        blocks.append((wc_start, speaker, text))

    blocks.sort(key=lambda b: b[0])
    for _, speaker, text in blocks:
        print(f"{speaker}: {text}")

if __name__ == "__main__":
    main()
```

**Step 4: Run tests, verify pass**

Run: `cd extract-notes-zoom/scripts && python3 -m pytest test_zoom_audio_merge.py -v`
Expected: 5 passed.

**Step 5: Commit**

```bash
git add extract-notes-zoom/scripts/zoom-audio-merge.py extract-notes-zoom/scripts/test_zoom_audio_merge.py
git commit -m "feat(zoom): add mute-timeline transcript merge with candidate-set labels"
```

---

## Task 2: Participant mute-state poller

AX scrape of the popped-out Participants window. Appends `epoch\tname\tmuted` rows to a timeline TSV. Cannot be unit-tested (needs live Zoom) → manual verification.

**Files:**
- Create: `extract-notes-zoom/scripts/zoom-participants-poll.sh`

**Step 1: Implement**

```bash
#!/usr/bin/env bash
# Poll the popped-out Zoom Participants window for roster + mute-state.
# Appends "epoch<TAB>name<TAB>muted" rows (muted: 1=muted 0=unmuted) to a
# timeline TSV until killed (SIGTERM).
#
# Usage: zoom-participants-poll.sh TIMELINE_TSV [INTERVAL]
#   TIMELINE_TSV : output file (header written if new)
#   INTERVAL     : seconds between polls (default 0.3 → ~3 Hz)
#
# Requires the Participants panel popped out into its own window so the AX
# handle survives screensharing. Names are read from the participants outline.

set -euo pipefail

TIMELINE="${1:?usage: zoom-participants-poll.sh TIMELINE_TSV [INTERVAL]}"
INTERVAL="${2:-0.3}"

[ -s "$TIMELINE" ] || printf 'epoch\tname\tmuted\n' > "$TIMELINE"

# AppleScript: emit one "name\tMUTED|UNMUTED" line per participant row.
read -r -d '' POLL_AS <<'ASCRIPT' || true
tell application "System Events"
  if not (exists process "zoom.us") then return ""
  tell process "zoom.us"
    if not (exists (window 1 whose name begins with "Participants")) then return ""
    tell (window 1 whose name begins with "Participants")
      tell outline 1 of scroll area 1
        set out to ""
        repeat with r in rows
          repeat with c in (UI elements of r)
            set nm to ""
            set st to "UNKNOWN"
            repeat with sub in (UI elements of c)
              if (class of sub as text) is "static text" then set nm to (value of sub as text)
            end repeat
            repeat with sub in (UI elements of c)
              if (class of sub as text) is "image" then
                set d to (description of sub)
                if d contains "audio muted" then
                  set st to "MUTED"
                else if d contains "audio unmuted" then
                  set st to "UNMUTED"
                end if
              end if
            end repeat
            if nm is not "" then set out to out & nm & (ASCII character 9) & st & (ASCII character 13)
          end repeat
        end repeat
        return out
      end tell
    end tell
  end tell
end tell
ASCRIPT

cleanup() { exit 0; }
trap cleanup TERM INT

while true; do
  epoch=$(date +%s.%N)
  raw=$(osascript -e "$POLL_AS" 2>/dev/null || true)
  if [ -n "$raw" ]; then
    # Parse rows terminated by \r, fields split on \t.
    printf '%s' "$raw" | tr '\r' '\n' | while IFS=$'\t' read -r name state; do
      [ -z "$name" ] && continue
      case "$state" in
        MUTED)   m=1 ;;
        UNMUTED) m=0 ;;
        *)       continue ;;  # unknown state → don't log a guess
      esac
      printf '%s\t%s\t%s\n' "$epoch" "$name" "$m" >> "$TIMELINE"
    done
  fi
  sleep "$INTERVAL"
done
```

**Step 2: Manual verification (real meeting)**

```bash
chmod +x extract-notes-zoom/scripts/zoom-participants-poll.sh
# With a Zoom meeting open and Participants panel popped out:
extract-notes-zoom/scripts/zoom-participants-poll.sh /tmp/zoom_tl_test.tsv 0.3 &
POLLER=$!
sleep 5
kill -TERM $POLLER
column -t -s$'\t' /tmp/zoom_tl_test.tsv | head
```
Expected: header + rows with your name and `muted` 0/1 flipping as you toggle mute. Confirm the poller exits cleanly on SIGTERM.

**Step 3: Commit**

```bash
git add extract-notes-zoom/scripts/zoom-participants-poll.sh
git commit -m "feat(zoom): add AX participant mute-state poller"
```

---

## Task 3: Swift audio capture helper

ScreenCaptureKit captures `zoom.us` app audio → `others.wav`; AVAudioEngine captures default mic → `me.wav`. On SIGTERM, finalize both files. Writes audio-start epoch to a sidecar the moment capture begins. Needs Screen Recording permission + live audio → manual verification.

**Files:**
- Create: `extract-notes-zoom/scripts/zoom-audio-capture.swift`
- Build to: `extract-notes-zoom/scripts/bin/zoom-audio-capture`

**Step 1: Implement** (`zoom-audio-capture.swift`)

```swift
// Capture Zoom app audio (others) + default mic (me) to two WAV files.
// Usage: zoom-audio-capture <others.wav> <me.wav> <start-epoch-file>
// Writes the capture-start epoch (Unix seconds) to start-epoch-file once
// capture begins, so a downstream merge can align whisper offsets to wall-clock.
// Runs until SIGTERM/SIGINT, then finalizes both files.
import AVFoundation
import ScreenCaptureKit
import Darwin

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write("usage: zoom-audio-capture <others.wav> <me.wav> <start-epoch-file>\n".data(using: .utf8)!)
    exit(2)
}
let othersPath = CommandLine.arguments[1]
let mePath = CommandLine.arguments[2]
let startEpochPath = CommandLine.arguments[3]

// --- WAV writer helper (16kHz mono via AVAudioFile, written as caller feeds) ---
func makeWavFile(_ path: String) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    return try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
}

// --- Mic capture via AVAudioEngine ---
final class MicRecorder {
    let engine = AVAudioEngine()
    var file: AVAudioFile?
    let outPath: String
    init(_ path: String) { outPath = path }
    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                      channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        file = try makeWavFile(outPath)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self = self, let file = self.file else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var err: NSError?
            var fed = false
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err == nil, out.frameLength > 0 { try? file.write(from: out) }
        }
        try engine.start()
    }
    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop(); file = nil }
}

// --- App audio capture via ScreenCaptureKit ---
final class AppAudioRecorder: NSObject, SCStreamOutput {
    var stream: SCStream?
    var file: AVAudioFile?
    let outPath: String
    init(_ path: String) { outPath = path }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let zoomApp = content.applications.first(where: {
            $0.bundleIdentifier == "us.zoom.xos" || $0.applicationName == "zoom.us"
        }) else {
            throw NSError(domain: "zoom-audio-capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zoom.us not found among shareable apps"])
        }
        let display = content.displays.first!
        let filter = SCContentFilter(display: display, including: [zoomApp], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // Minimal video (SCK requires a video config even for audio-only).
        cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        file = try makeWavFile(outPath)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let file = file, CMSampleBufferDataIsReady(sb) else { return }
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        let inFormat = AVAudioFormat(streamDescription: asbd)!
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
            frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        // Convert to int16 mono 16k for the WAV file.
        let outFormat = file.processingFormat
        if let conv = AVAudioConverter(from: inFormat, to: outFormat),
           let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) {
            var err: NSError?; var fed = false
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err == nil, out.frameLength > 0 { try? file.write(from: out) }
        }
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        file = nil
    }
}

let mic = MicRecorder(mePath)
let app = AppAudioRecorder(othersPath)

// Signal handling: flip a flag, finalize in the main runloop.
var stopRequested = false
signal(SIGTERM) { _ in stopRequested = true }
signal(SIGINT)  { _ in stopRequested = true }

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        try mic.start()
        try await app.start()
        // Record start epoch once both are running.
        let epoch = Date().timeIntervalSince1970
        try? String(format: "%.3f", epoch).write(toFile: startEpochPath, atomically: true, encoding: .utf8)
        FileHandle.standardError.write("capture started @ \(epoch)\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("start failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    sema.signal()
}
sema.wait()

while !stopRequested { Thread.sleep(forTimeInterval: 0.2) }

let done = DispatchSemaphore(value: 0)
Task { mic.stop(); await app.stop(); done.signal() }
done.wait()
FileHandle.standardError.write("capture finalized\n".data(using: .utf8)!)
```

**Step 2: Compile**

```bash
mkdir -p extract-notes-zoom/scripts/bin
swiftc -O extract-notes-zoom/scripts/zoom-audio-capture.swift \
  -o extract-notes-zoom/scripts/bin/zoom-audio-capture
```
Expected: compiles with no errors. (Warnings about Sendable/global-var are acceptable for v1.)

**Step 3: Manual verification (real meeting + Screen Recording grant)**

```bash
B=extract-notes-zoom/scripts/bin/zoom-audio-capture
"$B" /tmp/others.wav /tmp/me.wav /tmp/start.txt &
PID=$!
# talk + play some Zoom audio for ~10s
sleep 10
kill -TERM $PID
cat /tmp/start.txt; echo
ffprobe -hide_banner /tmp/me.wav 2>&1 | grep Duration
ffprobe -hide_banner /tmp/others.wav 2>&1 | grep Duration
```
Expected: `start.txt` holds a Unix epoch; both WAVs are 16 kHz mono with ~10s duration and audible content. First run will prompt for Screen Recording permission — grant it, then re-run.

**Step 4: Commit**

```bash
git add extract-notes-zoom/scripts/zoom-audio-capture.swift
git commit -m "feat(zoom): add ScreenCaptureKit+mic audio capture helper"
```
(Do NOT commit the compiled `bin/` binary — add it to `.gitignore` in Task 5.)

---

## Task 4: Orchestrator daemon

Ties it together: detect meeting → launch capture + poller → wait for window close → transcribe → merge → `/extract-notes-zoom`. Models `zoom-closed-caption.sh`.

**Files:**
- Create: `extract-notes-zoom/scripts/zoom-audio-record.sh`

**Step 1: Implement**

```bash
#!/usr/bin/env bash
# Record a Zoom meeting's audio + mute timeline, then transcribe and extract
# notes after it ends. Screenshare-proof alternative to zoom-closed-caption.sh.
#
# Usage: zoom-audio-record.sh [--daemon] [--notes-dir=DIR] [MEETING_ID]
#   --daemon        : run forever, auto-detecting meetings (for launchd)
#   --notes-dir=DIR : save extracted notes as org files in DIR
#   MEETING_ID      : numeric id (default: from invite link or "unknown")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_BIN="$SCRIPT_DIR/bin/zoom-audio-capture"
POLLER="$SCRIPT_DIR/zoom-participants-poll.sh"
MERGE="$SCRIPT_DIR/zoom-audio-merge.py"
WAV2="$SCRIPT_DIR/../../extract-notes-ytb/scripts/audio-to-wav.sh"  # reuse if present
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.whisper/ggml-large-v3.bin}"

DAEMON=false
NOTES_DIR=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --daemon) DAEMON=true; shift ;;
    --notes-dir=*) NOTES_DIR="${1#--notes-dir=}"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NOTES_DIR" ] && { NOTES_DIR="${NOTES_DIR/#\~/$HOME}"; mkdir -p "$NOTES_DIR"; }
MEETING_ID="${1:-}"
IDLE_INTERVAL=5

notify() { osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true; }

meeting_window_exists() {
  osascript -e '
  tell application "System Events"
    if not (exists process "zoom.us") then return "no"
    tell process "zoom.us"
      if exists window "Zoom Meeting" then return "yes"
    end tell
  end tell
  return "no"' 2>/dev/null
}

get_meeting_id() {
  osascript -e '
  set oldClip to the clipboard
  tell application "System Events"
    tell process "zoom.us"
      click menu item "Copy invite link" of menu 1 of menu bar item "Meeting" of menu bar 1
    end tell
  end tell
  delay 0.3
  set inviteLink to the clipboard as text
  set the clipboard to oldClip
  return inviteLink' 2>/dev/null | grep -oE '[0-9]{9,}' || echo "unknown"
}

record_meeting() {
  local mid="$1" date_tag
  date_tag=$(date +%Y%m%d_%H%M%S)
  local base="/tmp/zoom_audio_${mid}_${date_tag}"
  local others_wav="${base}_others.wav" me_wav="${base}_me.wav"
  local start_epoch="${base}_start.txt" timeline="${base}_timeline.tsv"

  echo "[$(date +%H:%M:%S)] Recording meeting $mid → $base" >&2
  notify "Zoom Audio" "Recording meeting $mid"

  "$CAPTURE_BIN" "$others_wav" "$me_wav" "$start_epoch" 2>>"${base}.log" &
  local cap_pid=$!
  bash "$POLLER" "$timeline" 0.3 &
  local poll_pid=$!

  while [ "$(meeting_window_exists)" = "yes" ]; do sleep 2; done
  echo "[$(date +%H:%M:%S)] Meeting ended — stopping capture." >&2
  kill -TERM "$cap_pid" 2>/dev/null || true
  kill -TERM "$poll_pid" 2>/dev/null || true
  wait "$cap_pid" 2>/dev/null || true
  wait "$poll_pid" 2>/dev/null || true

  [ -s "$others_wav" ] || [ -s "$me_wav" ] || { echo "No audio captured." >&2; return; }

  # Resample (whisper wants 16k mono; capture already is, but normalize anyway).
  local me_csv_prefix="${base}_me" others_csv_prefix="${base}_others"
  local transcript="${base}_transcript.txt"
  local audio_start; audio_start=$(cat "$start_epoch" 2>/dev/null || echo 0)

  [ -s "$me_wav" ] && whisper-cli -m "$WHISPER_MODEL" -l auto -f "$me_wav" \
       -ocsv -of "$me_csv_prefix" --max-context 0 >&2 2>&1 || true
  [ -s "$others_wav" ] && whisper-cli -m "$WHISPER_MODEL" -l auto -f "$others_wav" \
       -ocsv -of "$others_csv_prefix" --max-context 0 >&2 2>&1 || true

  python3 "$MERGE" \
    --me "${me_csv_prefix}.csv" \
    --others "${others_csv_prefix}.csv" \
    --timeline "$timeline" \
    --audio-start "$audio_start" > "$transcript" || true

  echo "[$(date +%H:%M:%S)] Transcript: $transcript" >&2
  notify "Zoom Audio" "Transcript ready: $transcript"

  if [ "$DAEMON" = true ] && [ -s "$transcript" ]; then
    (
      local json sid notes
      json=$(cd "$HOME/Org" && claude -p "/extract-notes-zoom from $transcript" \
             --settings "$HOME/.claude/settings.work.json" --output-format json 2>/dev/null) || true
      sid=$(echo "$json" | jq -r '.session_id // empty' 2>/dev/null) || true
      notes=$(echo "$json" | jq -r '.result // empty' 2>/dev/null) || true
      if [ -n "$notes" ]; then
        if [ -n "$NOTES_DIR" ]; then
          local nf="${NOTES_DIR}/$(date +%Y-%m-%d)_${mid}.org"
          echo "$notes" > "$nf"; notify "Zoom Audio Notes Ready" "$nf"
        else
          notify "Zoom Audio Notes Ready" "claude -r $sid"
        fi
      fi
    ) &
  fi
}

if [ "$DAEMON" = true ]; then
  echo "[$(date +%H:%M:%S)] Daemon: waiting for Zoom Meeting window..." >&2
  while true; do
    if [ "$(meeting_window_exists)" = "yes" ]; then
      mid="${MEETING_ID:-$(get_meeting_id)}"
      record_meeting "$mid"
      echo "[$(date +%H:%M:%S)] Waiting for next meeting..." >&2
    fi
    sleep "$IDLE_INTERVAL"
  done
else
  [ "$(meeting_window_exists)" = "yes" ] || { echo "No Zoom Meeting window." >&2; exit 1; }
  mid="${MEETING_ID:-$(get_meeting_id)}"
  record_meeting "$mid"
fi
```

**Step 2: Manual verification**

```bash
chmod +x extract-notes-zoom/scripts/zoom-audio-record.sh
# In a short real meeting (non-daemon), then leave the meeting:
extract-notes-zoom/scripts/zoom-audio-record.sh
cat /tmp/zoom_audio_*_transcript.txt
```
Expected: a transcript with `Me:` lines and `Name:` / `[A|B]:` / `Others:` lines, roughly chronological.

**Step 3: Commit**

```bash
git add extract-notes-zoom/scripts/zoom-audio-record.sh
git commit -m "feat(zoom): add audio-recording daemon orchestrator"
```

---

## Task 5: Wiring — gitignore, SKILL.md, launchd

**Files:**
- Create: `extract-notes-zoom/scripts/bin/.gitignore` (ignore compiled binary)
- Modify: `extract-notes-zoom/SKILL.md` (document the audio path + allowed-tools)
- Create: `extract-notes-zoom/scripts/com.user.zoom-audio-record.plist` (launchd template)

**Step 1: gitignore the binary**

```bash
mkdir -p extract-notes-zoom/scripts/bin
printf '*\n!.gitignore\n' > extract-notes-zoom/scripts/bin/.gitignore
```

**Step 2: launchd plist template** (`com.user.zoom-audio-record.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.zoom-audio-record</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>REPLACE_WITH_ABS_PATH/zoom-audio-record.sh</string>
    <string>--daemon</string>
    <string>--notes-dir=REPLACE_WITH_NOTES_DIR</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/zoom-audio-record.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/zoom-audio-record.err.log</string>
</dict>
</plist>
```

**Step 3: Update SKILL.md**

Add a section documenting the audio-capture path as the screenshare-proof
alternative, and add allowed-tools entries:
```
  - Bash(bash *zoom-audio-record.sh*)
  - Bash(*zoom-audio-capture*)
  - Bash(python3 *zoom-audio-merge.py*)
```
Document: one-time `swiftc` compile step; Screen Recording permission needed
for the capture binary; Participants panel must be popped out.

**Step 4: Commit**

```bash
git add extract-notes-zoom/scripts/bin/.gitignore \
        extract-notes-zoom/scripts/com.user.zoom-audio-record.plist \
        extract-notes-zoom/SKILL.md
git commit -m "feat(zoom): wire audio path — gitignore binary, launchd template, SKILL docs"
```

---

## Verification checklist (whole feature)

- [ ] `python3 -m pytest test_zoom_audio_merge.py -v` → all pass (automated).
- [ ] Poller logs name + 0/1 mute flips in a real meeting; exits on SIGTERM.
- [ ] Capture binary compiles; produces two non-empty 16 kHz mono WAVs + start epoch.
- [ ] End-to-end non-daemon run yields a chronological, speaker-labelled transcript.
- [ ] Transcript feeds `/extract-notes-zoom from FILE` cleanly.
- [ ] **Screenshare test:** start sharing, confirm Participants poll keeps logging
      (panel popped out) and audio capture continues.

## Notes for the implementer

- **TDD applies to Task 1 only** — it's the deterministic core. Tasks 2–4 touch
  live Zoom/permissions and are verified manually; keep them simple and obvious.
- **Don't commit the compiled binary** (`scripts/bin/zoom-audio-capture`).
- The Swift converter blocks are the fiddliest part; if app-audio conversion
  misbehaves, capture at SCK's native rate and let whisper's own resampling /
  the ffmpeg step handle it rather than converting in-process.
- Polling `\r`-terminated osascript output mirrors the parsing already used in
  `zoom-closed-caption.sh` — keep that delimiter choice for consistency.
