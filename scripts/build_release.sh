#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
# Build from a private neutral workspace, keeping dSYMs outside distributed apps.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/releases/FCP Cleaner.app"
BUILD_NUMBER=""
usage() {
    cat <<'HELP'
Usage: ./scripts/build_release.sh [--output PATH.app] [--build-number NUMBER]
Builds a universal, ad-hoc signed Release in a private neutral temporary workspace.
Keeps the build log and dSYM beside the output app; these are not release assets.
Existing outputs are refused. Requires resolved Sparkle in build/SourcePackages.
HELP
}
die() { echo "Error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|--build-number)
            [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
            if [[ "$1" == --output ]]; then OUTPUT="$2"; else BUILD_NUMBER="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || die "This script requires macOS."
[[ "$OUTPUT" == *.app ]] || die "Output must end with .app"
[[ -z "$BUILD_NUMBER" || "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer"
[[ -d "$ROOT/build/SourcePackages/artifacts/sparkle" ]] || die "Resolve packages into build/SourcePackages first"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
[[ ! -e "$OUTPUT" && ! -e "$OUTPUT.dSYM" && ! -e "$OUTPUT.build.log" ]] || die "Output or private build evidence exists"
WORK="$(mktemp -d /private/tmp/fcp-cleaner-build.XXXXXX)"
chmod 700 "$WORK"
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$result" == 0 ]]; then
        rm -rf "$WORK"
    else
        echo "Build or privacy gate failed; private workspace retained for diagnosis: $WORK" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$ROOT" "$WORK/source" <<'PY'
import importlib.util, pathlib, shutil, sys
root, destination = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("release_inputs", root / "scripts/prepare_release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
files = module.public_files()
module.audit(files)
for source in files:
    target = destination / source.relative_to(root)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if source.suffix == ".sh" else 0o644)
PY
# Copy already locked dependencies into the same neutral root. Do not rebuild
# from a symlink to a personal directory or distribute dependency dSYMs.
ditto --noextattr --norsrc --noqtn "$ROOT/build/SourcePackages" "$WORK/SourcePackages"
SETTINGS=(ONLY_ACTIVE_ARCH=NO "ARCHS=arm64 x86_64")
if [[ -n "$BUILD_NUMBER" ]]; then SETTINGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER"); fi
if ! xcodebuild -project "$WORK/source/FCP Cleaner/FCP Cleaner.xcodeproj" \
    -scheme "FCP Cleaner" -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$WORK/DerivedData" -clonedSourcePackagesDirPath "$WORK/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO DEVELOPMENT_TEAM= "${SETTINGS[@]}" build \
    > "$OUTPUT.build.log" 2>&1; then
    tail -60 "$OUTPUT.build.log" >&2
    die "Build failed; inspect the private .build.log beside the requested output"
fi
APP="$WORK/DerivedData/Build/Products/Release/FCP Cleaner.app"
"$ROOT/scripts/sign_adhoc.sh" "$APP"
python3 "$ROOT/scripts/privacy_scan.py" release "$APP"
ditto --noextattr --norsrc --noqtn "$APP" "$OUTPUT"
ditto --noextattr --norsrc --noqtn "$WORK/DerivedData/Build/Products/Release/FCP Cleaner.app.dSYM" "$OUTPUT.dSYM"
codesign --verify --deep --strict --verbose=2 "$OUTPUT"
echo "Created universal Release app; private dSYM and build log retained separately."
