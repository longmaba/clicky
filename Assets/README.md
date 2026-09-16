# Clicky sound assets

`profiles.json` is the runtime array of twenty `SoundProfileManifest` values.
All keyboard WAVs are mono, 48 kHz, PCM16. Paths are relative to this folder.
The app and website use the same files. Generic phases use `samples` and optional
`releaseSamples`; optional `keySamples` maps HID IDs to a separate pair of banks.
Enter (`7:40`) and keypad Enter (`7:88`) share recordings and decoded buffers.

Recorded releases use a fixed 0.7 gain multiplier at playback in the app and
website, including previews. The source WAVs retain their original phase
balance. Auditions use the same multiplier by default; `--release-gain 1`
restores the recorded balance for source review. Custom imports are unaffected.

## Original ten profiles

Each original bank has six press variants. These banks follow the ten sections
of the user-provided companion audio file for
video `Gzko0BoULdw`. The MP4 is video-only; extraction uses the `.f251.webm` file.

The recordings are short stroke excerpts, sometimes including their natural
release and room tail. Optional `releaseSamples` contains separately verified
key-up recordings; it remains null for the original ten banks. The source review
in `release-review.json` did not establish a clean, independently identifiable
release. See [the review findings](../docs/verification/release-source-review.md).
Silent retains its lower recorded level.
No peak normalization, compression, noise gate, or tone EQ is baked into banks.
The common gain is applied to float PCM before converting to PCM16, preserving
Opus transients that exceed unity during decoding. Excerpts have DC removal and
short cosine edge fades. Cuts align to the first audible attack with at most
0.5 ms of pre-roll; naturally immediate soft attacks retain their original starts.
Detailed timestamps, processing, source hash, output
hashes, and level measurements are in `extraction.json`.

## Ten paired packs

The additional packs by **tplai (Thomas Lai)** are Alps SKCM Blue, Drop Holy Panda,
Durock Alpaca, Gateron Ink Black, Gateron Ink Red, Gateron Turquoise Tealios,
Kailh Box Navy, NovelKeys Cream, Topre Unknown, and IBM Buckling Spring.

Their pinned [thock-soundpacks catalog](https://github.com/kamillobinski/thock-soundpacks/tree/213e1443c5005a99d5e51b46e31e17f30e4d752a)
configs explicitly identify `down` and `up` recordings for generic keys, Space,
Enter, and Backspace. Each pack has five generic presses and at least one
generic release; Alps has two releases. Each special category adds one press
and one release. This adds **121 WAVs: 80 presses and 41 releases**.

`thock-sources.json` locks the registry commit, archives, configs, source WAV
hashes, processing parameters, and unchanged original files. `thock-import.json`
records the publisher phase/category pointers, license metadata, source/output
hashes, and measured processing for every imported recording. Phase identity
comes from the publisher's config; it is not inferred from waveform peaks.

Importing resamples to 48 kHz float PCM, applies one common gain of 0.4, trims
only exact-zero leading source frames while retaining 0.5 ms of pre-roll, and
applies 0.4 ms/4 ms cosine boundary fades before PCM16 encoding. There is no EQ,
compression, or peak normalization. Quieter mechanical lead-ins remain intact.
The native normalization option uses the selected press's correction for both
phases and retains the original profiles' reference level. Independent phase
variants are selected within the same profile/category and saved at press time.

The complete [MIT notice](Licenses/kbsim-MIT.txt) is included in the app and
staged for the website. See [third-party notices](../THIRD_PARTY_NOTICES.md).

## Recorded mouse pack

`mouse-profiles.json` separately lists **Razer Orochi V2**, recorded by Sadiquecat
and declared CC0 by its publisher. Four WAVs provide distinct left/right down/up
sounds. `keySamples` maps `9:1` to left and `9:2` to right; the generic left pair
also serves middle button `9:3`, which has no separate source recording.

`thock-mouse-sources.json` pins the source and records excluded catalog packs.
`thock-mouse-import.json` records phase evidence, processing, and source/output
hashes. Stereo sources are averaged to mono before 48 kHz resampling. The same
gain of 0.4 and short fades apply to all four phases; only exact-zero leading
frames are trimmed. The previous 186 WAVs and keyboard catalog remain unchanged.
The [CC0/source notice](Licenses/Sadiquecat-CC0.txt) accompanies both app and site.

## Rebuilding and auditioning

`Sounds/Extras` contains five original, deterministic procedural sounds: Soft,
Crisp, Hard, Ding, and Typewriter. They use damped oscillators and seeded noise;
they are not extracted from the source video.

Rebuild with Python's standard library and FFmpeg:

```sh
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/import_thock_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/import_thock_mouse_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/check_sound_assets.py
python3 scripts/check_mouse_sound_assets.py
python3 scripts/audition_sounds.py --output /tmp/clicky-audition.wav
python3 scripts/audition_sounds.py --profile novelkeys-cream --category all --phase pair --hold 0.03 --hold 0.1 --hold 0.3
python3 scripts/audition_sounds.py --category all --phase release
python3 scripts/audition_sounds.py --mouse --category all --hold 0.03 --hold 0.1 --hold 0.3
```

Each importer preserves the other catalog entries. The paired importer downloads
only the pinned archives into a temporary source cache; `--offline --check`
rebuilds from that verified cache without network access. Source archives and
audition files are not bundled. Both reproducibility checks are required when
regenerating keyboard sounds; run the separate mouse importer check for its pack.

`release-review.json` is the extraction input for authentic release cuts. Each
verified profile must identify its source video movement and audio interval;
source hashes bind that evidence to the supplied files. Unverified/unavailable
profiles contribute no release samples. A profile needs only one verified release,
with more variants optional. The app and website play available releases on
actual key-up; previews use a 100 ms hold. Pair auditions mix releases at the
requested hold time, allowing the press tail to overlap naturally. A release-only
audition skips press-only banks and reports absence if none of the selected
profiles provides releases. `--category all` includes each special-key category
once; `--interval` and `--voices` exercise overlapping typing.

The 0.1.4 review inspected all 60 recorded variants and checked their boundaries
and secondary impacts. The maintainer's listening check confirmed clean single
hits in Creamy and their other favorite profiles after the cleanup; this is not
a claim that every variant was individually auditioned by a person. See
`docs/TESTING.md` for the recorded checks. The audition script emits a WAV and a
timestamped JSON index outside the bundle; `--play` plays it locally.

The original ten banks are redistributed with permission confirmed by the
maintainer. Their original rights are retained, separately from the MIT license
for Clicky's original code and generated assets. See `THIRD_PARTY_NOTICES.md`.
