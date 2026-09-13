#!/usr/bin/env python3
"""Build a labeled audition WAV outside the app bundle; optionally play it.

  python3 scripts/audition_sounds.py
  python3 scripts/audition_sounds.py --profile silent --play

The companion JSON timeline lists the profile and variant heard at each time.
Playback does not change the review status in Assets/extraction.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import wave

PROJECT = Path(__file__).resolve().parents[1]
RATE = 48_000


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--assets", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--output", type=Path, default=Path("/tmp/clicky-audition.wav"))
    parser.add_argument("--profile", help="One profile ID, or extras")
    parser.add_argument("--gap", type=float, default=0.22, help="Silence between variants, in seconds")
    parser.add_argument("--play", action="store_true", help="Play the composite using afplay or ffplay")
    args = parser.parse_args()
    if not 0.05 <= args.gap <= 10:
        parser.error("--gap must be between 0.05 and 10 seconds")
    manifests = json.loads((args.assets / "profiles.json").read_text())
    groups = [(p["id"], p["samples"]) for p in manifests]
    groups.append(("extras", [f"Sounds/Extras/{name}.wav" for name in ["soft", "crisp", "hard", "ding", "typewriter"]]))
    if args.profile:
        groups = [(name, paths) for name, paths in groups if name == args.profile]
        if not groups:
            parser.error(f"Unknown profile {args.profile!r}")
    frames = bytearray(b"\0\0" * round(0.3 * RATE))
    timeline = []
    for name, paths in groups:
        for path in paths:
            with wave.open(str(args.assets / path), "rb") as source:
                if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, RATE):
                    raise ValueError(f"Unexpected WAV format: {path}")
                start = len(frames) / (2 * RATE)
                samples = source.readframes(source.getnframes())
            frames.extend(samples)
            end = len(frames) / (2 * RATE)
            timeline.append({"profile": name, "path": path, "startSeconds": round(start, 4), "endSeconds": round(end, 4)})
            print(f"{start:7.3f}s  {name:12}  {Path(path).stem}")
            frames.extend(b"\0\0" * round(args.gap * RATE))
        frames.extend(b"\0\0" * round(0.65 * RATE))
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
