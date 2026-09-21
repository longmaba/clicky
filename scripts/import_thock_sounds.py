#!/usr/bin/env python3
"""Import the pinned, explicitly paired Thock/tplai soundpacks additively.

  python3 scripts/import_thock_sounds.py --ffmpeg /path/to/ffmpeg
  python3 scripts/import_thock_sounds.py --ffmpeg /path/to/ffmpeg --check

Only ZIP members referenced by the publisher's config are read. No archive
content is executed or extracted to disk. Existing recorded profiles and all
five original effects are checked against the source lock and preserved.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import urllib.request
import wave
import zipfile

from extract_sounds import fades, json_bytes, wav_bytes

PROJECT = Path(__file__).resolve().parents[1]
RATE = 48_000
SOURCE_RATE = 44_100
KEY_CATEGORIES = {"space": ["7:44"], "enter": ["7:40", "7:88"], "backspace": ["7:42"]}
MAX_ARCHIVE_BYTES = 25_000_000
MAX_MEMBER_BYTES = 5_000_000


def digest(payload):
    return hashlib.sha256(payload).hexdigest()


def checked_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value:
        raise ValueError(f"Unsafe source path: {value!r}")
    return value


def fetch(url, expected_hash, target, offline=False):
    if target.is_file():
        payload = target.read_bytes()
    else:
        if offline:
            raise ValueError(f"Missing cached source in offline mode: {target}")
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = response.read(MAX_ARCHIVE_BYTES + 1)
    if len(payload) > MAX_ARCHIVE_BYTES or digest(payload) != expected_hash:
        raise ValueError(f"Source size/hash mismatch: {target.name}")
    if not target.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
    return payload


def read_member(archive, name):
    checked_path(name)
    entries = [entry for entry in archive.infolist() if entry.filename == name]
    if len(entries) != 1 or entries[0].is_dir() or entries[0].file_size > MAX_MEMBER_BYTES:
        raise ValueError(f"Missing, duplicate or oversized source member: {name}")
    return archive.read(entries[0])


def pcm_source(payload):
    with wave.open(io.BytesIO(payload), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getcomptype()) != (1, 2, SOURCE_RATE, "NONE"):
            raise ValueError("Expected publisher mono 16-bit 44100 Hz PCM WAV")
        samples = array.array("h", reader.readframes(reader.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples or not any(samples) or any(abs(value) >= 32767 for value in samples):
        raise ValueError("Empty, silent or clipped source WAV")
    return samples


def measurements(samples, rate):
    peak = max(abs(value) for value in samples)
    onset = next((i for i, value in enumerate(samples) if abs(value) >= peak * .2), 0)
    nonzero = next((i for i, value in enumerate(samples) if value != 0), 0)
    return {"frames": len(samples), "sampleRate": rate, "durationSeconds": round(len(samples) / rate, 9),
            "peak": round(peak, 9), "rms": round(math.sqrt(sum(value * value for value in samples) / len(samples)), 9),
            "firstNonzeroMilliseconds": round(nonzero * 1000 / rate, 6),
            "first20PercentPeakMilliseconds": round(onset * 1000 / rate, 6)}


def render(payload, ffmpeg, processing):
    source_pcm = pcm_source(payload)
    source_nonzero = next(i for i, value in enumerate(source_pcm) if value != 0)
    # Trim digital zeros only, never a level threshold or a percentage of peak.
    # Keep at least 0.5 ms of the source silence before its very first nonzero bit.
    removed = max(0, source_nonzero - math.ceil(processing["prerollSeconds"] * SOURCE_RATE))
    command = [str(ffmpeg), "-v", "error", "-i", "pipe:0", "-map", "0:a:0", "-ac", "1",
               "-ar", str(RATE), "-af", "aresample=resampler=swr:filter_size=32:phase_shift=10:linear_interp=1:exact_rational=1:dither_method=none",
               "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"]
    decoded = array.array("f", subprocess.run(command, input=payload, capture_output=True, check=True).stdout)
    if sys.byteorder != "little":
        decoded.byteswap()
    if not decoded or not all(math.isfinite(value) for value in decoded):
        raise ValueError("Invalid decoded source")
    removed_output = round(removed * RATE / SOURCE_RATE)
    rendered = fades((value * processing["commonGain"] for value in decoded[removed_output:]),
                     fade_in=processing["fadeInSeconds"], fade_out=processing["fadeOutSeconds"])
    output = wav_bytes(rendered)
    # Report encoded PCM values so the checker can reproduce metrics directly.
    with wave.open(io.BytesIO(output), "rb") as reader:
        encoded = array.array("h", reader.readframes(reader.getnframes()))
    if sys.byteorder != "little":
        encoded.byteswap()
    return output, {"sourceMetrics": measurements([value / 32768 for value in source_pcm], SOURCE_RATE),
                    "outputMetrics": measurements([value / 32768 for value in encoded], RATE),
                    "processing": {"firstSourceNonzeroFrame": source_nonzero,
                                   "removedDigitalLeadingFrames44100Hz": removed,
                                   "removedLeadingFrames48000Hz": removed_output,
                                   "commonGain": processing["commonGain"]}}


def validate_config(config, entry):
    if config.get("id") != entry["packID"] or config.get("metadata") != entry["metadata"]:
        raise ValueError(f"Source config metadata changed: {entry['id']}")
    if config.get("license", {}).get("type") != "MIT" or config["metadata"].get("supportsKeyUp") is not True:
        raise ValueError(f"Source is not an approved paired MIT pack: {entry['id']}")
    # The catalog groups switches under the publisher's own manufacturer name.
    if not isinstance(config["metadata"].get("brand"), str) or not config["metadata"]["brand"].strip():
        raise ValueError(f"Source config has no switch brand: {entry['id']}")
    if set(config.get("sounds", {})) != {"default", *KEY_CATEGORIES}:
        raise ValueError(f"Unexpected source key categories: {entry['id']}")
    for category, phases in config["sounds"].items():
        if set(phases) != {"down", "up"}:
            raise ValueError(f"Incomplete source phase mapping: {entry['id']}/{category}")
        for phase, paths in phases.items():
            if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)):
                raise ValueError(f"Missing or duplicate source phase variants: {category}/{phase}")
            for path in paths:
                if PurePosixPath(checked_path(path)).suffix != ".wav":
                    raise ValueError(f"Unexpected source sound type: {path}")


def build(lock_path, original_assets, cache, ffmpeg, offline=False):
    lock_bytes = lock_path.read_bytes()
    lock = json.loads(lock_bytes)
    if lock.get("schemaVersion") != 1:
        raise ValueError("Unsupported Thock source lock version")
    registry = lock["registry"]
    base_url = f"https://raw.githubusercontent.com/{registry['repository']}/{registry['commit']}"
    registry_bytes = fetch(base_url + "/manifest.json", registry["manifestSha256"], cache / "manifest.json", offline)
    registry_packs = {pack["id"]: pack for pack in json.loads(registry_bytes)["soundpacks"]["keyboard"]}
    existing = json.loads((original_assets / "profiles.json").read_text())
    originals = [profile for profile in existing if profile["id"] in lock["preserveProfileIDs"]]
    if [profile["id"] for profile in originals] != lock["preserveProfileIDs"] or digest(json_bytes(originals)) != lock["preservedProfilesSha256"]:
        raise ValueError("Original profile metadata differs from source lock; review before updating")
    files = {}
    for path, expected_hash in lock["preservedFiles"].items():
        checked_path(path)
        payload = (original_assets / path).read_bytes()
        if digest(payload) != expected_hash:
            raise ValueError(f"Original sound differs from source lock: {path}")
        files[path] = payload
    owned_ids = set(lock["preserveProfileIDs"]) | {entry["id"] for entry in lock["profiles"]}
    additional = [profile for profile in existing if profile["id"] not in owned_ids]
    manifests, records = list(originals), []
    for entry in lock["profiles"]:
        pack = registry_packs.get(entry["packID"])
        if pack is None or pack["metadata"] != entry["metadata"] or pack["content"]["path"] != entry["contentPath"]:
            raise ValueError(f"Locked pack not in pinned registry: {entry['id']}")
        relative_archive = f"{checked_path(entry['contentPath'])}/{entry['packID']}.zip"
        url = f"{base_url}/{relative_archive}"
        archive_payload = fetch(url, entry["archiveSha256"], cache / f"{entry['packID']}.zip", offline)
        with zipfile.ZipFile(io.BytesIO(archive_payload)) as archive:
            config_payload = read_member(archive, "config.json")
            if digest(config_payload) != entry["configSha256"]:
                raise ValueError(f"Source config hash mismatch: {entry['id']}")
            config = json.loads(config_payload)
            validate_config(config, entry)
            record = {"id": entry["id"], "packID": entry["packID"], "archive": {"url": url, "sha256": entry["archiveSha256"]},
                      "configSha256": entry["configSha256"], "metadata": config["metadata"], "license": config["license"],
                      "sourceSounds": config["sounds"], "selections": []}
            manifest = {"id": entry["id"], "name": entry["name"], "brand": config["metadata"]["brand"],
                        "subtitle": entry["subtitle"], "color": entry["color"],
                        "samples": [], "releaseSamples": [], "keySamples": {}, "gain": 1.0, "normalizationReference": False,
                        "provenance": {"source": url, "sourceKind": "thock-soundpack", "packID": entry["packID"], "author": "tplai", "license": "MIT"}}
            for category in ("default", *KEY_CATEGORIES):
                bank = {"samples": [], "releaseSamples": []}
                for source_phase, phase, field in (("down", "press", "samples"), ("up", "release", "releaseSamples")):
                    for index, source_file in enumerate(config["sounds"][category][source_phase], 1):
                        payload = read_member(archive, source_file)
                        if digest(payload) != entry["soundSha256"].get(source_file):
                            raise ValueError(f"Source WAV hash mismatch: {entry['id']}/{source_file}")
                        rendered, details = render(payload, ffmpeg, lock["processing"])
                        prefix = "" if category == "default" else category + "-"
                        path = f"Sounds/{entry['id']}/{prefix}{phase}-{index:02d}.wav"
                        files[path] = rendered
                        bank[field].append(path)
                        pointer = f"sounds.{category}.{source_phase}[{index - 1}]"
                        record["selections"].append({"path": path, "category": category, "phase": phase,
                            "sourceFile": source_file, "sourceSha256": digest(payload), "sha256": digest(rendered),
                            "identification": {"status": "verified", "method": "source-config", "configPointer": pointer,
                                               "evidence": f"Publisher config maps {source_file} explicitly to {pointer}."}, **details})
                if category == "default":
                    manifest.update(bank)
                else:
                    for key in KEY_CATEGORIES[category]:
                        manifest["keySamples"][key] = bank
            manifests.append(manifest)
            records.append(record)
    # Keep any independently added catalog entries; this importer only owns
    # the packs in its source lock, just as the original extractor owns its banks.
    manifests.extend(additional)
    report = {"schemaVersion": 1, "sourceKind": "thock-soundpack", "source": registry,
              "sourceLock": {"file": lock_path.name, "sha256": digest(lock_bytes)}, "processing": lock["processing"],
              "review": {"phaseIdentity": "Publisher config explicitly separates down/up and key categories; no waveform-based phase inference.",
                         "listeningReview": "Pending user audition; preservation verified against the publisher's source WAVs and phase mappings."},
              "profiles": records}
    files["profiles.json"] = json_bytes(manifests)
    files["thock-import.json"] = json_bytes(report)
    return files, report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lock", type=Path, default=PROJECT / "Assets/thock-sources.json")
    parser.add_argument("--original-assets", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--output", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--cache", type=Path, help="Source cache (default /tmp/clicky-thock-source/<locked commit>)")
    parser.add_argument("--ffmpeg", type=Path, default=shutil.which("ffmpeg"))
    parser.add_argument("--offline", action="store_true", help="Require the verified source cache; never download")
    parser.add_argument("--check", action="store_true", help="Rebuild in memory and compare all generated/retained files")
    args = parser.parse_args()
    if not args.ffmpeg:
        parser.error("FFmpeg not on PATH; supply --ffmpeg /path/to/ffmpeg")
    lock = json.loads(args.lock.read_text())
    cache = args.cache or Path("/tmp/clicky-thock-source") / lock["registry"]["commit"]
    files, report = build(args.lock, args.original_assets, cache, args.ffmpeg, args.offline)
    for relative, content in files.items():
        path = args.output / relative
        if args.check:
            if not path.is_file() or path.read_bytes() != content:
                raise SystemExit(f"Reproducibility check failed: {path}")
        elif not path.is_file() or path.read_bytes() != content:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    selections = [selection for profile in report["profiles"] for selection in profile["selections"]]
    presses = sum(selection["phase"] == "press" for selection in selections)
    releases = len(selections) - presses
    print(f"{'Verified' if args.check else 'Imported'} {len(report['profiles'])} paired profiles: {presses} press and {releases} release WAVs.")
    print(f"Preserved {len(lock['preserveProfileIDs'])} original profiles and {len(lock['preservedFiles'])} original WAVs byte-for-byte.")


if __name__ == "__main__":
    main()
