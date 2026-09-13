# Clicky verification

## Local build verification

On 2026-09-13, the Release SwiftPM build completed and produced
`dist/Clicky.app` on the development Mac. The package test run reported 17 passing
tests. The exported app passed `codesign --verify --deep --strict`; its signature
is ad-hoc with hardened runtime, identifier `dev.clicky.app`, architecture arm64.
`vtool` confirmed a macOS 13.0 deployment target.

Bundle inspection confirmed ten manifests, all 60 referenced recorded WAVs, five
extra effects, the icon and intact SwiftPM resources. No source MP4/WebM is bundled.
The initial app occupies approximately 6.2 MB. Both Info.plist and the generated
Xcode project passed plist syntax validation, and its shared scheme XML parsed.
Xcode compilation could not be exercised because this installation's xcodebuild
requires a missing CoreSimulator framework; the default build uses SwiftPM.

These checks establish packaging and compilation, not physical-input, audible
latency, supported-headphone or minimum-OS runtime behavior.

## Recorded asset checks

The initial exported bank passed the following checks:

- Ten manifests, each with six WAV variants; all paths exist and release samples
  are null for the continuous-typing excerpts.
- All 65 WAVs are mono, 48 kHz, PCM16 and have zero-valued first/last frames.
- Peak magnitude is at most 0.469 (approximately −6.58 dBFS); no exported clipping.
- Recorded variants are 57–170 ms; original effects are 65–650 ms.
- Total WAV duration is 7.151 seconds. Silent's mean variant RMS is −37.23 dBFS.
- A second extraction with the same FFmpeg binary reproduced all output bytes.
- Source transient envelopes and exported waveforms were visually inspected.

**Human listening QA is pending.** Audio input was unavailable to the authoring
session. Listen to `/tmp/clicky-audition.wav`, or regenerate it with
`python3 scripts/audition_sounds.py --play`. Its adjacent JSON file identifies each
sample and start time. Check for neighboring hits, cut tails, excessive room noise,
and perceived differences between all ten banks. The source is continuous typing,
so isolated original key stems are unavailable.

## Automated commands

```sh
swift test --package-path Packages/ClickyCore
swift build
bash scripts/build.sh
codesign --verify --deep --strict dist/Clicky.app
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/check_sound_assets.py
open -n "$PWD/dist/Clicky.app" --args --diagnostics /tmp/Clicky-QA
open -n "$PWD/dist/Clicky.app" --args --audio-diagnostics /tmp/Clicky-Audio-QA
open -n "$PWD/dist/Clicky.app" --args --notch-diagnostics /tmp/Clicky-Notch-QA
```

The build script uses SwiftPM by default and verifies the generated signature;
`--xcode` selects xcodebuild when its required Xcode components are installed.
Diagnostic mode saves UI snapshots plus a resource/audio/status report and exits;
it does not exercise hardware input or request permission. These commands are
instructions, not a claim that every check or platform configuration has been run.
Tests live in the local ClickyCore package; the Xcode app scheme does not duplicate them.
The `--audio-diagnostics` variant skips UI snapshots and runs only the audio checks.
The `--notch-diagnostics` variant replays native mouse events through the inactive
notch panel and saves a focused interaction report and RealityKit snapshots. It
uses temporary configuration and zero-volume previews, without global input
injection. It does not substitute for a physical first-drag check.

## Manual acceptance matrix

All rows below require a human/hardware session and are **pending** unless a result
is recorded explicitly with device, macOS version, and date.

| Area | Exercise | Expected behavior |
| --- | --- | --- |
| First launch | Fresh app identity, deny Input Monitoring, preview sounds | Clear permission state; local previews work; global input remains inactive. |
| Permission recovery | Grant, relaunch if requested, revoke while running | Global response starts/stops correctly; held-key visuals clear. |
| Basic typing | Internal keyboard, USB keyboard, Bluetooth keyboard; rapid chords | One press sound per physical key; no stuck highlights or duplicate captures. |
| Vietnamese Telex | Built-in Vietnamese Telex and the user's chosen IME | Composition-generated backspaces/replacements do not add keyboard sounds. |
| Remapping | Virtual HID/remapper enabled alongside a physical keyboard | No duplicate sounds from duplicate device streams; document unsupported setups. |
| Modifiers | Left/right Shift, Option, Command, Control, Caps Lock, Fn | Correct transitions and shortcut behavior; ordinary function keys do not masquerade as Fn. |
| Media/mouse | F-key/media modes, volume/mute/playback, supported mouse buttons | Sound on exposed physical controls; OS action is not intercepted. |
| Repeat | Hold a key; then release, type on two devices | No artificial repeating sound for a held physical key; state clears per device. |
| Secure input | Password field; Terminal Secure Keyboard Entry | Feedback pauses and recovers; no attempt to bypass secure input. |
| Shortcut | Default Command + three K taps; record a replacement | Toggles once within interval; ordinary typing and mismatches do not toggle. |
| Profiles | Preview/play every bank at the same volume | Ten distinct source profiles; Silent remains quiet; no clipping or abrupt boundaries. |
| Controls | Tone, pitch, width, normalization, variation, home-row softness | Audible intended effect; smooth changes during fast typing without pops. |
| Overrides/favorites | Override several keys; save/apply/delete favorites; restart | Per-key values and favorite settings survive and restore correctly. |
| Imports | WAV/AIFF/MP3/M4A; press then optional release; invalid/empty/>15s file | Accepted files copy into app support; rejected files show a useful message; no crash. |
| Output | Switch speakers/headphones/output device; disconnect selected output | Stream recovers or exposes a clear status; no stale device crash. |
| Headphones | Pause-on-headphones toggle; macOS 14+ motion-capable headphones | Pause policy follows selected output; head tracking requires availability/consent. |
| Main window | Open/close repeatedly; change Dock visibility | Closing settings preserves background audio; reopening works through menu bar. |
| Overlays | Every style/theme, scale, offset, placement and dismiss option | Correct key feedback; no focus stealing; clicks pass through the running overlay. |
| Notch | Built-in notched display and an external display | 3D view stays within chosen screen geometry; hidden view stops unnecessary rendering. |
| Spaces/fullscreen | Ordinary Spaces, another app fullscreen, Stage Manager | Show/hide policy honored; no unwanted app activation or obstructed controls. |
| Multiple screens | Mixed DPI, negative-coordinate arrangement, hot-unplug | Overlay repositions/clamps safely; stale screen selection recovers. |
| Sleep/wake | Sleep with keys down; wake after device/output changes | Held state clears; input/audio recover without doubled listeners. |
| Persistence | Restart; malformed or newer-version configuration | Valid settings persist; invalid settings produce clear fallback/backup behavior. |
| Login item | Enable, log out/in, disable | Setting matches system registration and starts only when enabled. |
| Quit/rebuild | Quit menu item, rebuild and reopen same bundle path | Process/audio end on Quit; permission recovery remains understandable. |
| Performance | Sustained fast typing, 96-voice stress, app hidden, Instruments | No render-thread allocations/locks, glitches, unbounded memory, or excessive idle rendering. |
| Latency | Wired output vs Bluetooth, app busy vs idle | Measure onset latency; report hardware-dependent results instead of a universal claim. |

For a completed run, append actual observations, hardware and OS details below.
Do not mark a scenario passed only because the app compiled or a UI control exists.

## Recorded implementation run — 2026-09-13

On this Apple Silicon Mac, macOS 26.6.2 (25G83), with Swift 6.3.3:

- All **21 tests passed** in the ClickyCore package, including an AddressSanitizer run.
  Coverage includes overlapping voices, bounded queue overflow, sample ownership,
  paired releases across devices/configuration changes, independent category volumes,
  headphone panning, normalization, physical transitions, shortcuts, and persistence.
- The Release `.app` launched successfully with all ten banks and all 60 recorded
  samples present; the native output engine reported ready.
- A timed software replay sent **500 triggers at approximately 100/second** through
  the live audio controller/output callback at zero volume: **500 accepted, zero
  dropped**, 48 kHz output. The original diagnostics reported a cached 128-frame
  in-process device buffer reading, not the actual render callback size. The
  original 2.67 ms figure was not a physical key-to-speaker/Bluetooth measurement.
- Closing the settings window left the process and audio callback running.
- Native screenshots of all six settings pages in light/dark appearances, including
  scrolled lower controls, and all four visualizers were visually inspected.
  Separate RealityKit snapshots verified both 3D scenes; camera framing and a
  truncated notch-picker label were corrected and inspected again.
- The signed bundle passed strict/deep verification. Source audio was excluded
  from the app. The Xcode project is included; the working release build uses SwiftPM
  because the installed xcodebuild cannot load its CoreSimulator framework.

Input Monitoring was **not granted** during automated verification. Those native
diagnostic measurements are retained in `verification/report.json`.

## User-confirmed live keyboard check — 2026-09-13

After enabling Input Monitoring, the user confirmed that sounds work correctly when
typing in another app, in response to the one-sound-per-keypress check. Global
physical typing playback is therefore passed by user observation.

Telex, permission revocation/recovery, headphones, multi-display/fullscreen
interaction, sleep/wake, and individual listening checks for every sound profile
remain pending manual checks.

## Responsiveness and loudness follow-up — 2026-09-13

The user reported a quiet lead-in before keyboard hits and much lower loudness
than Keeby on AirPods Pro. Basic capture passed, but audible responsiveness and
headphone loudness were not accepted.

Version 0.1.1 tightens recorded starts to the first audible attack, retains short
edge fades, and applies a common +6.02 dB keyboard playback calibration after
normalization. Silent keeps its relative lower level; mouse/Enter category volumes
and macOS system volume are unchanged. Corrected source intervals and exact frame
cuts are retained in `Assets/extraction.json`.

The small-buffer request now runs after the output graph is prepared and before
callbacks start. Diagnostics query this process's device buffer and independently
record the actual C render callback size, avoiding the earlier cached-buffer ambiguity. The renderer starts a ready
sample on the first frame of the next callback with its existing 0.5 ms safety
ramp; it does not add a silent block.

- All **24 package tests passed**, including +6 dB output comparison, full-volume
  96-voice limiting, immediate render onset, and changing callback-size reporting.
- All **60 recorded asset checks passed**, with 51 starts shortened by a median
  5.73 ms. Marbly's six variants reach 20% of their peak within 0.27–0.52 ms.
  Three previously cut-off precursor clicks were restored from the source, and
  gradual Office attacks were preserved. `verification/sample-onsets.json` records
  per-variant measurements. The onset gate rejects the earlier bank; regeneration
  reproduces the updated WAVs and manifests byte for byte.
- A C-render measurement of Marbly at 40%, centered stereo, neutral tone/pitch,
  normalization on and variation off showed median per-ear RMS increasing from
  −38.71 to −32.69 dBFS, and maximum peak from −14.71 to −8.69 dBFS. These are
  digital signal measurements, not measured sound pressure at the ear.
- The signed 0.1.1 Release app accepted **500/500 software triggers with zero
  drops**. Both the in-process device query and the actual render callback reported
  **128 frames at 48 kHz (2.67 ms)** on MacBook Pro speakers. Audio continued after
  Settings closed. The report is `verification/responsiveness-audio.json`.
  AirPods were not connected during this automated run. Input Monitoring was not
  granted to the rebuilt app; it was reopened for the user to restore access.
- With the final buffer request placed between `prepare()` and `start()`, all
  **20 normal-runtime observations** reported 128-frame device/render blocks and
  continuously advancing audio. See `verification/normal-runtime-audio.json`.
  A separate probe process simultaneously reading 512 frames was reproduced as
  that client's own setting; it was not a regression in Clicky's buffer size.
  Run `--audio-report /tmp/Clicky-Audio.json` for this optional 20-second observation
  without changing settings, injecting input, or recording keys.

AirPods Pro listening and physical key-to-ear latency require another user check
with this update. No equivalence to Keeby's acoustic latency or loudness is claimed.

## User follow-up after permission recovery — 2026-09-13

The user restored Input Monitoring and reported that Clicky is "working well now."
They identified combination-key sounds as the remaining listening concern. The
current path plays an independent profile stroke for each modifier press as well
as the main key, with variation and spatial positioning enabled. Overlapping
modifier strokes are a likely contributor; the exact problematic combinations
and an adjusted modifier policy have not yet been auditioned.

## Modifier sounds and signing — 2026-09-13, version 0.1.2

- **31 package tests passed.** New coverage verifies migration of schema-1 settings
  and every favorite, both sides of every modifier plus Fn, exactly 25% amplitude
  in Soft, silence despite per-key volume overrides, press-time release policy,
  and unchanged main-key timing/shortcut recognition.
- Release integration replay accepted 13 expected triggers in Soft and Full and
  four in Silent: the nine modifiers were omitted in Silent while the chord's
  main key, Enter, mouse and media input continued. Zero triggers were dropped.
  A separate 500-trigger replay passed with actual 128-frame render blocks and
  continued audio after Settings closed. See `verification/modifier-audio.json`.
- Normal operation remained ready for all 20 observations at 128 frames. The
  Sound control and permission recovery UI were inspected in native screenshots
  in light and dark appearances.
- Replaced per-build ad-hoc signatures with one persistent self-signed certificate
  in a dedicated encrypted keychain outside the repository. The requirement pins
  both `dev.clicky.app` and the certificate fingerprint. Private keys, keychain
  passwords and certificate setup artifacts are excluded from the app and ZIP.
- A changed bundle was signed again and satisfied the original requirement with
  a different CodeDirectory hash. An unsigned change was rejected, and the exact
  user keychain search list was restored after signing. These are cryptographic
  checks, not a claim of a successful TCC permission-retention test. Run
  `python3 scripts/verify_signing.py`; see `verification/signing-identity.json`.

The new identity required one user Input Monitoring grant. Retention through a
later live update, Telex composition, AirPods disconnect/reconnect, and physical
sleep/wake remain manual acceptance checks. Windows implementation follows that
Mac acceptance pass.

## User-confirmed combination-key check — 2026-09-13

After being asked to enable Input Monitoring for 0.1.2 and try Command-C,
Command-Shift-S, and Shift-letter combinations with Soft selected, the user
confirmed: "Yes, combinations sound good." The combination-key listening check
is passed by user observation, and Soft remains the default modifier mode.
This also confirms working physical-key playback with the new signing identity;
permission retention through a subsequent update has not yet been tested.

## Notch drag repair — 2026-09-13, version 0.1.3

The user reported that dragging the keyboard did not rotate it. A native mouse
surface now accepts the first click in the non-key panel and owns drag/click
handling above RealityKit. Movement of at least three points starts rotation;
smaller jitter remains a click. The panel stays open through a captured drag,
including outside its frame, and resumes hover dismissal after release. Dynamic
camera distance keeps the model within the viewport while rotating.

- Release build succeeded. **42 native interaction checks passed** for keyboard
  and switch previews: first mouse delivery through `NSWindow.sendEvent`, active
  drag rotation, click/drag separation, drag out and back, pitch clamping, framing
  at ten rotation offsets, outside-panel hold beyond the dismissal timeout,
  release/dismissal, scene teardown, and unchanged foreground focus. See
  `verification/notch-interaction.json`.
- Before/rotated RealityKit snapshots were visually inspected. The first repair
  exposed keyboard clipping during rotation; camera fitting fixed it before
  delivery. Final images are `verification/notch-keyboard-before.png`,
  `verification/notch-keyboard-rotated.png`, and corresponding switch images.
- The signed 0.1.3 app retains the same certificate-pinned requirement as 0.1.2
  and passes strict/deep signature verification. Its ZIP contains version 0.1.3,
  build 4, without source recordings or signing materials.
- After quitting 0.1.2 and normally opening 0.1.3, all 20 runtime observations
  reported **Input Monitoring granted**, ready audio, and 128-frame device/render
  blocks at 48 kHz. This verifies permission retention for this local update.
  See `verification/notch-normal-runtime.json`. The isolated CLI diagnostic's
  permission flag was false; the normally launched app's live report is the
  result for the user-facing permission check.

The mouse replay targets only Clicky's own windows and does not simulate the
WindowServer's delivery of a physical first click.

The user subsequently confirmed "Yes, dragging works now" in response to the
0.1.3 first-drag check with another app focused. Physical first-drag rotation is
therefore passed by user observation.

## Complete sound-bank review — 2026-09-13, version 0.1.4

The user reported hearing two hits from one Creamy keypress, then requested the
same review for every other sound. The input/audio code review found one sample
enqueue per normalized down event, no recorded release samples, no looping or
stereo echo, and only one running Clicky instance. The Creamy waveforms contained
separate sharp impacts 13–31 ms after the first hit. The review expanded to all
60 recorded variants and five original effects.

**26 excerpts were reselected and four contaminated tails trimmed.** All source
selections remain in their original profile sections; 30 recorded variants are
byte-identical to 0.1.3. The four tail trims retain the original attack and end
before a later tap, with the existing eight-millisecond fade. No new input
debouncing, truncation of active audio voices, gating, EQ, or compression was added.

| Profile | Revised variants |
| --- | --- |
| Thocky | 01, 03, 04, 05 |
| Marbly | 02, 04 |
| Silent | None; rounded quiet bodies retained |
| Poppy | 01, 02, 06 |
| Clicky | 01, 03, 04; 05/06 retain their short continuous initial mechanism texture |
| Bubble Wrap | 01, 02, 03, 05 (tail), 06 |
| Clacky | 02, 04 |
| Creamy | 01, 02, 03, 05 |
| Deep Thock | 01, 03 (tail), 04 (tail), 06 (tail) |
| Office | 01, 02, 05; key texture now occurs in the initial attack |

- **All 60 recorded samples and five effects pass** format, edge, headroom, onset,
  and level checks. New renewed-impact checks distinguish a sharp rise from a
  quiet valley from sustained decay. Silent/Office use an upper texture band to
  avoid interpreting their low-frequency bodies as extra strikes. Creamy also
  passes a stricter amplitude check. Analysis filters never alter the WAVs.
- The new checks reject exactly the **30 original problematic excerpts**. A
  synthetic single decay passes and a second impact 30 ms later fails in each
  analysis mode. Source regeneration reproduces all WAVs and both manifests
  byte for byte. See `verification/single-impact-assets.json` and
  `verification/single-impact-rejected-baseline.json`.
- Before/after source waveforms were inspected for every profile. Selection
  times, per-variant decisions and the five original effects are documented in
  `verification/single-impact-review.json`; comparison plots are in
  `verification/sound-waveforms/`. Silent's lower level is preserved. The shared
  normalization reference changes by approximately **−0.15 dB** after reselection.
- Original effects are byte-identical. Typewriter intentionally includes a
  mechanical return at 46 ms; it is a composed effect, not a neighboring recorded
  keystroke. The other four effects have continuous decays.
- Release app compiled and passed signature verification with the existing
  certificate identity. In the real audio engine at zero diagnostic volume,
  **60 down/up pairs per profile produced 60 accepted sounds**: 600/600 total,
  zero drops, and no second sound on key-up. The additional 500-trigger stress
  replay also had zero drops; audio continued after Settings closed. The render
  callback and device reported 128 frames at 48 kHz. See
  `verification/single-impact-playback.json`.
- After reopening normally, all 20 observations report ready audio, Input
  Monitoring still granted, and 128-frame device/render blocks. Both asset copies
  in the final 0.1.4 ZIP match the reviewed sources byte for byte; source media and
  signing secrets are excluded. See `verification/single-impact-normal-runtime.json`.

This was waveform, source, and software-playback verification, not a claim of
human listening or measured key-to-ear latency.

The user subsequently confirmed "Yes, the sounds are clean now" after being
asked to try single keypresses in Creamy and their other favorite profiles in
0.1.4. The single-key listening check is passed by user observation for the
profiles they tried.


## Public repository and landing page

- Reran all 31 core tests, compiled the Release app, and passed the 60-recording /
  five-effect asset checks. The generated Xcode project is current.
- Headless Chromium and WebKit passed the landing-page interaction checks:
  all ten real WAV previews, six predecoded typing variants, repeat suppression,
  soft modifiers, no playback outside the typing field, text clearing, donation
  dialog focus return, and keyboard dragging without triggering a sound.
- Layouts at 320, 390, 768, 1024, 1440, and 1600 pixels fit the page and keyboard.
  Desktop and mobile screenshots were inspected. Both browsers reported no
  JavaScript errors or failed requests. Automated axe WCAG A/AA checks reported
  no violations on the initial page; this is not a complete accessibility audit.
- The ZIP includes installation instructions, MIT license, and recording notices.
  Packaging leaves the app unchanged, verifies its signature after extraction,
  and excludes source media and signing secrets. Two consecutive packages had
  identical SHA-256 hashes. The release remains locally signed and not notarized.
- GitHub Sponsors is configured but the recipient profile still needs activation.
  The Donate button discloses this and offers a working repository support link.

Structured local results: `verification/public-release.json`.
