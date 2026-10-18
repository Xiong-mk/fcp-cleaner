#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
# Sign a local test app from the inside out, without leaking host entitlements
# into Sparkle's independently running helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() {
    cat <<'HELP'
Usage: ./scripts/sign_adhoc.sh PATH.app
Re-signs the supplied FCP Cleaner test app in place with an ad-hoc signature.
Sparkle helper tools retain their own signing requirements; the host uses the
project entitlements with its actual bundle identifier substituted.
This does not notarize the app.
HELP
}
die() { echo "Error: $*" >&2; exit 1; }
if [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
[[ $# == 1 ]] || { usage >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "This script requires macOS."
APP="$1"
[[ -d "$APP/Contents" && -f "$APP/Contents/Info.plist" ]] || die "Not an app bundle: $APP"
APP="$(cd "$APP" && pwd)"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$FRAMEWORK/Versions/B"
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [[ -e "$SPARKLE/$component" ]] || die "Missing Sparkle component: $component"
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcp-cleaner-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Unlike an Xcode build, codesign does not expand build settings in an
# entitlements file. The installed app may also use a validation bundle ID.
python3 - "$APP/Contents/Info.plist" "$ROOT/FCP Cleaner/FCP Cleaner.entitlements" "$WORK/host.entitlements" <<'PY'
import pathlib, plistlib, sys
info_path, source_path, output_path = map(pathlib.Path, sys.argv[1:])
bundle_id = plistlib.loads(info_path.read_bytes()).get("CFBundleIdentifier")
if not isinstance(bundle_id, str) or not bundle_id or any(c.isspace() for c in bundle_id):
    raise SystemExit("The app has an invalid CFBundleIdentifier")

def resolve(value):
    if isinstance(value, str):
        value = value.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
        value = value.replace("${PRODUCT_BUNDLE_IDENTIFIER}", bundle_id)
        if "$(" in value or "${" in value:
            raise SystemExit(f"Unresolved build setting in entitlement: {value}")
        return value
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve(item) for item in value]
    return value

entitlements = resolve(plistlib.loads(source_path.read_bytes()))
output_path.write_bytes(plistlib.dumps(entitlements))
PY

# Follow Sparkle's sandbox signing order. Do not use --deep when signing:
# Installer / Autoupdate / Updater must not inherit the host sandbox, and only
# Downloader preserves its pre-existing (possibly sandboxed) entitlements.
codesign --force --sign - --options runtime "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --sign - --options runtime --preserve-metadata=entitlements \
    "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --sign - --options runtime "$SPARKLE/Autoupdate"
codesign --force --sign - --options runtime "$SPARKLE/Updater.app"
codesign --force --sign - --options runtime "$FRAMEWORK"
codesign --force --sign - --entitlements "$WORK/host.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Ad-hoc signed: $APP"
