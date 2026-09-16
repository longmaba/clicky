# Clicky verification

## Softer releases and 0.2.0 build — 2026-09-16

Recorded keyboard and mouse releases now use **0.7 playback gain** (about
3.1 dB lower) for physical input and complete previews. Press levels, original
WAVs, and custom imports retain their previous behavior. Both native version
sources and the generated Xcode project specify **0.2.0, build 6**.

- **66 core tests passed**, including absolute press/release gain assertions,
  keyboard normalization, mouse button routing, and preview parity.
  Publication CI later exposed a timing assumption in the preview test: a
  40 ms sleep resumed after the scheduled 100 ms release. The test now checks
  observed monotonic time with a bounded completion deadline and keeps checking
  that press-only previews remain single. See the
  [original failed run](https://github.com/longmaba/clicky/actions/runs/35047177025).
  This test correction does not change the published app or ZIP.
- **27 Python tests passed** with FFmpeg available. Both pinned importers passed
  `--offline --check`; keyboard and mouse asset checks also passed.
- **Chromium and WebKit passed** the complete regression suite, including
  explicit gain checks for generic/special keys, modifiers, mouse buttons and
  previews. Press gains are unchanged and release gains are multiplied by 0.7.
  Both browsers reported zero page errors. See
  [browser results](verification/softer-release-website.json).
- Six raw-asset auditions cover isolated phases and pairs at 30/100/300 ms
  holds with two overlapping voices. Release gain is recorded in each timeline;
  the largest mix peak is 0.62833 with no clipping. The helper now defaults to
  0.7 release gain; `--release-gain 1` restores the recorded balance for review.
  See [audition results](verification/softer-release-auditions.json).
- The signed app and packaged ZIP contain **190 WAVs**, both catalogs and both
  notices. Signature verification also passed after extracting the ZIP. All
  **199 website files** match the browser staging directory. See
  [build and archive results](verification/0.2.0-build.json).
- The packaged app passed **67 replay checks**, accepting all **3,190 sounds**
  with zero drops. All 190 samples loaded, and audio continued after Settings
  closed. See [native results](verification/softer-release-native.json).

The distribution ZIP is `dist/Clicky-macOS-arm64.zip`, with SHA-256 recorded in
[the build report](verification/0.2.0-build.json) and the release's `SHA256SUMS`.
Public download links now target the [0.2.0 release](https://github.com/longmaba/clicky/releases/tag/v0.2.0).
The repository's existing main-push workflow deploys GitHub Pages.

Cloudflare Workers tooling is also committed. `npm run deploy:dry-run` passed
with the locked Wrangler 4.131.1, preparing 199 website files (186 WAVs) without
uploading. This checks local build/configuration/packaging; remote account and
live Workers behavior were not tested, and no Cloudflare deployment was run.
Listening and physical hardware acceptance remain separate from automated checks.

## Recorded mouse press/release sounds — 2026-09-16

Added **Razer Orochi V2** by Sadiquecat (CC0) to the existing mouse sound choices.
The app and website use distinct recorded left/right presses and releases, with
the left pair as the documented middle-button fallback. Soft remains the default.
Mamba Elite's embedded license restricts use to Thock; the unidentified Pixabay
pack's distribution permission is unresolved. Neither pack is included.

- **65 core tests passed**, including eight new mouse controller/configuration
  tests. They cover button-specific PCM selection, middle fallback, holds,
  duplicate/orphan events, simultaneous buttons, sound changes while held,
  None/zero-volume/reset/suspension, complete cancellable previews, raw mouse
  volume, and existing configuration/favorite round-trips.
- **26 Python tests passed** with FFmpeg available, including three mouse import
  tests and mouse-category audition coverage. Mouse and keyboard import checks
  passed from the pinned source cache. The previous 186 WAVs and twenty-profile
  keyboard manifest are unchanged.
- All **four mouse WAVs passed** source/phase/hash, format, boundary, headroom,
  and lead-in checks. They are mono PCM16 at 48 kHz, last 84.25–84.92 ms, and
  peak at 0.33820. Source stereo is averaged to mono with the same processing
  for all phases. See [mouse asset results](verification/thock-mouse-sound-assets.json).
- The Release app built with the existing local certificate. Both native
  resource copies contain all **190 WAVs**, both catalogs, and both sound notices
  with identical bytes. The website stages 181 keyboard WAVs, four recorded mouse
  WAVs, and the original Soft click.
- **Chromium and WebKit passed** the full keyboard/mouse regression suite with
  zero page errors. Mouse checks cover all three buttons, original Soft first
  interaction, phase identity, held releases, simultaneous buttons, changing
  sounds, mute/reset/focus loss, keyboard/touch previews, slow loads/resumes, and
  unavailable-file fallback. Final 320/1440 px layouts show full model names and
  no horizontal overflow. WebKit's initial unactivated audio context required a
  controlled activation before the test's suspension probe; the harness now
  observes state with bounded waits. See [browser results](verification/thock-mouse-website.json).
- All **199 staged website files** match the browser-verified output; all staged
  sound bytes and notices match `Assets`. See [bundle results](verification/thock-mouse-bundle.json).
- The packaged app passed **67 replay checks** with 3,190 accepted sounds and
  zero drops. Each mouse button produced 20 sounds from ten down/up pairs, and
  all 190 samples loaded successfully. Audio continued after Settings closed.
  See [native results](verification/thock-mouse-native.json). This replay sends
  software events to the real audio engine; it is not physical mouse testing.
  An initial run counted two extra UI preview sounds; the diagnostic now
  suppresses UI auditions during its replay. The [initial report](verification/thock-mouse-native-before-preview-isolation.json)
  is retained, and normal app previews are unchanged.
- Isolated press/release and paired auditions cover all four recordings at
  30/100/300 ms holds, including overlapping voices. The loudest mixed audition
  peaks at 0.46405 with no clipping; timestamps match the requested holds. See
  [audition metadata](verification/thock-mouse-auditions.json) and local WAVs in
  `build/auditions/thock-mouse/`.

Listening, physical mouse/trackpad acceptance, and real sleep/wake remain user
checks. This update has not been publicly released or deployed.

## Paired Thock catalog import — 2026-09-16

Added ten tplai packs alongside the original ten profiles, using registry commit
`213e1443c5005a99d5e51b46e31e17f30e4d752a`. All ten new packs have publisher-mapped
press/up recordings, including Space, Enter/keypad Enter, and Backspace. The
original profiles, default selection, and all 65 original WAVs are unchanged.
The original ten remain press-only; their earlier video review is recorded below.

- **57 core tests passed**, including 22 controller integration tests. New
  coverage checks special-key routing and fallback, per-key profile overrides,
  saved releases across profile changes, Enter-effect precedence, category
  previews, and deduplicated sample registration. Tests verify that adding the
  packs leaves original normalized playback bit-for-bit unchanged and applies
  one peak-bounded normalization correction to both phases of a stroke.
- **22 Python tests passed**: 12 extraction/asset/audition tests, five pinned
  importer tests, and five category audition tests. Both importers passed
  reproducibility checks using FFmpeg 7.1 and the verified source cache. Missing
  keypad Enter mappings, wrong source phases, altered hashes, and unverified
  original-video release cuts are rejected.
- **Asset checks passed** for 181 keyboard WAVs (140 presses, 41 releases) and
  five original effects. All use mono PCM16 at 48 kHz with zero boundaries and
  headroom. Imported stems preserve quiet mechanical lead-ins; publisher config
  mappings establish phase identity. Their maximum encoded peak is 0.41550.
  See [asset measurements](verification/thock-sound-assets.json).
- The locally signed Release app built and passed **64 native replay checks**:
  3,130 accepted sounds, zero drops, 186 loaded samples, and continuing audio
  after Settings closed. Sixty strokes per original profile produced 60 sounds;
  sixty per paired profile produced 120. Ten strokes on each of four mapped
  keys per paired profile produced 20 sounds. The output callback used 128 frames
  at 48 kHz. See [native playback](verification/thock-key-release-playback.json).
- All **42 notch checks passed**, including silent drags, preview counts,
  interaction cleanup, and unchanged foreground focus. These window-event tests
  used the default press-only profile; paired previews are covered by controller
  tests. See [notch results](verification/thock-key-release-notch.json).
- **Chromium and WebKit passed** the full twenty-profile suite: 26 capability
  checks, 63 keycaps, and zero page errors each. It covers real catalog pairs,
  exact category routing, holds, first interaction, slow loading, focus loss,
  modifiers, simultaneous keys, muted/reset releases, touch, keyboard-activated
  previews, and silent rotation drags. Desktop and 320/390 px catalog screenshots
  were reviewed, as were native light/dark Settings screenshots with long names.
  See [browser results](verification/thock-key-release-website.json).
- The app's two resource copies and staged website contain identical keyboard
  audio and the complete Thomas Lai MIT notice. All 193 staged website files
  match the browser-verified output. Website paths are remapped from `Sounds/`
  to `sounds/`. See [bundle checks](verification/thock-bundle.json).
- Generated 34 isolated/pair/fast-typing audition WAVs with timelines covering
  every imported sample and 30/100/300 ms holds. All 960 paired voice timings
  match the requested holds; no audition clips. Maximum mixed peak is 0.44620.
  Metadata is in [audition results](verification/thock-auditions.json); local WAVs
  are in `build/auditions/thock/`.

This is a local build and staged website update; no public release or deployment
was performed. Listening review, physical typing on two keyboards, and actual
sleep/wake acceptance remain user checks. The automated native replays exercise
software event delivery and rendering, not measured physical key-to-ear latency.
Browser verification used the repository's standalone Playwright runner because
the in-app browser connection was unavailable.

## Key-release playback support — 2026-09-15

At this stage, the app and website supported optional, independently timed release
recordings and complete 100 ms previews. **No production releases had been approved.**
The supplied video/audio review could not establish a clean authentic release;
all ten bundled profiles remain press-only. See
[the source-review findings](verification/release-source-review.md) and
`Assets/release-review.json` for exact windows, evidence, and limitations.

- All **50 core tests** passed, including 15 controller tests using temporary
  fixture banks and the real decoder/queue/mixer with offline rendering. Tests
  cover holds, duplicates, orphan releases, modifiers, two keyboards, saved
  tuning, effective mute and per-key overrides, imports, preview cancellation,
  reset, suspension, output rebuild, and bank replacement.
- A positive paired fixture replay submitted **500 strokes / 1,000 triggers**
  at simulated 10 ms spacing with releases 30 ms after presses. It had zero
  dropped triggers or stolen voices and finite, bounded rendered audio.
- The Release app built successfully. Real-output diagnostics passed 500
  strokes plus 60 strokes per production profile, with zero drops and continuing
  audio after Settings closed. Production profiles correctly submitted only
  their press phase. The output/render block size was 128 frames at 48 kHz.
  See `verification/key-release-playback.json`.
- All **42 native notch checks** passed, including preview counts, silent
  drags, jitter, release/reset, and retained foreground focus. See
  `verification/key-release-notch.json`.
- All **9 sound-tool tests** passed. Extraction reproducibility and asset checks
  passed: 60 presses, zero verified releases, and five original effects. Every
  existing WAV and `profiles.json` is byte-identical to the prior version.
- Chromium and WebKit passed the complete website regression suite with the
  production manifest and separate in-memory paired fixtures. Checks cover
  physical release timing beyond the animation timer, overlapping holds,
  modifiers, profile changes, mute/reset, superseded previews, touch, silent
  drags, missing samples, and delayed audio resume. Test audio is never staged
  or shipped. One interrupted run lost focus to the native diagnostic window;
  the final browser runs were isolated from native window activity.
  See `verification/key-release-website.json` for the combined results and run notes.

The in-app browser connection was unavailable; browser verification used the
repository's documented standalone regression runner. There was no human
listening or physical keyboard acceptance check, no new sound-bank publication,
and no website deployment. Isolated recordings are still needed to enable
authentic releases in the production profiles.

## Mouse click fixes — 2026-09-14

The Mac app now observes left, right, and middle mouse transitions through its
listen-only session event tap, covering trackpad tap-to-click. HID mouse input
is used only when that tap cannot be created, preventing duplicate sounds from
the two streams. Keyboard HID input and the existing Fn path remain in place.

- All 35 core tests passed, including mouse mapping, source selection,
  simultaneous buttons, modifier handling, fallback devices, and reset recovery.
- The Release app was rebuilt with the existing local certificate. Signing and
  ZIP extraction verification passed. The reopened normal app reported ready
  audio, Input Monitoring granted, and 128-frame render blocks.
- Physical mouse/trackpad playback and listening still require a user check.
  The macOS session stream cannot distinguish the same button held on separate
  mice; HID fallback retains separate device identities.

The website now plays the original Soft effect on ordinary mouse clicks and
touch taps. Keyboard rows preserve their 3D transform space, and the decorative
bottom strip no longer intercepts key clicks; the rotation button stays active.
Chromium and WebKit passed first-gesture audio, all three mouse buttons, all 63
on-screen keys, touch taps, mute, silent dragging, duplicate prevention, and
slow-loading checks, alongside the existing keyboard/profile checks. The live
Worker's homepage, script, styles, and mouse WAV matched the tested build.

Local reports: `build/website-checks/report.json`,
`build/website-worker-mouse-check.json`, and `build/mouse-fix-runtime.json`.

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
uses temporary configuration and near-silent previews, without global input
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


## Page-wide website typing (2026-09-14)

The landing page now responds to physical keyboard events anywhere in its own
document, without an enable toggle or a focused typing box. WAVs preload without
playing; the first keypress resumes browser audio. A fixed keycap indicator makes
feedback visible even when the hero keyboard is offscreen. Volume 0 mutes audio
while retaining visual feedback.

`scripts/check_website.cjs` passed in Chromium and WebKit:

- No playback on page load; first keypress plays without a preliminary click.
- One stroke per press, suppressed held-key repeats, and balanced modifiers.
- Enter, Numpad Enter, and Space on preview buttons do not produce double sounds.
- Normal text entry, select-all, and volume-slider arrow controls still work.
- All ten profiles respond across the page without moving focus to the textarea.
- Muting preserves visual effects; blur clears the temporary textarea and feedback.
  The next keypress resumes audio without an enable step.
- Donation dialog behavior remains intact, and the indicator fits 320, 390, and
  1440 pixel viewports while scrolled to the footer. Reduced motion is respected.
- Typing before a slow download finishes produces no delayed burst of old keys.

Desktop/mobile screenshots were inspected. Results are in
`verification/website-pagewide.json`. These are browser/software checks, not
manual listening or measured key-to-ear latency. The native app is unchanged.
