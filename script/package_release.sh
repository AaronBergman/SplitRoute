#!/usr/bin/env bash

set -euo pipefail

APP_NAME="SplitRoute"
VERSION="0.1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
DMG_PATH="$RELEASE_DIR/$APP_NAME-v$VERSION.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
WORK_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/splitroute-release.XXXXXX")"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
DMG_ROOT="$WORK_DIR/dmg-root"
MOUNT_POINT="$WORK_DIR/mount"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    if [[ -d "$WORK_DIR" ]]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$WORK_DIR"
        else
            mv "$WORK_DIR" "$RELEASE_DIR/.staging.previous.$(date +%s)"
        fi
    fi
}
trap cleanup EXIT

cd "$ROOT_DIR"
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/SplitRoute_SplitRoute.bundle"

mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$DMG_ROOT" "$MOUNT_POINT" "$RELEASE_DIR"
cp "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Release resource bundle is missing: $RESOURCE_BUNDLE" >&2
    exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP_RESOURCES/SplitRoute_SplitRoute.bundle"

plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

ditto "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

for existing in "$DMG_PATH" "$CHECKSUM_PATH"; do
    if [[ -e "$existing" ]]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$existing"
        else
            mv "$existing" "$existing.previous.$(date +%s)"
        fi
    fi
done

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    "$DMG_PATH"
hdiutil verify "$DMG_PATH"

hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$MOUNT_POINT" \
    "$DMG_PATH" >/dev/null
MOUNTED=1

codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app"
test -L "$MOUNT_POINT/Applications"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
    echo "Expected version $VERSION but packaged $ACTUAL_VERSION." >&2
    exit 1
fi

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "Created $DMG_PATH"
echo "Created $CHECKSUM_PATH"
