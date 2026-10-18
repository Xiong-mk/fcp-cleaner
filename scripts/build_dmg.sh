#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
# Build a local ad-hoc test installer using macOS tools; no Homebrew dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_INPUT=""
REQUIRE_UNIVERSAL=0
OUTPUT="$ROOT/build/releases/FCP Cleaner.dmg"
usage() {
    cat <<'HELP'
Usage: ./scripts/build_dmg.sh [--app PATH.app] [--output PATH.dmg]
Without --app, builds a universal Release from the current project.
Requires macOS, Xcode and Finder automation permission in a logged-in GUI session.
The output is an ad-hoc signed, unnotarized test installer. Existing output is refused.
HELP
}
die() { echo "Error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--output)
            [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
            if [[ "$1" == --app ]]; then APP_INPUT="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || die "This script requires macOS."
[[ "$OUTPUT" == *.dmg ]] || die "Output must end with .dmg"
mkdir -p "$(dirname "$OUTPUT")" "$ROOT/build"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
[[ ! -e "$OUTPUT" ]] || die "Output exists: $OUTPUT (choose another --output)"
[[ ! -e "$OUTPUT.sha256" && ! -e "$OUTPUT.json" ]] || die "Output metadata already exists."
WORK="$(mktemp -d "$ROOT/build/dmg-work.XXXXXX")"
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$MOUNTED" == 1 ]]; then
        if ! hdiutil detach "$MOUNT"; then
            echo "Could not detach; preserved working directory: $WORK" >&2
            exit 1
        fi
    fi
    rm -rf "$WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$APP_INPUT" ]]; then
    REQUIRE_UNIVERSAL=1
    echo "Building universal Release (arm64 + x86_64)…"
    BUILD_LOG="$ROOT/build/dmg-release-build.log"
    if ! xcodebuild -project "$ROOT/FCP Cleaner/FCP Cleaner.xcodeproj" \
        -scheme "FCP Cleaner" -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/build/DMG" \
        ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO DEVELOPMENT_TEAM= build > "$BUILD_LOG" 2>&1; then
        tail -60 "$BUILD_LOG" >&2
        die "Build failed; see $BUILD_LOG"
    fi
    APP_INPUT="$ROOT/build/DMG/Build/Products/Release/FCP Cleaner.app"
fi
[[ -d "$APP_INPUT/Contents" ]] || die "Not an app bundle: $APP_INPUT"
[[ -f "$APP_INPUT/Contents/Info.plist" ]] || die "Missing Info.plist"

STAGING="$WORK/staging"
APP="$STAGING/FCP Cleaner.app"
mkdir -p "$STAGING/.background" "$MOUNT"
ditto --noqtn "$APP_INPUT" "$APP"
cp "$ROOT/Resources/DMG/安装说明.txt" "$STAGING/安装说明.txt"
cp "$ROOT/Resources/DMG/background.png" "$STAGING/.background/background.png"
ln -s /Applications "$STAGING/Applications"

echo "Signing the packaging copy (ad-hoc, project sandbox entitlements)…"
"$ROOT/scripts/sign_adhoc.sh" "$APP"
for legal in LICENSE.txt COPYING.txt THIRD_PARTY_NOTICES.txt Sparkle-LICENSE.txt; do
    [[ -f "$APP/Contents/Resources/$legal" ]] || die "Missing bundled legal resource: $legal"
done

echo "Creating read/write image…"
hdiutil create -volname "FCP Cleaner" -fs HFS+ -srcfolder "$STAGING" \
    -format UDRW "$WORK/Editable.dmg"
hdiutil attach "$WORK/Editable.dmg" -mountpoint "$MOUNT" -nobrowse -noautoopen
MOUNTED=1

echo "Saving Finder background and icon positions…"
/usr/bin/osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias
    tell application "Finder"
        set installWindow to make new Finder window to (POSIX file mountPath as alias)
        set installFolder to target of installWindow
        tell installWindow
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set bounds to {160, 120, 1060, 720}
        end tell
        set viewOptions to icon view options of installWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        set text size of viewOptions to 14
        set label position of viewOptions to bottom
        set background picture of viewOptions to backgroundFile
        set position of item "FCP Cleaner.app" of installFolder to {200, 245}
        set position of item "Applications" of installFolder to {700, 245}
        set position of item "安装说明.txt" of installFolder to {450, 415}
        update installFolder without registering applications
        delay 2
        close installWindow
        delay 2
    end tell
end run
APPLESCRIPT

[[ -s "$MOUNT/.DS_Store" ]] || die "Finder did not save the layout (.DS_Store)."
# DiskImageMounter opens the saved root window on double-click. Do not use the
# deprecated bless --openfolder operation, which is unsupported on Apple Silicon.
sync
hdiutil detach "$MOUNT"
MOUNTED=0

echo "Compressing and verifying final image…"
hdiutil convert "$WORK/Editable.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/Final.dmg"
hdiutil verify "$WORK/Final.dmg"
# Read-only remount checks catch layout or bundle damage introduced by conversion.
hdiutil attach "$WORK/Final.dmg" -mountpoint "$MOUNT" -readonly -nobrowse -noautoopen
MOUNTED=1
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]] || die "Invalid Applications link"
[[ -s "$MOUNT/.DS_Store" && -s "$MOUNT/.background/background.png" ]] || die "Missing Finder layout"
cmp "$ROOT/Resources/DMG/安装说明.txt" "$MOUNT/安装说明.txt"
codesign --verify --deep --strict --verbose=2 "$MOUNT/FCP Cleaner.app"
codesign -d --entitlements :- "$MOUNT/FCP Cleaner.app" > "$WORK/entitlements.plist" 2>/dev/null
python3 - "$MOUNT/FCP Cleaner.app" "$WORK/entitlements.plist" "$WORK/metadata.json" "$REQUIRE_UNIVERSAL" <<'PY'
import json, pathlib, plistlib, subprocess, sys
app, entitlements_file, output = map(pathlib.Path, sys.argv[1:4])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
entitlements = plistlib.loads(entitlements_file.read_bytes())
bundle_id = info["CFBundleIdentifier"]
expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.network.client": True,
    "com.apple.security.temporary-exception.mach-lookup.global-name": [
        f"{bundle_id}-spks", f"{bundle_id}-spki",
    ],
}
if entitlements != expected:
    raise SystemExit(f"Unexpected package entitlements: {entitlements}")
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
if sys.argv[4] == "1" and set(architectures) != {"arm64", "x86_64"}:
    raise SystemExit(f"Universal build is missing an architecture: {architectures}")
signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True).stderr
if "Signature=adhoc" not in signature:
    raise SystemExit("The package is not ad-hoc signed")
metadata = dict(version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"],
                bundle_id=info["CFBundleIdentifier"], minimum_macos=info["LSMinimumSystemVersion"],
                architectures=architectures, signature="ad-hoc", notarized=False, image_format="UDZO",
                entitlements=entitlements)
output.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
PY
hdiutil detach "$MOUNT"
MOUNTED=0

mv -n "$WORK/Final.dmg" "$OUTPUT"
[[ ! -f "$WORK/Final.dmg" ]] || die "Output appeared during packaging; existing file preserved."
cp "$WORK/metadata.json" "$OUTPUT.json"
(
    cd "$(dirname "$OUTPUT")"
    shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)
echo "Created: $OUTPUT"
cat "$OUTPUT.sha256"
