#!/usr/bin/env python3
"""Import the pinned CC0 Razer Orochi V2 button-down/up recordings.

  python3 scripts/import_thock_mouse_sounds.py --ffmpeg /path/to/ffmpeg
  python3 scripts/import_thock_mouse_sounds.py --ffmpeg /path/to/ffmpeg --check

Reads publisher config and WAV members directly from a hash-verified ZIP;
never extracts or executes archive content. Existing keyboard assets are
checked for preservation and never written by this importer.
"""

from __future__ import annotations

import argparse
import array
import io
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import wave
import zipfile

from extract_sounds import fades, json_bytes, wav_bytes
from import_thock_sounds import checked_path, digest, fetch, measurements, read_member

PROJECT = Path(__file__).resolve().parents[1]
SOURCE_RATE = 44100
RATE = 48000
BUTTONS = {"left": "9:1", "right": "9:2"}


def render_stereo(payload, ffmpeg, processing):
    with wave.open(io.BytesIO(payload), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (2, 2, SOURCE_RATE, "NONE"):
            raise ValueError("Expected publisher stereo PCM16 44100 Hz WAV")
        interleaved = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        interleaved.byteswap()
    if not interleaved or len(interleaved) % 2 or not any(interleaved) or any(abs(v) >= 32767 for v in interleaved):
        raise ValueError("Empty, silent, incomplete or clipped mouse source")
    channels = (interleaved[::2], interleaved[1::2])
    first_nonzero = next(i for i, (left, right) in enumerate(zip(*channels)) if left or right)
    removed = max(0, first_nonzero - math.ceil(processing["prerollSeconds"] * SOURCE_RATE))
    # Arithmetic-mean downmix is explicit and identical for every phase/button.
    # The trimming threshold is exact digital zero in BOTH original channels.
    filters = "pan=mono|c0=0.5*c0+0.5*c1,aresample=resampler=swr:filter_size=32:phase_shift=10:linear_interp=1:exact_rational=1:dither_method=none"
    command = [str(ffmpeg), "-v", "error", "-i", "pipe:0", "-map", "0:a:0", "-ar", str(RATE),
               "-af", filters, "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"]
    decoded = array.array("f", subprocess.run(command, input=payload, capture_output=True, check=True).stdout)
    if sys.byteorder != "little":
        decoded.byteswap()
    if not decoded or not all(math.isfinite(value) for value in decoded):
        raise ValueError("Invalid decoded mouse source")
    removed_output = round(removed * RATE / SOURCE_RATE)
    rendered = fades((value * processing["commonGain"] for value in decoded[removed_output:]),
                     fade_in=processing["fadeInSeconds"], fade_out=processing["fadeOutSeconds"])
    output = wav_bytes(rendered)
    with wave.open(io.BytesIO(output), "rb") as reader:
        encoded = array.array("h", reader.readframes(reader.getnframes()))
    if sys.byteorder != "little":
        encoded.byteswap()
    mono = [(left + right) / 65536 for left, right in zip(*channels)]
    return output, {"sourceMetrics": {"channels": 2, "sampleWidthBytes": 2, "sampleRate": SOURCE_RATE,
                    "frames": len(channels[0]), "durationSeconds": round(len(channels[0]) / SOURCE_RATE, 9),
                    "channelPeaks": [round(max(abs(v) for v in channel) / 32768, 9) for channel in channels],
                    "monoDownmix": measurements(mono, SOURCE_RATE)},
                    "outputMetrics": measurements([value / 32768 for value in encoded], RATE),
                    "processing": {"firstSourceNonzeroFrame": first_nonzero,
                        "removedDigitalLeadingFrames44100Hz": removed,
                        "removedLeadingFrames48000Hz": removed_output, "commonGain": processing["commonGain"]}}


def validate_config(config, entry):
    if config.get("id") != entry["packID"] or config.get("metadata") != entry["metadata"]:
        raise ValueError("Mouse source metadata differs from source lock")
    if config.get("license", {}).get("type") != "CC0" or config["metadata"].get("category") != "mouse" or config["metadata"].get("supportsKeyUp") is not True:
        raise ValueError("Expected approved paired CC0 mouse soundpack")
    if set(config.get("sounds", {})) != set(BUTTONS):
        raise ValueError("Expected explicit left/right mouse source categories")
    for button, phases in config["sounds"].items():
        if set(phases) != {"down", "up"}:
            raise ValueError(f"Incomplete mouse phases: {button}")
        for phase, paths in phases.items():
            if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)):
                raise ValueError(f"Missing/duplicate mouse source variants: {button}/{phase}")
            for path in paths:
                if Path(checked_path(path)).suffix != ".wav":
                    raise ValueError(f"Unexpected mouse source member: {path}")


def license_notice(entry, archive_url):
    return (f"{entry['name']} mouse sound recordings\n\n"
            f"Recording author: {entry['metadata']['author']}\n"
            "License declared by the publisher's soundpack config: CC0 1.0 Universal\n"
            "https://creativecommons.org/publicdomain/zero/1.0/\n"
            "Legal code: https://creativecommons.org/publicdomain/zero/1.0/legalcode\n\n"
            f"Pinned source archive: {archive_url}\n"
            f"Archive SHA-256: {entry['archiveSha256']}\n"
            f"Publisher config SHA-256: {entry['configSha256']}\n\n"
            "Clicky converts the stereo source to mono 48 kHz, applies common gain\n"
            "and short boundary fades, and removes only exact digital leading silence.\n"
            "The publisher explicitly identifies left/right button-down/up recordings.\n"
            "The mouse model identifies the recording; no manufacturer endorsement is implied.\n").encode("utf-8")


def build(lock_path, assets, cache, ffmpeg, offline=False):
    lock_bytes = lock_path.read_bytes()
    lock = json.loads(lock_bytes)
    if lock.get("schemaVersion") != 1:
        raise ValueError("Unsupported mouse source lock version")
    for relative, expected in lock["preservedFiles"].items():
        if digest((assets / checked_path(relative)).read_bytes()) != expected:
            raise ValueError(f"Existing keyboard asset differs from mouse source lock: {relative}")
    registry = lock["registry"]
    base = f"https://raw.githubusercontent.com/{registry['repository']}/{registry['commit']}"
    registry_bytes = fetch(base + "/manifest.json", registry["manifestSha256"], cache / "manifest.json", offline)
    packs = {pack["id"]: pack for pack in json.loads(registry_bytes)["soundpacks"]["mouse"]}
    files, profiles, records = {}, [], []
    for entry in lock["profiles"]:
        pack = packs.get(entry["packID"])
        if pack is None or pack["metadata"] != entry["metadata"] or pack["content"]["path"] != entry["contentPath"]:
            raise ValueError(f"Mouse pack differs from pinned registry: {entry['id']}")
        url = f"{base}/{checked_path(entry['contentPath'])}/{entry['packID']}.zip"
        archive_bytes = fetch(url, entry["archiveSha256"], cache / (entry["packID"] + ".zip"), offline)
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            config_bytes = read_member(archive, "config.json")
            if digest(config_bytes) != entry["configSha256"]:
                raise ValueError("Mouse publisher config hash mismatch")
            config = json.loads(config_bytes)
            validate_config(config, entry)
            profile = {"id": entry["id"], "name": entry["name"], "subtitle": entry["subtitle"], "color": entry["color"],
                       "samples": [], "releaseSamples": [], "keySamples": {}, "gain": 1.0, "normalizationReference": False,
                       "provenance": {"source": url, "sourceKind": "thock-mouse-soundpack", "packID": entry["packID"],
                                      "author": entry["metadata"]["author"], "license": "CC0"}}
            record = {"id": entry["id"], "packID": entry["packID"], "archive": {"url": url, "sha256": entry["archiveSha256"]},
                      "configSha256": entry["configSha256"], "metadata": config["metadata"], "license": config["license"],
                      "sourceSounds": config["sounds"], "fallback": {"9:3": "left", "reason": "No middle-button recording in this source pack; runtime uses the generic left pair."},
                      "selections": []}
            for button, key in BUTTONS.items():
                bank = {"samples": [], "releaseSamples": []}
                for source_phase, phase, field in (("down", "press", "samples"), ("up", "release", "releaseSamples")):
                    for index, source_file in enumerate(config["sounds"][button][source_phase], 1):
                        payload = read_member(archive, source_file)
                        if digest(payload) != entry["soundSha256"].get(source_file):
                            raise ValueError(f"Mouse source WAV hash mismatch: {source_file}")
                        output, details = render_stereo(payload, ffmpeg, lock["processing"])
                        path = f"Sounds/{entry['id']}/{button}-{phase}-{index:02d}.wav"
                        files[path] = output
                        bank[field].append(path)
                        pointer = f"sounds.{button}.{source_phase}[{index - 1}]"
                        record["selections"].append({"path": path, "category": button, "phase": phase,
                            "sourceFile": source_file, "sourceSha256": digest(payload), "sha256": digest(output),
                            "identification": {"status": "verified", "method": "source-config", "configPointer": pointer,
                                               "evidence": f"Publisher config maps {source_file} explicitly to {pointer}."}, **details})
                profile["keySamples"][key] = bank
                if button == "left":
                    profile.update(bank)
            profiles.append(profile)
            records.append(record)
            files[entry["noticePath"]] = license_notice(entry, url)
    # Future independently imported mouse entries remain outside this importer's ownership.
    existing_manifest = assets / "mouse-profiles.json"
    if existing_manifest.is_file():
        owned = {profile["id"] for profile in profiles}
        profiles.extend(profile for profile in json.loads(existing_manifest.read_text()) if profile["id"] not in owned)
    report = {"schemaVersion": 1, "sourceKind": "thock-mouse-soundpack", "source": registry,
              "sourceLock": {"file": lock_path.name, "sha256": digest(lock_bytes)}, "processing": lock["processing"],
              "review": {"phaseIdentity": "Publisher config explicitly identifies left/right down/up; no waveform-based phase inference.",
                         "listeningReview": "Pending user audition; format, source identity, processing and output hashes are verified."},
              "profiles": records, "excludedPacks": lock["excludedPacks"]}
    files["mouse-profiles.json"] = json_bytes(profiles)
    files["thock-mouse-import.json"] = json_bytes(report)
    return files, report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lock", type=Path, default=PROJECT / "Assets/thock-mouse-sources.json")
    parser.add_argument("--assets", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--output", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=shutil.which("ffmpeg"))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--check", action="store_true", help="Rebuild in memory and compare; no asset writes")
    args = parser.parse_args()
    if not args.ffmpeg:
        parser.error("FFmpeg not on PATH; supply --ffmpeg /path/to/ffmpeg")
    lock = json.loads(args.lock.read_text())
    cache = args.cache or Path("/tmp/clicky-thock-source") / lock["registry"]["commit"]
    files, report = build(args.lock, args.assets, cache, args.ffmpeg, args.offline)
    for relative, payload in files.items():
        path = args.output / relative
        if args.check:
            if not path.is_file() or path.read_bytes() != payload:
                raise SystemExit(f"Mouse reproducibility check failed: {path}")
        elif not path.is_file() or path.read_bytes() != payload:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
    count = sum(len(record["selections"]) for record in report["profiles"])
    print(f"{'Verified' if args.check else 'Imported'} {len(report['profiles'])} recorded mouse profile(s), {count} button/phase WAVs.")
    print(f"Preserved {len(lock['preservedFiles'])} existing keyboard asset files; excluded {len(report['excludedPacks'])} unsuitable source packs.")


if __name__ == "__main__":
    main()
