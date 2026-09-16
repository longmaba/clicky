#!/usr/bin/env python3
"""Build a labeled audition WAV outside the app bundle; optionally play it.

  python3 scripts/audition_sounds.py
  python3 scripts/audition_sounds.py --profile silent --play
  python3 scripts/audition_sounds.py --phase release
  python3 scripts/audition_sounds.py --phase pair --hold 0.035 --hold 0.3
  python3 scripts/audition_sounds.py --profile alps-skcm-blue --category all
  python3 scripts/audition_sounds.py --mouse --category all --hold 0.03 --hold 0.3
  python3 scripts/audition_sounds.py --interval 0.07 --voices 2 --gain 0.5

The companion JSON timeline lists the profile and variant heard at each time.
The all category includes each available keyboard or mouse category once;
specific missing special banks use that profile's generic sounds, like the app.
Playback does not change source or listening review status.
Releases use the app's 0.7 playback gain by default; --release-gain 1 auditions
the original recorded phase balance.
"""

from __future__ import annotations

import argparse
import array
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import wave

PROJECT = Path(__file__).resolve().parents[1]
RATE = 48_000
RELEASE_GAIN = 0.7
KEY_CATEGORIES = {"space": ("7:44",), "enter": ("7:40", "7:88"), "backspace": ("7:42",)}
MOUSE_CATEGORIES = {"left": ("9:1",), "right": ("9:2",), "middle": ("9:3",)}
CATEGORIES = {**KEY_CATEGORIES, **MOUSE_CATEGORIES}


def read_pcm(path):
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, RATE):
            raise ValueError(f"Unexpected WAV format: {path}")
        samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def select_categories(groups, category="default"):
    """Resolve special banks once per category; Enter aliases share one audition."""
    if category not in ("default", "all", *CATEGORIES):
        raise ValueError(f"Unknown audition category: {category}")
    selected = []
    for group in groups:
        mouse = any(key.startswith("9:") for key in (group.get("keySamples") or {}))
        available = tuple(MOUSE_CATEGORIES) if mouse else ("default", *KEY_CATEGORIES)
        categories = available if category == "all" else (category,)
        for requested in categories:
            bank = group
            source_category = "default"
            if requested != "default":
                overrides = group.get("keySamples") or {}
                bank = next((overrides[key] for key in CATEGORIES[requested] if key in overrides), None)
                if bank is None:
                    if category == "all":
                        continue
                    bank = group
                else:
                    source_category = requested
            selected.append({**bank, "id": group["id"], "category": requested, "sourceCategory": source_category})
    return selected


def build_audition(assets, groups, phase="pair", holds=(0.1,), gap=0.22, interval=None, voices=1, gain=1.0,
                   category="default", release_gain=RELEASE_GAIN):
    """Schedule release at key-up, mixing it over a still-decaying press."""
    scheduled, timeline, cache = [], [], {}
    cursor = round(0.3 * RATE)
    last_end = cursor
    stroke = 0

    def event(group, path, kind, start, voice, hold):
        nonlocal last_end
        if path not in cache:
            cache[path] = read_pcm(assets / path)
        samples = cache[path]
        phase_gain = release_gain if kind == "release" else 1.0
        scheduled.append((start, samples, phase_gain))
        last_end = max(last_end, start + len(samples))
        timeline.append({"profile": group["id"], "category": group["category"], "sourceCategory": group["sourceCategory"],
                         "path": path, "phase": kind, "stroke": stroke, "voice": voice,
                         "phaseGain": phase_gain, "outputGain": gain * phase_gain,
                         "holdSeconds": hold, "startSeconds": round(start / RATE, 6),
                         "endSeconds": round((start + len(samples)) / RATE, 6)})
        return start + len(samples)

    for group in select_categories(groups, category):
        presses, releases = group["samples"], group.get("releaseSamples") or []
        if phase == "release" and not releases:
            continue
        count = len(releases) if phase == "release" else max(len(presses), len(releases) if phase == "pair" else 0)
        for hold in holds if phase == "pair" else (0,):
            for index in range(count):
                end = cursor
                for voice in range(voices):
                    if phase != "release":
                        end = max(end, event(group, presses[index % len(presses)], "press", cursor, voice, hold))
                    if phase != "press" and releases:
                        release_start = cursor + (round(hold * RATE) if phase == "pair" else 0)
                        end = max(end, event(group, releases[index % len(releases)], "release", release_start, voice, hold))
                stroke += 1
                cursor = cursor + round(interval * RATE) if interval is not None else end + round(gap * RATE)
        cursor = max(cursor, last_end) + round(0.65 * RATE)
    if not timeline:
        raise ValueError("No release samples available for the selected profiles")
    mixed = array.array("d", [0]) * max(cursor, last_end)
    for start, samples, phase_gain in scheduled:
        for index, sample in enumerate(samples):
            mixed[start + index] += sample * phase_gain
    peak = max(abs(value) for value in mixed) * gain
    if peak > 32767:
        raise ValueError(f"Audition mix would clip; choose --gain {min(1, 32000 / (peak / gain)):.3f} or lower")
    pcm = array.array("h", (round(value * gain) for value in mixed))
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm.tobytes(), timeline


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--assets", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--output", type=Path, default=Path("/tmp/clicky-audition.wav"))
    parser.add_argument("--profile", help="One profile ID, or extras")
    parser.add_argument("--mouse", action="store_true", help="Audition the recorded mouse catalog")
    parser.add_argument("--category", choices=("default", *CATEGORIES, "all"), default="default")
    parser.add_argument("--gap", type=float, default=0.22, help="Silence between variants, in seconds")
    parser.add_argument("--phase", choices=("press", "release", "pair"), default="pair")
    parser.add_argument("--hold", type=float, action="append", help="Pair hold seconds; repeat for several holds (default 0.1)")
    parser.add_argument("--interval", type=float, help="Start-to-start stroke seconds for overlapping fast typing")
    parser.add_argument("--voices", type=int, default=1, help="Simultaneous keys per stroke, 1–8")
    parser.add_argument("--gain", type=float, default=1.0, help="Uniform audition gain, 0.01–1; preserves relative levels")
    parser.add_argument("--release-gain", type=float, default=RELEASE_GAIN,
                        help="Release phase multiplier, 0–1 (default 0.7, matching app playback)")
    parser.add_argument("--play", action="store_true", help="Play the composite using afplay or ffplay")
    args = parser.parse_args()
    if not 0.05 <= args.gap <= 10:
        parser.error("--gap must be between 0.05 and 10 seconds")
    holds = args.hold or [0.1]
    if any(not math.isfinite(hold) or not 0 <= hold <= 10 for hold in holds):
        parser.error("--hold must be between 0 and 10 seconds")
    if args.interval is not None and not 0.01 <= args.interval <= 10:
        parser.error("--interval must be between 0.01 and 10 seconds")
    if not 1 <= args.voices <= 8 or not 0.01 <= args.gain <= 1:
        parser.error("--voices must be 1–8 and --gain must be 0.01–1")
    if not math.isfinite(args.release_gain) or not 0 <= args.release_gain <= 1:
        parser.error("--release-gain must be between 0 and 1")
    manifests = json.loads((args.assets / ("mouse-profiles.json" if args.mouse else "profiles.json")).read_text())
    groups = list(manifests)
    if not args.mouse:
        groups.append({"id": "extras", "samples": [f"Sounds/Extras/{name}.wav" for name in ["soft", "crisp", "hard", "ding", "typewriter"]]})
    if args.profile:
        groups = [group for group in groups if group["id"] == args.profile]
        if not groups:
            parser.error(f"Unknown profile {args.profile!r}")
    try:
        frames, timeline = build_audition(args.assets, groups, args.phase, holds, args.gap, args.interval, args.voices, args.gain,
                                        category=args.category, release_gain=args.release_gain)
    except ValueError as error:
        parser.error(str(error))
    for event in timeline:
        print(f"{event['startSeconds']:7.3f}s  {event['profile']:12}  {event['category']:9}  {event['phase']:7}  {Path(event['path']).stem}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(frames)
    timeline_path = args.output.with_suffix(".json")
    timeline_path.write_text(json.dumps(timeline, indent=2) + "\n")
    print(f"Audition: {args.output}\nTimeline: {timeline_path}")
    if args.play:
        afplay = shutil.which("afplay")
        ffplay = shutil.which("ffplay")
        if afplay:
            subprocess.run([afplay, str(args.output)], check=True)
        elif ffplay:
            subprocess.run([ffplay, "-nodisp", "-autoexit", str(args.output)], check=True)
        else:
            parser.error("No afplay or ffplay found; open the generated WAV in an audio player")


if __name__ == "__main__":
    main()
