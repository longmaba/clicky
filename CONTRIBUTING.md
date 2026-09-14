# Contributing to Clicky

Thank you for helping improve Clicky. Please open an issue before a large
feature or architectural change so we can agree on its scope. Focused fixes,
accessibility improvements, and reproducible bug reports are welcome.

## Develop and check

The Mac app targets macOS 13+ on Apple Silicon. Install the Xcode command-line
tools, then follow the [build instructions](README.md#build-and-open) for local signing
and packaging. Each contributor creates their own local signing identity;
never share private keys, certificates with private keys, or keychain passwords.

Run the checks relevant to your change:

```sh
swift test --package-path Packages/ClickyCore
swift build -c release
python3 scripts/check_sound_assets.py
python3 scripts/generate_xcode_project.py
git diff --exit-code -- Clicky.xcodeproj
```

If you add or remove an app source file, regenerate the Xcode project and include
the resulting project changes in your pull request. The final diff check verifies
that the checked-in project is current; it is expected to show those changes
until you have included them in your commit.

The website is plain HTML, CSS, and JavaScript. It has no package install step:

```sh
python3 scripts/prepare_website.py
node --check website/app.js
python3 -m http.server 8080 --directory build/website
```

Open <http://localhost:8080> to check layout, keyboard navigation, sound previews,
and links. Test at both narrow mobile and desktop widths. The staging script
copies the ten prepared sound banks into the site; do not add source recordings.

For changes to keyboard or audio behavior, the browser regression check runs in
Chromium and WebKit. With the local server above still running, use a separate
terminal (Node.js and npm are development dependencies for this check only):

```sh
npm install --prefix /tmp/clicky-browser-checks playwright@1.63.0
/tmp/clicky-browser-checks/node_modules/.bin/playwright install chromium webkit
NODE_PATH=/tmp/clicky-browser-checks/node_modules CLICKY_SITE_URL=http://localhost:8080/ node scripts/check_website.cjs
```

It checks first-key activation across the page, repeat and button deduplication,
normal text selection, profile changes, muting, focus recovery, mobile key
feedback, and slow audio loading. Screenshots and a report go to
`build/website-checks/`. Only use a local server for this development check.

## Pull requests

Describe the problem, the behavior after your change, and how you checked it.
For interface changes, include a screenshot or short recording. For audio or
input changes, include the sound profile, input device, output device, macOS
version, and relevant listening or integration checks. Do not attach typed
content or unrelated personal information to a report.

Keep audio rendering free of allocations, locks, decoding, and logging. Input
handling should remain based on physical key transitions; Clicky must not
reconstruct, collect, or persist the user's typed text. Add tests for behavior
changes in the portable core when they can catch meaningful regressions.

Code contributions are made under the repository's MIT license. New sound or
visual assets must have a clear source and permission for distribution. The
existing recorded keyboard sounds have separate terms documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); do not treat them as MIT assets.
