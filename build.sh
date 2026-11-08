#!/usr/bin/env zsh
# Build "build/Screen It Recorder.app"; `--install` also replaces it in /Applications
# and relaunches it.
# Signing, in order: SIGN_ID (e.g. "Developer ID Application: …", adds the hardened runtime),
# else the local identity from tools/make-local-signing-cert.sh, else ad hoc. Only a stable
# identity keeps macOS's Screen Recording / Camera / Mic permission across rebuilds.
set -euo pipefail
cd "${0:A:h}"

APP="build/Screen It Recorder.app"
INSTALLED="/Applications/Screen It Recorder.app"
LOCAL_ID="ScreenItRecorder Local Signing"
swift build -c release

rm -rf "$APP" build/ScreenItRecorder.app build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp .build/release/ScreenItRecorder "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/tile.svg Resources/face.svg "$APP/Contents/Resources/"

swift tools/make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --entitlements Resources/ScreenItRecorder.entitlements \
    --sign "$SIGN_ID" "$APP"
elif security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1; then
  codesign --force --sign "$LOCAL_ID" "$APP"
else
  echo "Signing ad hoc — permissions reset every build. Run tools/make-local-signing-cert.sh once." >&2
  codesign --force --sign - "$APP"
fi
codesign -dr - "$APP" 2>&1 | grep designated
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "com.mergodon.ScreenItRecorder"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x ScreenItRecorder >/dev/null || break; sleep 0.5; done
  rm -rf "$INSTALLED" /Applications/ScreenItRecorder.app  # second path: the pre-rename name
  cp -R "$APP" /Applications/
  open "$INSTALLED"
  echo "Installed $INSTALLED"
fi
