#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-run}"
APP_NAME="SplitRoute"
BUNDLE_ID="com.aaronbergman.SplitRoute"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/SplitRoute_SplitRoute.bundle"

if [[ -e "$APP_BUNDLE" ]]; then
    if command -v trash >/dev/null 2>&1; then
        trash "$APP_BUNDLE"
    else
        mv "$APP_BUNDLE" "$DIST_DIR/$APP_NAME.previous.$(date +%s).app"
    fi
fi

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$APP_RESOURCES/SplitRoute_SplitRoute.bundle"
fi

plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..20}; do
            if pgrep -x "$APP_NAME" >/dev/null; then
                echo "$APP_NAME is running from $APP_BUNDLE"
                exit 0
            fi
            sleep 0.25
        done
        echo "$APP_NAME did not stay running." >&2
        exit 1
        ;;
esac
