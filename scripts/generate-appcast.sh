#!/usr/bin/env bash
#
# Sign a packaged mTerm DMG with Sparkle's EdDSA key and generate a production
# appcast. The private key is read from the macOS Keychain by Sparkle's tool.
#
#   scripts/generate-appcast.sh <version> [output]
#
# Defaults to build/appcast.xml so a release can be created before the live
# appcast at the repository root is replaced and pushed.
set -euo pipefail

APP_NAME="mTerm"
REPOSITORY="luanzt/mTerm"
SPARKLE_KEY_ACCOUNT="mterm-ed25519"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <MAJOR.MINOR.PATCH> [output]" >&2
    exit 2
fi

DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
OUTPUT="${2:-$ROOT/build/appcast.xml}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$ROOT/$OUTPUT"
fi

GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

[ -f "$DMG" ] || {
    echo "error: package first; missing $DMG" >&2
    exit 1
}
[ -x "$GENERATE_APPCAST" ] || {
    echo "error: Sparkle tools not found; run swift build -c release first" >&2
    exit 1
}
[ -x "$SIGN_UPDATE" ] || {
    echo "error: Sparkle sign_update tool not found" >&2
    exit 1
}

ARCHIVES_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mterm-appcast.XXXXXX")"
trap 'rm -rf "$ARCHIVES_DIR"' EXIT
ditto "$DMG" "$ARCHIVES_DIR/$(basename "$DMG")"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/v$VERSION/"
RELEASE_URL="https://github.com/$REPOSITORY/releases/tag/v$VERSION"

echo "==> Signing $(basename "$DMG") and generating appcast"
"$GENERATE_APPCAST" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "$RELEASE_URL" \
    --versions "$VERSION" \
    --maximum-versions 1 \
    -o "$OUTPUT" \
    "$ARCHIVES_DIR"

xmllint --noout "$OUTPUT"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUTPUT" | head -1)"
[ -n "$SIGNATURE" ] || {
    echo "error: generated appcast has no EdDSA signature" >&2
    exit 1
}
"$SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$DMG" "$SIGNATURE"

echo "Done: $OUTPUT"
