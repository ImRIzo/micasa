#!/bin/bash
# Builds Micasa.app for Apple Silicon (M1/M2/M3/M4).
#
#   ./build-app.sh              build build/Micasa.app (arm64)
#   ./build-app.sh --universal  arm64 + Intel in one app
#   ./build-app.sh --install    also copy it to /Applications
#
# Needs Xcode 15+ or the Command Line Tools (xcode-select --install) and macOS 14+.

set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Micasa for macOS must be built on a Mac." >&2
  exit 1
fi

if [[ $UNIVERSAL -eq 1 ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=(--arch arm64)
fi

echo "==> Compiling (release)…"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/Micasa.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Micasa" "$APP/Contents/MacOS/Micasa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc, for this Mac)"
codesign --force --sign - --timestamp=none "$APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "==> Installing to /Applications"
  rm -rf /Applications/Micasa.app
  cp -R "$APP" /Applications/Micasa.app
  APP="/Applications/Micasa.app"
fi

# Tell Finder about the app's photo types so it appears under "Open With".
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" || true

echo
echo "Done: $APP"
echo "Open a photo with:  open -a \"$APP\" ~/Pictures/some-photo.heic"
