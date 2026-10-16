#!/usr/bin/env bash
# Builds SnapshotKit.app (and the snapkit CLI) in release mode into ./dist, plus zip archives
# for a release. The app is ad-hoc signed; for distribution, sign and notarize with your own identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/SnapshotKitCore/Support/SnapshotKitVersion.swift)}"

swift build -c release --product SnapshotKit
swift build -c release --product snapkit
BIN="$(swift build -c release --show-bin-path)"

APP="dist/SnapshotKit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SnapshotKit" "$APP/Contents/MacOS/SnapshotKit"
cp "$BIN/snapkit" dist/snapkit

# App icon, compiled from the Icon Composer file: Assets.car for macOS 26 and later (no grey
# legacy frame), plus app-icon.icns rendered from it for macOS 14–25.
ICON_PLIST="$(mktemp)"
xcrun actool assets/app-icon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon app-icon --target-device mac \
  --output-partial-info-plist "$ICON_PLIST" >/dev/null
rm -f "$ICON_PLIST"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SnapshotKit</string>
  <key>CFBundleDisplayName</key><string>SnapshotKit</string>
  <key>CFBundleIdentifier</key><string>org.snapshotkit.SnapshotKit</string>
  <key>CFBundleExecutable</key><string>SnapshotKit</string>
  <key>CFBundleIconFile</key><string>app-icon</string>
  <key>CFBundleIconName</key><string>app-icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 SnapshotKit contributors. MIT License.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
codesign --force --sign - dist/snapkit >/dev/null

ARCH="$(uname -m)"
rm -f dist/*.zip
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "dist/SnapshotKit-$VERSION-macos-$ARCH.zip"
ditto -c -k --norsrc --noextattr --noqtn dist/snapkit "dist/snapkit-$VERSION-macos-$ARCH.zip"
echo "Built $ROOT/$APP and $ROOT/dist/snapkit ($VERSION, $ARCH)"
ls -1 dist/*.zip
