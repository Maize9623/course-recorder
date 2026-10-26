#!/bin/bash
# Builds dist/课程录制工具.app (release, arm64) and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="课程录制工具"
BUNDLE_ID="com.gene.course-recorder"
APP="dist/${APP_NAME}.app"

swift build -c release
BIN=".build/release/CourseRecorder"

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  "$BIN" --make-icon "$ICONSET/icon_1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm "$ICONSET/icon_1024.png"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CourseRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Use a real signing identity when one exists. Ad-hoc signatures get an identifier-based designated
# requirement, so camera / microphone / screen permissions survive rebuilds instead of being tied to the binary hash.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}' || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi

echo "✅ 已生成：${APP}（签名：${IDENTITY:-ad-hoc}）"
