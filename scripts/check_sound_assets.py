#!/usr/bin/env python3
"""Check bundled WAV attack timing, boundaries and headroom without audio hardware.

The timing metric is the first frame reaching 20% of the variant's peak. It is
an asset regression check, not a physical key-to-ear latency measurement.
Original excerpt profiles are checked for renewed sharp impacts after the
initial attack. Catalog phase stems are checked against publisher mappings and
hashes without treating their quieter mechanical lead-ins as unwanted delays.
Analysis filters never change the audio assets.
"""

import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys
import wave


def impact_metrics(samples, profile):
    """Find a renewed sharp attack, rather than treating ringing as another hit.

    Silent/Office have strong rounded low-frequency bodies. Analyze their upper
    texture band over 2 ms so zero crossings in those bodies do not look like
    new impacts. These analysis filters are never applied to bundled audio.
    """
    soft = profile in ("silent", "office")
    cutoff, passes, width = (1800, 2, 96) if soft else (250, 1, 48)
    alpha = 1 / (1 + 2 * math.pi * cutoff / 48000)
    filtered = [value / 32768 for value in samples]
    for _ in range(passes):
        previous_input = previous_output = 0
        output = []
        for value in filtered:
            result = alpha * (previous_output + value - previous_input)
            output.append(result)
            previous_input, previous_output = value, result
        filtered = output
    envelope = [math.sqrt(sum(v * v for v in filtered[start:start + width]) / width)
                for start in range(0, len(filtered) - width + 1, 24)]
    primary = max(envelope[:13], default=0)
    secondary = []
    start_ms = 12 if profile == "office" else 8
    if primary > 0:
        for i in range(start_ms * 2, len(envelope) - 1):
            level = envelope[i]
            ratio = level / primary
            if level < envelope[i - 1] or level <= envelope[i + 1] or ratio < (0.18 if soft else 0.12):
                continue
            recent = max(envelope[i - 6:i - 4])
            valley = min(sum(envelope[j:j + 4]) / 4 for j in range(i - 16, i - 6))
            floor = primary * (0.01 if soft else 0.005)
            rise = level / max(valley, floor)
            fast_rise = level / max(recent, floor)
            if rise < (4 if soft else 3) or fast_rise < (3 if soft else 2.5):
                continue
            hit = {"milliseconds": i * 0.5, "relativeRMS": round(ratio, 7),
                   "riseFromValley": round(rise, 4), "riseWithinTwoMilliseconds": round(fast_rise, 4)}
            if secondary and hit["milliseconds"] - secondary[-1]["milliseconds"] < 4:
                if ratio <= secondary[-1]["relativeRMS"]:
                    continue
                secondary.pop()
            secondary.append(hit)
    peak_index = max(range(len(envelope)), key=envelope.__getitem__) if envelope else 0
    return {"unexpectedSecondaryImpacts": secondary,
            "impactBandPeakMilliseconds": peak_index * 0.5,
            "impactAnalysis": {"highPassHz": cutoff, "filterPasses": passes,
                "rmsWindowMilliseconds": width / 48, "hopMilliseconds": 0.5,
                "initialWindowStartMaximumMilliseconds": 6, "secondaryStartMinimumMilliseconds": start_ms,
                "minimumRelativeRMS": 0.18 if soft else 0.12,
                "minimumRiseFromValley": 4 if soft else 3,
                "minimumRiseWithinTwoMilliseconds": 3 if soft else 2.5}}


def creamy_impact_metrics(samples):
    # Analysis only: remove the low-frequency decay so a normal resonant tail
    # does not resemble a second strike. The bundled samples are never altered.
    alpha = 1 / (1 + 2 * math.pi * 250 / 48000)
    previous_input = previous_output = 0
    filtered = []
    for value in samples:
        output = alpha * (previous_output + value - previous_input)
        filtered.append(output / 32768)
        previous_input, previous_output = value, output
    # Full 1 ms RMS windows, advanced by 0.5 ms. A second transient at or
    # after 8 ms must be weak compared with the initial 0–6 ms impact.
    windows = [(start / 48, math.sqrt(sum(value * value for value in filtered[start:start + 48]) / 48))
               for start in range(0, len(filtered) - 47, 24)]
    primary = max((rms for start, rms in windows if start <= 6), default=0)
    later_time, later = max(((start, rms) for start, rms in windows if start >= 8),
                            key=lambda window: window[1], default=(0, 0))
    return {
        "creamyLateToPrimaryRMSRatio": round(later / primary, 7) if primary else 0,
        "creamyLaterPeakMilliseconds": later_time,
        "creamyPrimaryRMS": round(primary, 7),
    }


def inspect(path, single_impact=False, profile=None):
    with wave.open(str(path), "rb") as reader:
        assert (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) == (1, 2, 48000), str(path)
        samples = array.array("h", reader.readframes(reader.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    assert samples and samples[0] == samples[-1] == 0, f"Nonzero boundary: {path}"
    peak = max(abs(value) for value in samples)
    assert 0 < peak < 16384, f"Missing headroom: {path}"
    onset = next(i for i, value in enumerate(samples) if abs(value) >= peak * 0.2)
    measured = {
        "frames": len(samples),
        "peak": round(peak / 32768, 7),
        "rms": round(math.sqrt(sum(value * value for value in samples) / len(samples)) / 32768, 7),
        "firstNonzeroMilliseconds": round(next(i for i, value in enumerate(samples) if value) / 48, 6),
        "first20PercentPeakMilliseconds": round(onset / 48, 6),
    }
    if single_impact:
        measured.update(creamy_impact_metrics(samples))
    if profile:
        measured.update(impact_metrics(samples, profile))
    return measured


def check_assets(assets, baseline=None):
    profiles = json.loads((assets / "profiles.json").read_text())
    provenance = json.loads((assets / "extraction.json").read_text())
    legacy_ids = {p["id"] for p in provenance["profiles"]}
    catalog_path = assets / "thock-import.json"
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {"profiles": []}
    catalog_records = {p["id"]: p for p in catalog["profiles"]}
    assert len(legacy_ids) == 10 and not legacy_ids.intersection(catalog_records)
    assert len(profiles) == len({p["id"] for p in profiles})
    assert {p["id"] for p in profiles} == legacy_ids.union(catalog_records), "Catalog/provenance profile mismatch"
    rows, failures = [], []
    for profile in profiles:
        record = catalog_records.get(profile["id"])
        assert profile["samples"] and (record or len(profile["samples"]) == 6)
        releases = profile.get("releaseSamples")
        assert releases is None or isinstance(releases, list), f"Invalid releaseSamples: {profile['id']}"
        releases = releases or []
        assert len(set(releases)) == len(releases), f"Duplicate releases: {profile['id']}"
        categories = {"7:44": "space", "7:40": "enter", "7:88": "enter", "7:42": "backspace"}
        phases = [("default", "press", relative) for relative in profile["samples"]]
        phases += [("default", "release", relative) for relative in releases]
        for key, sample_set in (profile.get("keySamples") or {}).items():
            assert key in categories, f"Unknown bundled sample category: {key}"
            assert sample_set["samples"] and sample_set.get("releaseSamples"), f"Incomplete key sample pair: {key}"
            for field, phase in (("samples", "press"), ("releaseSamples", "release")):
                phases += [(categories[key], phase, relative) for relative in sample_set[field]]
        # Enter and Numpad Enter refer to the same source recordings.
        phases = list(dict.fromkeys(phases))
        paths = [path for _, _, path in phases]
        assert len(paths) == len(set(paths)), f"A WAV is assigned to conflicting phases/categories: {profile['id']}"
        if record:
            assert releases and profile.get("normalizationReference") is False
            key_samples = profile.get("keySamples") or {}
            assert set(key_samples) == set(categories), \
                f"Imported pack must map Space, Return, Numpad Enter and Backspace: {profile['id']}"
            assert key_samples["7:40"] == key_samples["7:88"], \
                f"Imported Return and Numpad Enter must share their source bank: {profile['id']}"
            selections = {selection["path"]: selection for selection in record["selections"]}
            assert set(paths) == set(selections), f"Incomplete imported pack: {profile['id']}"
        # Silent and Office have naturally softer attacks. The other eight
        # profiles must have a substantial transient within the first millisecond.
        limit = 2 if profile["id"] in ("silent", "office") else 1
        for category, phase, relative in phases:
            assert relative.startswith(f"Sounds/{profile['id']}/") and ".." not in Path(relative).parts, relative
            is_creamy = profile["id"] == "creamy" and phase == "press"
            measured = inspect(assets / relative, single_impact=is_creamy, profile=None if record else profile["id"])
            row = {"profile": profile["id"], "category": category, "phase": phase, "path": relative,
                   "sourceKind": "thock-soundpack" if record else "recorded-excerpt", **measured}
            if record:
                selection = selections[relative]
                identity = selection.get("identification", {})
                field = "down" if phase == "press" else "up"
                sources = record["sourceSounds"][category][field]
                assert selection["phase"] == phase and selection["category"] == category, relative
                assert selection["sourceFile"] in sources, f"Wrong source phase: {relative}"
                pointer = f"sounds.{category}.{field}[{sources.index(selection['sourceFile'])}]"
                assert (identity.get("status") == "verified" and identity.get("method") == "source-config"
                        and identity.get("configPointer") == pointer and identity.get("evidence")), relative
                assert selection["sha256"] == hashlib.sha256((assets / relative).read_bytes()).hexdigest(), \
                    f"Imported sound hash mismatch: {relative}"
                # These are publisher-labelled isolated phases, not cuts from the
                # old continuous recording. Preserve their initial mechanism body;
                # its loudest peak need not occur in the first millisecond.
                assert measured["frames"] <= 48000, f"Unexpected long keyboard recording: {relative}"
                if measured["firstNonzeroMilliseconds"] > 8:
                    failures.append(f"{relative}: more than 8 ms digital leading silence")
                rows.append(row)
                continue
            # This source has a gradual initial body, not leading silence; keep
            # its natural beginning instead of cutting to meet a peak threshold.
            sample_limit = 4 if relative == "Sounds/office/02.wav" else limit
            if phase == "release":
                # Returning switches can have a softer top-out than their press.
                # Keep this an onset/contamination gate, not a loudness target.
                sample_limit = 4 if profile["id"] in ("silent", "office") else 2
            if measured["first20PercentPeakMilliseconds"] > sample_limit:
                failures.append(f"{relative}: attack exceeds {sample_limit} ms")
            if is_creamy and measured["creamyLateToPrimaryRMSRatio"] > 0.18:
                failures.append(f"{relative}: Creamy secondary impact ratio "
                                f"{measured['creamyLateToPrimaryRMSRatio']:.4f} exceeds 0.18 "
                                f"at {measured['creamyLaterPeakMilliseconds']:.1f} ms")
            for hit in measured["unexpectedSecondaryImpacts"]:
                failures.append(f"{relative}: renewed impact at {hit['milliseconds']:.1f} ms "
                                f"({hit['relativeRMS']:.3f} of initial impact)")
            if profile["id"] == "office" and measured["impactBandPeakMilliseconds"] > 12:
                failures.append(f"{relative}: main key texture delayed to "
                                f"{measured['impactBandPeakMilliseconds']:.1f} ms")
            if baseline and (baseline / relative).is_file():
                before = inspect(baseline / relative, single_impact=is_creamy)
                row["beforeFirst20PercentPeakMilliseconds"] = before["first20PercentPeakMilliseconds"]
                row["removedLeadingMilliseconds"] = round((before["frames"] - measured["frames"]) / 48, 6)
                if is_creamy:
                    row.update({"before" + key[0].upper() + key[1:]: value
                                for key, value in before.items() if key.startswith("creamy")})
            rows.append(row)
    effects = []
    for path in sorted((assets / "Sounds" / "Extras").glob("*.wav")):
        effects.append({"path": str(path.relative_to(assets)), **inspect(path),
                        "sourceKind": "Original procedural effect, verified by extraction reproducibility",
                        "intentionalReturnClickMilliseconds": 46 if path.stem == "typewriter" else None})
    silent = statistics.mean(r["rms"] for r in rows if r["profile"] == "silent" and r["phase"] == "press")
    others = statistics.mean(r["rms"] for r in rows if r["profile"] in legacy_ids - {"silent"} and r["phase"] == "press")
    assert silent < others * 0.5, "Silent must retain its quieter character"
    release_rows = [row for row in rows if row["phase"] == "release"]
    if release_rows:
        selections = {selection["path"]: selection for profile in provenance["profiles"]
                      for selection in profile.get("releaseSelections", [])}
        for row in (row for row in release_rows if row["sourceKind"] == "recorded-excerpt"):
            selection = selections.get(row["path"], {})
            identity = selection.get("identification", {})
            assert identity.get("status") == "verified" and identity.get("evidence") and "videoSeconds" in identity, \
                f"Missing release identification: {row['path']}"
            assert selection.get("sha256") == hashlib.sha256((assets / row["path"]).read_bytes()).hexdigest(), \
                f"Release hash mismatch: {row['path']}"
    report = {"metric": "First frame at 20% of sample peak; excludes render, hardware and Bluetooth latency",
              "creamySingleImpactMetric": {
                  "highPassHz": 250, "filter": "One-pole RC high-pass, analysis only",
                  "rmsWindowMilliseconds": 1, "hopMilliseconds": 0.5,
                  "primaryWindowStartRangeMilliseconds": [0, 6],
                  "laterWindowStartMinimumMilliseconds": 8, "maximumLateToPrimaryRMSRatio": 0.18,
              },
              "impactReview": "Original excerpts use profile-aware renewed-attack gates. Catalog stems use publisher phase mapping, hashes, format, boundaries and headroom checks; not a substitute for listening.",
              "profileCount": len(profiles),
              "catalogSampleCount": sum(row["sourceKind"] == "thock-soundpack" for row in rows),
              "sampleCount": len(rows), "pressSampleCount": len(rows) - len(release_rows),
              "releaseSampleCount": len(release_rows),
              "releaseSupportedProfiles": [p["id"] for p in profiles if p.get("releaseSamples")],
              "failures": failures, "samples": rows, "originalEffects": effects}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=Path(__file__).resolve().parents[1] / "Assets")
    parser.add_argument("--baseline", type=Path, help="Optional earlier asset directory for comparison")
    parser.add_argument("--output", type=Path, help="Optional JSON measurement report")
    args = parser.parse_args()
    report = check_assets(args.assets, args.baseline)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    if report["failures"]:
        raise SystemExit("\n".join(report["failures"]))
    print(f"Passed: {report['pressSampleCount']} presses, {report['releaseSampleCount']} verified releases, "
          f"source-specific checks, WAV boundaries/headroom, Silent level, and {len(report['originalEffects'])} original effects.")
    if args.baseline:
        trimmed = [r["removedLeadingMilliseconds"] for r in report["samples"] if r.get("removedLeadingMilliseconds", 0) > 0]
        print(f"Tightened {len(trimmed)} starts; median removed {statistics.median(trimmed) if trimmed else 0:.2f} ms.")


if __name__ == "__main__":
    main()
