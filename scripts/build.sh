#!/usr/bin/env bash
set -euo pipefail

clicky_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$clicky_root"

clicky_backend="swiftpm"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --xcode) clicky_backend="xcode" ;;
    --help|-h)
      printf 'Usage: bash scripts/build.sh [--xcode]\nDefault: SwiftPM release build and local .app packaging.\n'
      exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
fi
[[ $# -eq 0 ]] || { printf 'Too many arguments\n' >&2; exit 2; }

python3 scripts/generate_xcode_project.py
if [[ ! -f Assets/AppIcon.icns || scripts/create_icon.swift -nt Assets/AppIcon.icns ]]; then
  swift scripts/create_icon.swift Assets/AppIcon.icns
fi
plutil -lint App/Info.plist

if [[ "$clicky_backend" == "xcode" ]]; then
  xcodebuild \
    -project Clicky.xcodeproj \
    -scheme Clicky \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$clicky_root/build/DerivedData" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build
  clicky_product="$clicky_root/build/DerivedData/Build/Products/Release/Clicky.app"
  test -d "$clicky_product"
else
  mkdir -p "$clicky_root/build"
  # A clean release build also avoids stale SwiftPM build-description failures
  # in the installed Swift 6.3 toolchain. Only this script's scratch cache is cleared.
  swift package --scratch-path "$clicky_root/build/swiftpm" clean
  swift build --configuration release --arch arm64 --scratch-path "$clicky_root/build/swiftpm"
  clicky_bin="$(swift build --configuration release --arch arm64 --scratch-path "$clicky_root/build/swiftpm" --show-bin-path)"
  test -x "$clicky_bin/Clicky"
fi

mkdir -p "$clicky_root/dist"
clicky_stage="$(mktemp -d "$clicky_root/build/package.XXXXXX")"
trap 'rm -rf -- "$clicky_stage"' EXIT
clicky_app="$clicky_stage/Clicky.app"
if [[ "$clicky_backend" == "xcode" ]]; then
  ditto "$clicky_product" "$clicky_app"
else
  clicky_contents="$clicky_app/Contents"
  mkdir -p "$clicky_contents/MacOS" "$clicky_contents/Resources"
  ditto "$clicky_bin/Clicky" "$clicky_contents/MacOS/Clicky"
  ditto "$clicky_bin/Clicky_Clicky.bundle" "$clicky_contents/Resources/Clicky_Clicky.bundle"
  ditto Assets "$clicky_contents/Resources/Assets"
  cp Assets/AppIcon.icns "$clicky_contents/Resources/AppIcon.icns"
  python3 - "$clicky_contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
with open('App/Info.plist', 'rb') as source:
    info = plistlib.load(source)
replacements = {'$(EXECUTABLE_NAME)': 'Clicky', '$(PRODUCT_BUNDLE_IDENTIFIER)': 'dev.clicky.app',
                '$(PRODUCT_NAME)': 'Clicky', '$(MARKETING_VERSION)': '0.1.4',
                '$(CURRENT_PROJECT_VERSION)': '5', '$(MACOSX_DEPLOYMENT_TARGET)': '13.0'}
info = {key: replacements.get(value, value) if isinstance(value, str) else value for key, value in info.items()}
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(info, output, sort_keys=False)
pathlib.Path(sys.argv[1]).with_name('PkgInfo').write_bytes(b'APPL????')
PY
fi
python3 scripts/sign_app.py "$clicky_app"
codesign --verify --deep --strict "$clicky_app"
# Publish only a fully packaged, verified signed app. Signing failures retain
# the previous deliverable; installed copies and user configuration are untouched.
rm -rf -- "$clicky_root/dist/Clicky.app"
ditto "$clicky_app" "$clicky_root/dist/Clicky.app"
codesign --verify --deep --strict "$clicky_root/dist/Clicky.app"
printf '\nBuilt app with persistent local signing: %s\n' "$clicky_root/dist/Clicky.app"
printf 'Open it with: open "%s"\n' "$clicky_root/dist/Clicky.app"
