#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"

# Resolve before building. A configured certificate must never silently fall back
# to ad-hoc identity, which changes the app's permission identity on rebuild.
SIGNING_IDENTITY="$(/usr/bin/python3 "$PROJECT_DIR/scripts/configure-local-signing.py" --resolve-build-identity)"

xcrun swift build --disable-sandbox --build-system native --manifest-cache local -c release -debug-info-format none
BIN_DIR="$(xcrun swift build --disable-sandbox --build-system native --manifest-cache local -c release --show-bin-path)"
STAGE_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/SolarCallDesk-build.XXXXXX")"
trap '/bin/rm -rf "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/Solar Call Desk.app"
FINAL_DIST_DIR="${SOLARCALLDESK_DIST_DIR:-$PROJECT_DIR/dist}"
FINAL_APP_DIR="$FINAL_DIST_DIR/Solar Call Desk.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp -X "$BIN_DIR/SolarCallDesk" "$APP_DIR/Contents/MacOS/SolarCallDesk"
cp -X "$PROJECT_DIR/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ "$SIGNING_IDENTITY" == - ]]; then SIGNING_MODE=ad-hoc; else SIGNING_MODE=certificate; fi
/usr/libexec/PlistBuddy -c "Add :SolarSigningMode string $SIGNING_MODE" "$APP_DIR/Contents/Info.plist"

if [[ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]]; then
  cp -X "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Sign and archive outside the synced Documents folder. Finder/File Provider can
# continually reattach FinderInfo to the visible app; cleaning it in place races.
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --identifier local.solar.calldesk --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
if [[ "$SIGNING_MODE" == certificate ]]; then
  /usr/bin/python3 "$PROJECT_DIR/scripts/configure-local-signing.py" --verify-designated-requirement "$APP_DIR"
fi
mkdir -p "$FINAL_DIST_DIR"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$FINAL_DIST_DIR/SolarCallDesk.zip"
/usr/bin/unzip -tq "$FINAL_DIST_DIR/SolarCallDesk.zip"
/usr/bin/ditto -x -k "$FINAL_DIST_DIR/SolarCallDesk.zip" "$STAGE_DIR/extracted"
/usr/bin/codesign --verify --strict "$STAGE_DIR/extracted/Solar Call Desk.app"
/usr/bin/cmp "$APP_DIR/Contents/MacOS/SolarCallDesk" "$STAGE_DIR/extracted/Solar Call Desk.app/Contents/MacOS/SolarCallDesk"
/usr/bin/ditto --norsrc --noextattr "$APP_DIR" "$FINAL_APP_DIR"
/usr/bin/diff -qr "$APP_DIR" "$FINAL_APP_DIR"
/usr/bin/codesign --verify --verbose=2 "$FINAL_APP_DIR"
/usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP_DIR" 2>/dev/null || true
if /usr/bin/codesign --verify --strict "$FINAL_APP_DIR" 2>"$STAGE_DIR/local-verification.txt"; then
  print "Local app strict signature verified."
elif /usr/bin/xattr -p com.apple.FinderInfo "$FINAL_APP_DIR" >/dev/null 2>&1 \
  && [[ "$(cat "$STAGE_DIR/local-verification.txt")" == *"resource fork, Finder information, or similar detritus"* ]]; then
  print "Finder/File Provider reattached FinderInfo to the local app; clean staged and extracted ZIP signatures passed."
else
  cat "$STAGE_DIR/local-verification.txt" >&2
  exit 1
fi
print "Built: $FINAL_APP_DIR"
print "Archive: $FINAL_DIST_DIR/SolarCallDesk.zip"
