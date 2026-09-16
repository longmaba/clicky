# Key-release source review — 2026-09-15

**Result: zero verified release cuts; no sound-bank rollout.** The app, website,
and tooling support optional releases, but the ten production profiles remain
press-only. Existing press WAVs were not reclassified or replaced.

## What was inspected

The supplied `Gzko0BoULdw` companion audio is approximately 55.083 seconds long.
The companion video is 1920 × 1080 at 60000/1001 frames per second. File names
and SHA-256 hashes are recorded in [the extraction review](../../Assets/release-review.json).

The review used the full-source mono 48 kHz float audio envelope, a source video
overview, frame sequences near the end of each profile, and five additional
detail windows with 1 ms audio RMS envelopes. Detailed sheets use every other
decoded video frame (29.97 frames per second). Frame time is derived from the
original frame index, not rounded thumbnail labels.

This was a targeted visual and waveform review, not exhaustive classification
of every movement. No human listening assessment was performed. The source has
no physical input timestamps or isolated per-key stems. A secondary waveform
peak was never treated as proof of key-up.

## Findings by profile

Times below are seconds in the supplied source. All rows remain unavailable for
extraction: this means no eligible cut was established in this review, not that
the source has been proven to contain no releases.

| Profile | Detailed windows | Why a release was not approved |
| --- | --- | --- |
| Thocky | 5.373–6.043 | Angled view and alternating finger movements; smaller sounds cannot be uniquely assigned to release. |
| Marbly | 6.350–6.750; 11.379–12.049 | Fingertips obscure travel, with overlapping activity and broad sound bodies between major attacks. |
| Silent | 15.700–16.370 | Quiet, broad sound bodies and continuous motion; no isolated release demonstration. |
| Poppy | 20.855–21.525 | Both hands remain active; candidate small transients coincide with multiple movements. |
| Clicky | 26.000–26.370; 26.360–27.030 | Sharp clicks occur close together; release, neighboring press, and mechanism texture remain ambiguous. |
| Bubble Wrap | 31.766–32.436 | Curled fingers hide travel; no single visible release has a clean independent transient. |
| Clacky | 33.720–34.030; 37.505–38.175 | Smaller inter-attack events lack an unambiguous corresponding finger lift. |
| Creamy | 44.130–44.500; 43.928–44.598 | Dark keys and overlapping movements obscure attribution of the quieter sounds. |
| Deep Thock | 45.200–45.600; 49.116–49.786 | Distant view and overlapping low-level sound make individual release travel difficult to resolve. |
| Office | 54.355–55.025 | Curled fingers stay over the keys through the final frames; quieter sounds lack isolated visual attribution. |

No synthetic cues, unrelated recordings, press trims, or release WAVs were added.
The machine-readable review records empty release selections for every profile.
It can be amended when a reviewer can establish a specific authentic cut.

## Recording needed to finish the feature

For each profile, record one key press, hold it for at least 0.5 seconds, release
it, then leave at least 0.5 seconds of quiet before the next stroke. Keep other
keys still and key travel visible. Several repetitions provide useful variation;
one clean release is enough to enable a profile. Preserve original levels and
permission to redistribute the recordings in the app and website.

When a release is verified, enter its exact audio interval, attack time, video
time, and identification evidence in `Assets/release-review.json`; regenerate
the banks and run the asset and playback checks. Only verified profiles gain
key-up playback. Partial rollout is supported.
