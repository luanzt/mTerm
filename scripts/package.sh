#!/usr/bin/env bash
#
# Build mTerm as a distributable macOS app + .dmg.
#
#   scripts/package.sh [version]
#
# version defaults to the latest git tag (or 0.0.0). A leading "v" is stripped,
# so `scripts/package.sh v0.1.0` and `scripts/package.sh 0.1.0` are equivalent.
#
# Output: build/mTerm-<version>.dmg  (drag mTerm.app into Applications)
#
# The app is ad-hoc code-signed (`codesign -s -`) so it launches on Apple
# Silicon, but it is NOT notarized: on first open the user must right-click the
# app and choose "Open" (or allow it in System Settings ▸ Privacy & Security).
set -euo pipefail

APP_NAME="mTerm"
BUNDLE_ID="com.luanzt.mterm"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building $APP_NAME $VERSION (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Optional app icon: drop an AppIcon.icns at packaging/AppIcon.icns to embed it.
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
    cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$APP/Contents/Info.plist" >/dev/null
    echo "    embedded packaging/AppIcon.icns"
fi

echo "==> Ad-hoc code-signing"
codesign --force --deep --sign - "$APP"

echo "==> Building $(basename "$DMG")"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Done: $DMG"
echo
echo "Publish it as a GitHub Release:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION \"$DMG\" --generate-notes"
