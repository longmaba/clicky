# Clicky

Make every keystroke feel good. Clicky is a native, offline Mac app that adds
mechanical keyboard sounds to your typing, with twenty sound profiles, soft
modifiers, sound tuning, and an interactive 3D notch keyboard.

[Website & sound playground](https://clicky.longmaba.workers.dev/) ·
[Download 0.2.0](https://github.com/longmaba/clicky/releases/tag/v0.2.0) ·
[Contribute](CONTRIBUTING.md)

Built with SwiftUI/AppKit, physical HID events, and native audio mixing for
**Apple Silicon and macOS 13 or later**. A separate native Windows app is planned;
this repository does not yet ship a Windows executable. Clicky has original
branding and is inspired by Keeby; it is not affiliated with Keeby.

## Install

1. Download `Clicky-macOS-arm64.zip` from the
   [latest release](https://github.com/longmaba/clicky/releases/latest).
2. Unzip it and move `Clicky.app` into Applications.
3. Open the app, then grant **Input Monitoring** as described below.

The current release is signed with a local development certificate and is **not
Apple-notarized**. macOS may block its first launch. After attempting to open it,
use **System Settings → Privacy & Security → Open Anyway** if you choose to trust
this build, or build it yourself from source. Clicky lives in the menu bar and
keeps playing when Settings closes.

## What it does

- Twenty sound profiles, including ten with separate press and release recordings, plus custom imports.
- Recorded switches are grouped by manufacturer (Alps, Drop, Durock, Gateron, IBM, Kailh, NovelKeys, Topre).
- Adjustable tone, pitch, volume, stereo positioning, and per-key overrides.
- Soft modifier sounds so shortcuts feel balanced, with six favorite presets.
- Optional keyboard, keystroke, combo, and bezel visualizers, and a draggable 3D keyboard.
- Output-device selection, headphone options, and optional supported head tracking.
- Offline operation: typed text is never reconstructed, stored, or transmitted.

## Build and open

Use Xcode's Swift command-line toolchain and macOS SDK. No Homebrew, Rust, Node,
or remote Swift package dependency is required. Bundled WAVs are already
extracted; FFmpeg is needed only if you want to regenerate them.

```sh
python3 scripts/sign_app.py --setup  # Once per Mac; may ask for Keychain confirmation.
bash scripts/build.sh
open dist/Clicky.app
```

The default build uses SwiftPM to build the app and local `Packages/ClickyCore`
package, then signs `dist/Clicky.app` with the same local certificate on each build. It also
regenerates `Clicky.xcodeproj` from the current `App` Swift files. The `Assets`
folder and SwiftPM resource bundle are copied into the app's resources.

With a fully initialized Xcode installation, use `bash scripts/build.sh --xcode`
or open `Clicky.xcodeproj` and run its shared **Clicky** scheme. On the development
machine, `xcodebuild` initially could not load its missing CoreSimulator framework;
the default SwiftPM path builds the Mac app without needing that component.

Developer ID signing and notarization are not configured. The first local build
setup creates an encrypted keychain in
`~/Library/Application Support/Clicky Build/Signing/` and adds **current-user Code
Signing trust only** for its self-signed certificate. Private material stays
outside the repository and app. The signing script temporarily adds that keychain
to the existing search list for signing, then restores it; the default keychain,
system trust store, Gatekeeper and TCC records are untouched. Build failures never
fall back to ad-hoc signing or silently replace the certificate.

Keep this signing folder and the app location stable. Back up the folder privately
if you need the same identity after moving Macs. Switching from the earlier ad-hoc
build to this certificate requires one new Input Monitoring grant; subsequent
builds retain the same certificate-bound identity. Quit an older running copy
before rebuilding and reopening. The Xcode target also uses this signing helper.

To package a verified build with installation instructions and license notices:

```sh
python3 scripts/package_release.py
```

This writes `dist/Clicky-macOS-arm64.zip`, verifies the signature after extraction,
and leaves the app unchanged. It does not notarize the release.

## First launch

Open Clicky's settings from its menu-bar icon and enable **Input Monitoring** when
prompted. In **System Settings → Privacy & Security → Input Monitoring**, enable
Clicky; quit and reopen it if macOS requests that. If it is absent from the list,
add the built `Clicky.app` using the system panel's add button. A rebuilt ad-hoc
app may require permission to be enabled again. For a missing entry, use Clicky's
**Show Clicky in Finder** button, then **+** in Input Monitoring to add that exact
copy. Choose **Quit & Reopen** if macOS requests it.

Preview sounds from the app, then choose a profile and turn Clicky on for typing
across applications. Closing settings leaves the menu-bar app running. Use the
menu-bar **Quit** command to stop it. The default toggle shortcut is Command plus
three taps of K; customize it in General settings.

Global capture observes physical input for sound/visual feedback. Typed strings
are not saved or sent to a service. Secure Event Input pauses background feedback,
including when enabled by password fields or terminal applications. Some keyboard
firmware does not expose a separate Fn event; Touch ID/power are not ordinary keys.
Mouse sounds follow macOS left, right, and middle button events, including
trackpad tap-to-click. When that event stream is unavailable, supported raw HID
mouse buttons remain a fallback.

## Sounds and controls

The original ten banks are **Thocky, Marbly, Silent, Poppy, Clicky, Bubble Wrap,
Clacky, Creamy, Deep Thock, and Office**, with six press variants each.

Ten additional packs by **tplai**, imported from
[thock-soundpacks](https://github.com/kamillobinski/thock-soundpacks), provide
separate press and release recordings: **Alps SKCM Blue, Drop Holy Panda,
Durock Alpaca, Gateron Ink Black, Gateron Ink Red, Gateron Turquoise Tealios,
Kailh Box Navy, NovelKeys Cream, Topre Unknown, and IBM Buckling Spring**.
They also include distinct Space, Enter, and Backspace recordings.

Volume, tone,
pitch, stereo width, variation, normalization, per-key overrides, and favorites
are adjustable. Mouse and Enter effects include original Soft, Crisp, Hard, Ding,
and Typewriter sounds. WAV, AIFF, MP3, and M4A imports up to 15 seconds can provide
custom press sounds and optional separately supplied release sounds.

**Extra Sounds → Mouse clicks → Razer Orochi V2** adds recorded button-down/up
sounds by Sadiquecat (CC0), alongside the original mouse options. Left and right
buttons have distinct recordings; middle click uses the left pair. Releases play
on physical button-up, and previews use a 100 ms hold. The website's **Mouse sound**
selector offers the same pack. Soft remains the default.

The app and website play a supported profile's release on physical key-up,
including modifiers; previews play a complete stroke with a 100 ms hold.
Release playback is automatic and needs no setting. The original ten banks
remain press-only: their supplied continuous recording did not yield a
confidently identified isolated release in the
[source review](docs/verification/release-source-review.md).

Recorded keyboard and mouse releases play about 3 dB softer (70% gain), including
previews. Press levels and custom imports keep their configured volume.

**Modifier sounds** offers Soft (25% of normal modifier volume), Silent, and Full.
Soft is the default for Command, Shift, Option, Control and Fn, on either side of
the keyboard. The main key in a shortcut keeps its normal timing and volume;
no chord-detection delay is added. Modifier policy also applies to per-key volume
overrides. Existing settings and favorite snapshots migrate to Soft while keeping
their other values.

Visual settings control floating keyboard/keystroke/combo/bezel feedback and the
3D notch presentation. Overlays use native nonactivating panels. Audio output can
follow the system or a selected device; compatible headphone motion requires
macOS 14+, supported hardware, and motion permission. Bluetooth adds device latency.

Settings and copied imports live in `~/Library/Application Support/Clicky/`.
Configuration format version 1 and HID usage identifiers are intended for reuse
by a future Windows implementation.

## Source audio and reproducibility

The supplied MP4 contains video only. The original ten banks were extracted from its
companion file:

`Thock vs Creamy vs Marbly vs Clack ｜ Best Sound Profile？ Ultimate Keyboard Sound Test [Gzko0BoULdw].f251.webm`

Exact source intervals, processing, file hashes and audio metrics are recorded in
`Assets/extraction.json`. These are short stroke excerpts of continuous typing,
not independently recorded press/release stems. Silent retains its quiet source
character. The five extra effects and the amber keycap icon are original
procedurally generated assets. Source media is not copied into the app bundle.

The ten paired packs are pinned to registry revision
`213e1443c5005a99d5e51b46e31e17f30e4d752a` in `Assets/thock-sources.json`.
`Assets/thock-import.json` records each publisher down/up mapping, source/output
hash, and processing step. Each pack's `brand` comes from that pinned publisher
metadata and groups the switch in the app and on the website. A common gain, resampling, digital-silence trimming,
and short edge fades preserve each pack's recorded phase balance. Original
profiles and their normalization reference remain unchanged. The packs' MIT
license is included in the app and website; see [sound credits](THIRD_PARTY_NOTICES.md).

```sh
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg
python3 scripts/extract_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/import_thock_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/import_thock_mouse_sounds.py --ffmpeg /path/to/ffmpeg --check
python3 scripts/check_sound_assets.py
python3 scripts/check_mouse_sound_assets.py
python3 scripts/audition_sounds.py --output /tmp/clicky-audition.wav --play
python3 scripts/audition_sounds.py --profile novelkeys-cream --category all --hold 0.03 --hold 0.1 --hold 0.3
python3 scripts/audition_sounds.py --mouse --category all --hold 0.03 --hold 0.1 --hold 0.3
swift scripts/create_icon.swift Assets/AppIcon.icns
```

## Checks

```sh
swift test --package-path Packages/ClickyCore
swift build
open -n "$PWD/dist/Clicky.app" --args --diagnostics /tmp/Clicky-QA
open -n "$PWD/dist/Clicky.app" --args --notch-diagnostics /tmp/Clicky-Notch-QA
```

The package tests exercise input/configuration and audio behavior. `swift build`
is a compilation convenience; use the bundled `.app` for realistic Input Monitoring,
menu-bar, resource, and launch-at-login testing. Diagnostic mode renders snapshots
and writes a report to the specified folder, then exits. It does not simulate
physical typing or replace permission/hardware tests. Asset format, edge, headroom
and reproducibility checks passed during creation. Human listening and real hardware
verification remain necessary; see `docs/TESTING.md` for the manual matrix.

`check_sound_assets.py` checks all 181 keyboard WAVs and five generated effects.
It validates the new packs' publisher phase mappings and hashes, and detects
sharp secondary impacts in original stroke excerpts, with separate analysis
for Silent/Office's rounded bodies. The 0.1.4 review covers the original 60
variants and five generated effects. Typewriter's
mechanical return is an intentional part of that optional Enter effect.

The notch diagnostic replays mouse events through Clicky's own inactive panel,
checks drag/click separation, focus, camera framing and dismissal, and saves 3D
snapshots. It uses temporary settings and silent previews; it never posts global
mouse events. A physical first-drag check remains necessary.

## Landing page

The site in `website/` uses plain HTML, CSS, and JavaScript and is hosted at
[clicky.longmaba.workers.dev](https://clicky.longmaba.workers.dev/). Deploy it to
Cloudflare Workers with Node.js 22 or later and Python 3 installed:

```sh
npm ci
npx wrangler login # If not already authenticated
npm run deploy
```

The root `wrangler.jsonc` runs `npm run build`, which uses
`python3 scripts/prepare_website.py` to bundle the site and sound previews into
`build/website`, then publishes that directory. Use `npm run dev` for a local
Workers preview, or `npm run deploy:dry-run` to validate deployment packaging.

To stage and serve the site locally using only Python:

```sh
python3 scripts/prepare_website.py
python3 -m http.server 8080 --directory build/website
```

Open `http://localhost:8080`. Typing anywhere on the page plays the selected
profile and shows a key effect by default; no toggle or input focus is required.
Ordinary left, right, and middle mouse clicks play the bundled Soft effect.
On-screen keys play the selected keyboard profile; dragging rotates the keyboard.
Samples preload silently, and the first keypress or click unlocks browser audio.
Volume 0 mutes both keyboard and mouse sound. The optional typing field is cleared when the page loses focus,
and no typed text is collected or stored.
`website/config.js` holds the repository, release, and donation links. The
GitHub Pages workflow remains separately available and publishes the prepared
site on changes to `main`; repository Pages settings must use **GitHub Actions**
as the build source.

## Contributing and support

Bug reports, sound improvements, documentation, and future Windows work are
welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks.

GitHub Sponsors is being set up at
[github.com/sponsors/longmaba](https://github.com/sponsors/longmaba). The site's
Donate button explains that status until the account can accept contributions.
After activation, set `donationsEnabled: true` in `website/config.js` to link
directly to Sponsors. Starring the repository and contributing are welcome now.

## License and sound credits

Clicky's original source code, website, icon, and generated effects are available
under the [MIT license](LICENSE). Recorded keyboard WAVs are included with
redistribution permission confirmed by the maintainer; their original rights
are retained and they are not covered by MIT. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and scope.
The original video and audio source files are excluded from Git.
