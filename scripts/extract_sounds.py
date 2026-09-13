#!/usr/bin/env python3
"""Rebuild Clicky's recorded banks and original effects using stdlib + FFmpeg.

Example:
  python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg
  python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg --check

Decode to FLOAT before adding headroom: Opus transients can exceed 0 dBFS, so
decoding through an intermediate PCM16 WAV irreversibly clips these recordings.
The selected intervals are short recorded stroke excerpts, not isolated down/up
recordings. Their original relative levels, including Silent, are preserved.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import io
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import wave

SAMPLE_RATE = 48_000
SOURCE_GAIN = 0.32
FADE_IN_SECONDS = 0.0004
FADE_OUT_SECONDS = 0.008
ATTACK_PREROLL_FRAMES = 24  # 0.5 ms: edge fade and render safety ramp finish before impact.
PROJECT = Path(__file__).resolve().parents[1]

# Explicit, source-relative seconds selected by inspecting transient envelopes.
# Each interval ends before the next distinct neighboring major attack.
PROFILES = [
    ("thocky", "Thocky", "Warm, rounded knocks", "C68B54", 0.000, 6.073,
     [(5.899, 6.015), (1.354, 1.474), (4.506, 4.622), (2.905, 3.021), (5.722, 5.838), (5.548, 5.667)]),
    ("marbly", "Marbly", "Smooth, glassy resonance", "AD9ACE", 6.073, 12.079,
     [(6.471, 6.583), (10.445, 10.562), (7.073, 7.197), (11.863, 11.979), (7.959, 8.071), (11.509, 11.632)]),
    ("silent", "Silent", "A soft, quiet touch", "94A7AD", 12.079, 16.400,
     [(12.559, 12.651), (12.747, 12.836), (13.374, 13.440), (14.374, 14.462), (14.655, 14.715), (14.791, 14.873)]),
    ("poppy", "Poppy", "Bright little pops", "E8A05B", 16.400, 21.555,
     [(17.605, 17.711), (17.755, 17.861), (18.729, 18.829), (19.179, 19.270), (20.219, 20.315), (18.955, 19.060)]),
    ("clicky", "Clicky", "Crisp, tactile clicks", "D3BB6F", 21.555, 27.060,
     [(21.934, 21.987), (22.665, 22.722), (23.094, 23.166), (26.131, 26.236), (24.749, 24.814), (26.243, 26.311)]),
    ("bubble-wrap", "Bubble Wrap", "Playful, hollow pops", "C493B5", 27.060, 32.466,
     [(27.114, 27.200), (28.379, 28.485), (28.822, 28.928), (30.143, 30.237), (30.254, 30.338), (32.103, 32.209)]),
    ("clacky", "Clacky", "Sharp, lively taps", "DA8276", 32.466, 38.205,
     [(32.554, 32.662), (32.708, 32.813), (34.773, 34.863), (33.799, 33.905), (36.474, 36.561), (36.590, 36.677)]),
    ("creamy", "Creamy", "Soft, buttery texture", "DCCCA0", 38.205, 44.628,
     [(38.383, 38.475), (40.450, 40.548), (42.190, 42.289), (41.178, 41.269), (44.294, 44.393), (43.868, 43.990)]),
    ("deep-thock", "Deep Thock", "Low, resonant knocks", "82A799", 44.628, 49.816,
     [(48.658, 48.774), (45.762, 45.905), (46.914, 47.045), (47.289, 47.400), (47.659, 47.829), (49.574, 49.710)]),
    ("office", "Office", "Familiar everyday typing", "7FA1C3", 49.816, 55.055,
     [(49.889, 49.985), (53.288, 53.382), (52.118, 52.177), (52.854, 52.928), (52.353, 52.442), (54.613, 54.711)]),
]


# First audible attack, in frames relative to each original selection above.
# Reviewed against the unfaded source and a 250 Hz high-pass detector (analysis
# only). Original cuts retained ~6 ms of room sound before most attacks. Keeping
# only 0.5 ms before impact makes the audible hit coincide with the key event.
# Zero preserves variants already containing an immediate, naturally soft attack.
# Align the short, continuous Clicky 05/06 attack clusters to their beginning,
# retaining their texture. The 0.1.4 full-bank waveform review replaces excerpts
# with clearly separated extra impacts and removes four contaminated late tails.
# Silent retains its naturally rounded attack/body and lower recorded level.
# Office reselections retain their broad body while starting on the key texture.
ATTACK_FRAMES = {
    "thocky": [313, 308, 312, 323, 311, 302],
    "marbly": [325, 335, 326, 310, 283, 291],
    "silent": [0, 0, 409, 0, 370, 510],
    "poppy": [305, 293, 257, 234, 278, 283],
    "clicky": [314, 262, 316, 283, 62, 51],
    "bubble-wrap": [309, 304, 289, 257, 239, 297],
    "clacky": [312, 283, 304, 297, 296, 302],
    "creamy": [312, 293, 305, 302, 313, 327],
    "deep-thock": [325, 278, 292, 335, 353, 323],
    "office": [158, 197, 176, 283, 179, 249],
}

RESELECTED_VARIANTS = {
    "thocky": [1, 3, 4, 5], "marbly": [2, 4], "silent": [],
    "poppy": [1, 2, 6], "clicky": [1, 3, 4], "bubble-wrap": [1, 2, 3, 6],
    "clacky": [2, 4], "creamy": [1, 2, 3, 5], "deep-thock": [1], "office": [1, 2, 5],
}
TRIMMED_TAIL_VARIANTS = {"bubble-wrap": [5], "deep-thock": [3, 4, 6]}


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def db(value):
    return round(20 * math.log10(value), 4) if value > 0 else None


def metrics(samples):
    peak = max(abs(v) for v in samples)
    rms = math.sqrt(sum(v * v for v in samples) / len(samples))
    return {"frames": len(samples), "durationSeconds": round(len(samples) / SAMPLE_RATE, 6),
            "peak": round(peak, 7), "peakDbFS": db(peak), "rms": round(rms, 7),
            "rmsDbFS": db(rms)}


def fades(samples, fade_in=FADE_IN_SECONDS, fade_out=FADE_OUT_SECONDS):
    result = list(samples)
    incoming = max(2, min(len(result), round(fade_in * SAMPLE_RATE)))
    outgoing = max(2, min(len(result), round(fade_out * SAMPLE_RATE)))
    for index in range(incoming):
        result[index] *= 0.5 - 0.5 * math.cos(math.pi * index / (incoming - 1))
    for index in range(outgoing):
        result[-outgoing + index] *= 0.5 + 0.5 * math.cos(math.pi * index / (outgoing - 1))
    result[0] = result[-1] = 0.0
    return result


def wav_bytes(samples):
    if not samples or not all(math.isfinite(v) and abs(v) < 1 for v in samples):
        raise ValueError("Invalid or clipping samples")
    pcm = array.array("h", (round(v * 32767) for v in samples))
    if sys.byteorder != "little":
        pcm.byteswap()
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(SAMPLE_RATE)
        writer.writeframes(pcm.tobytes())
    return output.getvalue()


def decode(source, ffmpeg):
    command = [str(ffmpeg), "-v", "error", "-i", str(source), "-map", "0:a:0",
               "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"]
    result = subprocess.run(command, check=True, capture_output=True)
    samples = array.array("f", result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples or not all(math.isfinite(v) for v in samples):
        raise ValueError("FFmpeg returned empty or non-finite PCM")
    return samples


def noise_stream(seed):
    """Fixed LCG: deterministic noise, independent of Python's random version."""
    while True:
        seed = (1664525 * seed + 1013904223) & 0xFFFFFFFF
        yield seed / 2147483648.0 - 1.0


def original_effect(name):
    duration = {"soft": 0.080, "crisp": 0.065, "hard": 0.115, "ding": 0.650, "typewriter": 0.180}[name]
    seed = {"soft": 103, "crisp": 211, "hard": 307, "ding": 401, "typewriter": 503}[name]
    noise = noise_stream(seed)
    samples = []
    low = previous = 0.0
    for index in range(round(duration * SAMPLE_RATE)):
        t = index / SAMPLE_RATE
        white = next(noise)
        low += 0.18 * (white - low)
        high = white - previous
        previous = white
        if name == "soft":
            value = (0.72 * math.sin(2 * math.pi * 235 * t) + 0.4 * low) * math.exp(-t / 0.013)
        elif name == "crisp":
            value = 0.47 * high * math.exp(-t / 0.005) + 0.45 * math.sin(2 * math.pi * 1250 * t) * math.exp(-t / 0.009)
        elif name == "hard":
            value = 0.43 * high * math.exp(-t / 0.007)
            value += (0.65 * math.sin(2 * math.pi * 410 * t) + 0.21 * math.sin(2 * math.pi * 1130 * t)) * math.exp(-t / 0.019)
        elif name == "ding":
            value = sum(amplitude * math.sin(2 * math.pi * frequency * t) * math.exp(-t / decay)
                        for amplitude, frequency, decay in [(0.72, 1174.66, 0.16), (0.25, 2349.32, 0.095), (0.1, 3135.96, 0.055)])
        else:
            value = (0.45 * high + 0.45 * math.sin(2 * math.pi * 720 * t)) * math.exp(-t / 0.009)
            value += 0.26 * math.sin(2 * math.pi * 2260 * t) * math.exp(-t / 0.035)
            if t >= 0.046:
                rt = t - 0.046
                value += 0.22 * (high + math.sin(2 * math.pi * 940 * rt)) * math.exp(-rt / 0.009)
        samples.append(value)
    samples = fades(samples, fade_in=0.0007, fade_out=0.012)
    peak = max(abs(v) for v in samples)
    target = 0.36 if name == "ding" else 0.42
    return [v / peak * target for v in samples]


def build(source, ffmpeg):
    decoded = decode(source, ffmpeg)
    source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
    files = {}
    manifests = []
    records = []
    for identifier, name, subtitle, color, section_start, section_end, selections in PROFILES:
        section = decoded[round(section_start * SAMPLE_RATE):round(section_end * SAMPLE_RATE)]
        manifest = {"id": identifier, "name": name, "subtitle": subtitle, "color": color,
                    "samples": [], "releaseSamples": None, "gain": 1.0,
                    "provenance": {"source": source.name, "sectionStart": section_start, "sectionEnd": section_end}}
        record = {"id": identifier, "sectionStart": section_start, "sectionEnd": section_end,
                  "sourceSectionMetrics": metrics(section), "selections": []}
        record["selectionReview"] = {
            "revision": "0.1.4", "auditedVariants": [f"{i:02d}" for i in range(1, 7)],
            "reselectedVariants": [f"{i:02d}" for i in RESELECTED_VARIANTS[identifier]],
            "trimmedTailVariants": [f"{i:02d}" for i in TRIMMED_TAIL_VARIANTS.get(identifier, [])],
            "method": "Source waveform and transient-envelope review; analysis filters are not applied to assets. Reselections preserve a full isolated impact and decay; tail trims end before an unrelated late tap.",
            "regressionCheck": "scripts/check_sound_assets.py: profile-aware sharp renewed-attack detection, onset, edges, headroom, and Silent level. Rounded Silent/Office bodies use an upper-texture-band check; Creamy also has a strict late/initial amplitude gate.",
            "listeningReview": "Pending user audition of the updated 0.1.4 sound bank."}
        if identifier == "silent":
            record["selectionReview"]["retainedCharacter"] = "All six original excerpts retained: rounded quiet bodies, without a distinct sharp second strike."
        elif identifier == "clicky":
            record["selectionReview"]["retainedCharacter"] = "Variants 05/06 retain their short continuous initial mechanism cluster; separated later impacts are rejected."
        elif identifier == "office":
            record["selectionReview"]["retainedCharacter"] = "Broad membrane-key body retained; 01/02/05 reselected to bring key texture into the initial attack."
        for index, (start, end) in enumerate(selections, 1):
            if not section_start <= start < end <= section_end:
                raise ValueError(f"Selection outside {identifier} source section")
            selection_start = round(start * SAMPLE_RATE)
            attack = ATTACK_FRAMES[identifier][index - 1]
            trimmed_frames = max(0, attack - ATTACK_PREROLL_FRAMES)
            start_frame = selection_start + trimmed_frames
            end_frame = round(end * SAMPLE_RATE)
            raw = decoded[start_frame:end_frame]
            if len(raw) != end_frame - start_frame or len(raw) <= attack:
                raise ValueError(f"Incomplete source for {identifier}")
            # Subtract the tiny excerpt DC offset, without gating/EQ/normalization.
            dc = sum(raw) / len(raw)
            rendered = fades((v - dc) * SOURCE_GAIN for v in raw)
            path = f"Sounds/{identifier}/{index:02d}.wav"
            payload = wav_bytes(rendered)
            files[path] = payload
            manifest["samples"].append(path)
            record["selections"].append({"path": path,
                "selectionStartSeconds": start, "startSeconds": round(start_frame / SAMPLE_RATE, 9), "endSeconds": end,
                "startFrame": start_frame, "endFrameExclusive": end_frame,
                "attackAlignment": {"sourceAttackFrame": selection_start + attack,
                    "removedLeadingFrames": trimmed_frames,
                    "removedLeadingMilliseconds": round(trimmed_frames * 1000 / SAMPLE_RATE, 6),
                    "outputAttackFrame": attack - trimmed_frames},
                "sourceMetrics": metrics(raw), "removedDCOffset": round(dc, 9),
                "outputMetrics": metrics(rendered), "sha256": hashlib.sha256(payload).hexdigest()})
        manifests.append(manifest)
        records.append(record)
    effects = []
    for name in ("soft", "crisp", "hard", "ding", "typewriter"):
        rendered = original_effect(name)
        path = f"Sounds/Extras/{name}.wav"
        payload = wav_bytes(rendered)
        files[path] = payload
        effects.append({"id": name, "path": path, "source": "Original Clicky procedural synthesis, version 1",
                        "metrics": metrics(rendered), "sha256": hashlib.sha256(payload).hexdigest()})
    report = {"schemaVersion": 1, "source": {"file": source.name, "sha256": source_digest,
        "videoTitle": "Thock vs Creamy vs Marbly vs Clack | Best Sound Profile? Ultimate Keyboard Sound Test",
        "videoID": "Gzko0BoULdw", "durationSeconds": round(len(decoded) / SAMPLE_RATE, 6),
        "decodedPeak": round(max(abs(v) for v in decoded), 7)},
        "processing": {"decode": "FFmpeg: first audio stream -> mono 48000 Hz float32 little-endian PCM",
            "encode": "mono 48000 Hz signed 16-bit little-endian PCM WAV",
            "commonGain": SOURCE_GAIN, "commonGainDb": db(SOURCE_GAIN), "removeExcerptDC": True,
            "fadeInSeconds": FADE_IN_SECONDS, "fadeOutSeconds": FADE_OUT_SECONDS, "fadeCurve": "half cosine",
            "attackAlignment": "Frame-reviewed first impact with at most 0.5 ms pre-roll; naturally immediate attacks retained",
            "attackPrerollFrames": ATTACK_PREROLL_FRAMES,
            "peakNormalization": False, "compression": False, "noiseGate": False,
            "note": "Common gain preserves source profile differences and Silent's lower volume. Float decoding avoids clipping Opus peaks before attenuation."},
        "review": {"waveformReview": "Selected intervals inspected against source transient envelopes; boundaries avoid the next distinct major attack.",
            "listeningReview": "Pending human audition. Audio input was unavailable in the authoring tool session.",
            "sampleSemantics": "Recorded stroke excerpts; may include the natural release/room tail. Not independently recorded key-down/key-up samples.",
            "sourceLimitations": "Continuous typing recording: subtle overlapping room sound or neighboring release tails may remain. No isolated original key stems are available."},
        "profiles": records, "originalEffects": effects}
    files["profiles.json"] = json_bytes(manifests)
    files["extraction.json"] = json_bytes(report)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, help="Companion .f251.webm (defaults to the project file)")
    parser.add_argument("--ffmpeg", type=Path, default=shutil.which("ffmpeg"), help="FFmpeg executable path")
    parser.add_argument("--output", type=Path, default=PROJECT / "Assets")
    parser.add_argument("--check", action="store_true", help="Rebuild in memory and compare; do not write")
    arguments = parser.parse_args()
    if not arguments.ffmpeg:
        parser.error("FFmpeg not on PATH; supply --ffmpeg /path/to/ffmpeg")
    matches = sorted(PROJECT.glob("*.f251.webm"))
    source = arguments.source or (matches[0] if len(matches) == 1 else None)
    if source is None or not source.is_file():
        parser.error("Source audio not found; supply --source /path/to/audio.webm")
    files = build(source, arguments.ffmpeg)
    for relative, content in files.items():
        target = arguments.output / relative
        if arguments.check:
            if not target.is_file() or target.read_bytes() != content:
                raise SystemExit(f"Reproducibility check failed: {target}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
    action = "Verified" if arguments.check else "Wrote"
    print(f"{action} 10 profiles × 6 recorded variants, 5 original effects, and 2 manifests.")
    print(f"Total output: {sum(len(data) for data in files.values()):,} bytes. Listening review remains pending.")


if __name__ == "__main__":
    main()
