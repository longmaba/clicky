# Clicky sound assets

`profiles.json` is the runtime array of ten `SoundProfileManifest` values. Each
bank has six mono, 48 kHz, PCM16 WAV variants. Paths are relative to this folder.
The banks follow the ten sections of the user-provided companion audio file for
video `Gzko0BoULdw`. The MP4 is video-only; extraction uses the `.f251.webm` file.

The recordings are short stroke excerpts, sometimes including their natural
release and room tail. They are not independent press/release recordings, so
`releaseSamples` is deliberately null. Silent retains its lower recorded level.
No peak normalization, compression, noise gate, or tone EQ is baked into banks.
The common gain is applied to float PCM before converting to PCM16, preserving
Opus transients that exceed unity during decoding. Excerpts have DC removal and
short cosine edge fades. Cuts align to the first audible attack with at most
0.5 ms of pre-roll; naturally immediate soft attacks retain their original starts.
Detailed timestamps, processing, source hash, output
hashes, and level measurements are in `extraction.json`.

`Sounds/Extras` contains five original, deterministic procedural sounds: Soft,
Crisp, Hard, Ding, and Typewriter. They use damped oscillators and seeded noise;
they are not extracted from the source video.

Rebuild with Python's standard library and FFmpeg:

```sh
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/check_sound_assets.py
python3 scripts/audition_sounds.py --output /tmp/clicky-audition.wav
```

The 0.1.4 review inspected all 60 recorded variants and checked their boundaries
and secondary impacts. The maintainer's listening check confirmed clean single
hits in Creamy and their other favorite profiles after the cleanup; this is not
a claim that every variant was individually auditioned by a person. See
`docs/TESTING.md` for the recorded checks. The audition script emits a WAV and a
timestamped JSON index outside the bundle; `--play` plays it locally.

The recorded banks are redistributed with permission confirmed by the
maintainer. Their original rights are retained, separately from the MIT license
for Clicky's original code and generated assets. See `THIRD_PARTY_NOTICES.md`.
