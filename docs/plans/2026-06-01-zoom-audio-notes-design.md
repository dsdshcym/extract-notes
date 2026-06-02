# Zoom Audio Notes — Design

**Date:** 2026-06-01
**Status:** Design validated, not yet implemented
**Author:** Yiming (with Claude)

## Problem

`scripts/zoom-closed-caption.sh` extracts meeting transcripts by scraping Zoom's
in-window closed-caption overlay via the macOS Accessibility (AX) API
(`window "Zoom Meeting" → table 1`).

**Critical failure:** while *you* are screensharing, Zoom collapses the main
meeting window into a floating panel. The `window "Zoom Meeting"` handle and its
caption table no longer exist, so CC scraping silently stops for the entire
duration of your share — exactly when you're often presenting and most want a
record.

## Goal

A screenshare-proof way to capture the meeting and produce notes. Decided
constraints (from brainstorming):

- **Post-meeting transcript is acceptable** — no need to keep a live `/tmp`
  stream during the meeting. Capture audio during, transcribe + extract after.
- **Capture method: ScreenCaptureKit (SCK), per-app audio.** macOS 13+ native,
  no virtual audio devices (BlackHole) and no system-audio reconfiguration.
- **Transcription: local `whisper.cpp`** (`whisper-cli`, already installed).
  Private, offline, no per-minute cost. Work-meeting audio never leaves the Mac.
- **Diarization is a must-have**, via visual active-speaker detection (below).
- **Participant poll must survive screensharing** — require the Participants
  panel popped out into its own window so its AX handle persists while sharing.
- **Trigger: launchd daemon**, mirroring `zoom-closed-caption.sh` — auto-detect
  meeting, record start→end, then transcribe + `/extract-notes-zoom` + save `.org`.

## Environment (verified 2026-06-01)

- macOS 26.4 → full ScreenCaptureKit support.
- `swiftc` present → can compile a helper binary.
- `whisper-cli` (whisper.cpp 1.8.4 via brew) + `ffmpeg` present.
- Only `for-tests-ggml-tiny.bin` model present → must download a real model
  (e.g. `ggml-base.en.bin`) as a one-time setup step.

## Why not other approaches

- **Hook into Zoom directly:** the desktop client exposes no audio hook/API.
  Live audio is only available via Zoom's Meeting SDK (bot-as-participant), not
  by instrumenting the installed app. Out of scope.
- **Fix the AX CC path during screenshare:** brittle; depends on finding where
  the caption overlay relocates, which Zoom may change. Audio capture is
  independent of Zoom's UI tree and therefore robust.
- **BlackHole virtual device:** works but needs manual audio-device setup and a
  Multi-Output device you must remember to select. SCK avoids all of that.

## Architecture

Three new pieces, living alongside the existing scripts.

### 1. `scripts/zoom-audio-capture.swift` → compiled to `scripts/bin/zoom-audio-capture`

A small Swift helper, the single Screen-Recording-permissioned binary. It does
two jobs while it runs, until it receives SIGTERM:

- **App audio (others):** SCK captures `zoom.us`'s application audio output →
  `others.wav`. This is everyone else's voices (they come out of system output).
- **Mic (you):** AVAudioEngine records the default input device → `me.wav`.

Two separate tracks is deliberate: transcribing each independently gives free,
reliable **2-way** labelling ("Me" vs "Others") with no diarization at all.
Diarization (below) then refines the "Others" side into real names.

> Note: SCK app-audio captures only what Zoom *plays* (remote participants), not
> your mic. That's why the mic is a parallel AVAudioEngine stream.

### 2. `scripts/zoom-audio-record.sh` — orchestrator (bash)

Reuses helpers from `zoom-closed-caption.sh`: `meeting_window_exists`,
`get_meeting_id`, `notify`. Daemon loop:

1. Detect Zoom Meeting window appears.
2. Launch the Swift helper (audio) + the participant poller (below).
3. Poll for the meeting window closing.
4. On meeting end: SIGTERM the helper, stop the poller, run the pipeline.

### 3. Transcription + diarization merge (post-meeting)

1. `ffmpeg` resample `me.wav` / `others.wav` → 16 kHz mono.
2. `whisper-cli --output-csv` on each → timestamped segments.
3. Python merge:
   - `me` segments → label **Me**.
   - `others` segments → assign a name via the speaking timeline (below).
   - Interleave both by timestamp → `Me [hh:mm:ss]: …` / `Alice [hh:mm:ss]: …`.
   - Write `/tmp/zoom_audio_{mid}_{date}_transcript.txt`.
4. Existing flow: `claude -p "/extract-notes-zoom from <file>"` → save `.org`
   under `--notes-dir` (unchanged from the CC script).

## Participant data (AX, verified live)

The popped-out Participants window exposes the roster:

```
window "Participants (N)"
  → outline 1 of scroll area 1
    → row → cell → static text   (value = "Yiming Chen (Host, me)")
                 + image desc = "Computer audio muted" | "Computer audio unmuted"
                 + image desc = "Video off"
```

Two uses:

### Roster context (cheap, always-on)
Scrape the attendee list at meeting start (and end). Pass it to
`/extract-notes-zoom` so Claude names attendees and attributes lines correctly.
Gets ~80% of diarization value with ~15 lines and no timing.

### Visual active-speaker detection (the diarization backbone)

**Key finding (verified):** the mic icon's AX `description` is **binary** —
`muted` vs `unmuted` — and does **not** change while speaking. `AXValueDescription`
is empty; there is no volume/level attribute. Zoom *draws* a green volume
animation but never surfaces it to the accessibility tree.

The speaking signal is therefore **visual only**: the mic glyph is **dim-gray
when silent, bright-white when talking** (confirmed via screenshots). AX is blind
to it; pixels are not. AX still gives us the icon's exact **screen rect**
(verified: e.g. `pos=1434,1148 size=26x26`), so we can sample just that rect.

**Per poll (~3–4 Hz), per participant row:**
1. Read name + mic `description` + icon screen rect (re-query each poll — rows
   virtualize/scroll, so cached rects go stale).
2. `description = muted` → silent, skip.
3. `description = unmuted` → sample mean luma of the icon rect.
4. Log `timestamp, name, luma`.

**Calibration:** do not hardcode a luma threshold (varies by theme/display).
Track each participant's rolling baseline (dim) and peak; "speaking" = luma
clearly above baseline / near peak. Self-tunes per session.

**Merge into transcript:** for each whisper "Others" segment, choose the
participant whose speaking-windows overlap it most → that name. Fall back to
"Others" when nobody is clearly speaking or it's ambiguous.

## Permissions

- **Screen Recording** is required for both SCK audio capture and pixel
  sampling — one grant covers both. The single Swift helper is the only thing
  that needs it. (Confirmed needed: `screencapture` failed with "could not
  create image from display" without it.)
- **Accessibility** — already used by the existing CC/transcript scripts.

Doing pixel sampling **inside the Swift helper** (via CoreGraphics
`CGWindowListCreateImage` on the Participants window region) is cleaner than
shelling out to `screencapture`, and keeps everything under one permissioned
process.

## Known limitations (accepted)

- **Large meetings:** the participants list virtualizes; participants scrolled
  off-screen can't be sampled. Fine for typical meeting sizes; degrades past
  roughly one screen of participants.
- **Crosstalk / overlap:** simultaneous speakers → segment attributed to the
  dominant speaker, or "Others."
- **Brightness threshold:** not yet numerically verified (Screen Recording
  permission was unavailable during design). Auto-calibration is the hedge;
  validate during the first real multi-person run.
- **Remote speakers within the mixed "Others" track** cannot be separated by
  audio alone — names come entirely from the visual speaking timeline.

## Open items before / during implementation

1. Confirm the dim-vs-bright luma delta and a robust calibration rule in a real
   multi-person meeting.
2. Confirm the "speaking" stays detectable when the Participants panel is small
   / docked vs popped out (we require popped-out for screenshare resilience).
3. One-time model download step (`ggml-base.en.bin` or similar) + where to store it.
4. launchd plist mirroring the existing CC daemon.
