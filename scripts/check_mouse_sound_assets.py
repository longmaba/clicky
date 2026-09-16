#!/usr/bin/env python3
"""Check recorded mouse button/phase mappings, source hashes and PCM quality."""

import argparse
import array
import hashlib
import json
from pathlib import Path
import sys
import wave

from import_thock_sounds import measurements


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def check_mouse_assets(assets):
    profiles = json.loads((assets / "mouse-profiles.json").read_text())
    report = json.loads((assets / "thock-mouse-import.json").read_text())
    lock_payload = (assets / "thock-mouse-sources.json").read_bytes()
    lock = json.loads(lock_payload)
    assert report["sourceLock"]["sha256"] == sha256(lock_payload), "Mouse source lock hash mismatch"
    records = {record["id"]: record for record in report["profiles"]}
    entries = {entry["id"]: entry for entry in lock["profiles"]}
    assert len(profiles) == len({profile["id"] for profile in profiles})
    assert {profile["id"] for profile in profiles} == set(records) == set(entries), "Mouse profile/source mismatch"
    rows = []
    for profile in profiles:
        entry, record = entries[profile["id"]], records[profile["id"]]
        assert record["archive"]["sha256"] == entry["archiveSha256"] and record["configSha256"] == entry["configSha256"]
        assert record["license"]["type"] == "CC0", "Unapproved mouse license"
        assert set(profile["keySamples"]) == {"9:1", "9:2"}, "Recorded mouse must map left and right buttons"
        assert profile["samples"] == profile["keySamples"]["9:1"]["samples"]
        assert profile["releaseSamples"] == profile["keySamples"]["9:1"]["releaseSamples"]
        assert record["fallback"]["9:3"] == "left", "Unrecorded middle button must use the documented generic fallback"
        selections = {selection["path"]: selection for selection in record["selections"]}
        assigned = []
        for key, category in (("9:1", "left"), ("9:2", "right")):
            bank = profile["keySamples"][key]
            for field, phase, source_phase in (("samples", "press", "down"), ("releaseSamples", "release", "up")):
                assert isinstance(bank[field], list) and bank[field], f"Missing mouse phase: {key}/{phase}"
                for path in bank[field]:
                    assert path.startswith(f"Sounds/{profile['id']}/") and ".." not in Path(path).parts
                    assigned.append(path)
                    selection = selections[path]
                    assert selection["phase"] == phase and selection["category"] == category, f"Wrong mouse phase/category: {path}"
                    sources = record["sourceSounds"][category][source_phase]
                    assert selection["sourceFile"] in sources, f"Wrong publisher mouse phase: {path}"
                    assert selection["sourceSha256"] == entry["soundSha256"][selection["sourceFile"]], f"Mouse source WAV hash mismatch: {path}"
                    identity = selection["identification"]
                    assert identity["status"] == "verified" and identity["method"] == "source-config" and identity.get("evidence")
                    assert identity["configPointer"] == f"sounds.{category}.{source_phase}[{sources.index(selection['sourceFile'])}]"
                    payload = (assets / path).read_bytes()
                    assert sha256(payload) == selection["sha256"], f"Mouse output WAV hash mismatch: {path}"
                    with wave.open(str(assets / path), "rb") as reader:
                        assert (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getcomptype()) == (1, 2, 48000, "NONE")
                        pcm = array.array("h", reader.readframes(reader.getnframes()))
                    if sys.byteorder != "little":
                        pcm.byteswap()
                    assert pcm and len(pcm) <= 48000 and pcm[0] == pcm[-1] == 0, f"Invalid mouse PCM boundaries/duration: {path}"
                    measured = measurements([value / 32768 for value in pcm], 48000)
                    assert 0 < measured["peak"] < .5, f"Missing mouse headroom: {path}"
                    assert measured["firstNonzeroMilliseconds"] <= 8, f"Mouse digital lead-in exceeds 8 ms: {path}"
                    assert measured == selection["outputMetrics"], f"Mouse output measurements changed: {path}"
                    rows.append({"profile": profile["id"], "button": category, "phase": phase, "path": path, **measured})
        assert len(assigned) == len(set(assigned)), "Mouse phases/buttons must use distinct recordings"
        assert set(assigned) == set(selections), "Missing or unexpected recorded mouse samples"
    return {"profileCount": len(profiles), "sampleCount": len(rows),
            "pressSampleCount": sum(row["phase"] == "press" for row in rows),
            "releaseSampleCount": sum(row["phase"] == "release" for row in rows),
            "maximumPeak": max(row["peak"] for row in rows),
            "middleButtonFallback": "Generic left pair; no middle-button recording is claimed",
            "listeningReview": "Not performed by this checker", "failures": [], "samples": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=Path(__file__).resolve().parents[1] / "Assets")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = check_mouse_assets(args.assets)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Passed: {report['profileCount']} recorded mouse profile(s), {report['pressSampleCount']} presses, "
          f"{report['releaseSampleCount']} releases; source mapping/hashes, PCM format, boundaries and headroom.")


if __name__ == "__main__":
    main()
