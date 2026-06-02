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
import argparse
import csv
import sys


def read_segments(path):
    """Read a whisper -ocsv file → list of (start_s, end_s, text)."""
    segs = []
    try:
        with open(path, newline="") as f:
            for i, row in enumerate(csv.reader(f)):
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
    """Read the poller TSV → list of (epoch, name, unmuted_bool)."""
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
                rows.append((epoch, parts[1], parts[2] == "0"))  # muted col: 0 == unmuted
    except FileNotFoundError:
        pass
    return rows


def unmuted_during(timeline, start_wc, end_wc):
    """Names unmuted in any poll sample overlapping [start_wc, end_wc].

    Widen the window by PAD seconds each side so a segment falling between
    poll samples still catches the relevant state (~3-4 Hz polling)."""
    PAD = 0.75
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
