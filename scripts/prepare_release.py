#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
"""Audit the public source boundary and create a deterministic source archive."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PROJECT = Path("FCP Cleaner")
APP = PROJECT / "FCP Cleaner"
LICENSE_HASH = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
SPARKLE_VERSION = "2.10.0"
SPARKLE_REVISION = "eef1a539a373c1f1a320624b1130fc5de7b2e100"
SPARKLE_LICENSE_HASH = "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
VERSION = "0.1.0"
ROOT_FILES = (
    ".gitignore", ".gitattributes", ".gitleaks.toml", ".githooks/pre-commit", "LICENSE", "README.md", "CONTRIBUTING.md",
    "THIRD_PARTY_NOTICES.md", "CHANGELOG.md",
    "docs/architecture.md", "docs/security.md", "docs/release.md",
    "docs/license-provenance.md", "docs/task-seven-validation.md",
    "docs/images/cache-results.png", "scripts/test.sh", "scripts/prepare_release.py",
    "Resources/DMG/background.png", "Resources/DMG/安装说明.txt",
    "docs/appcast.xml", "docs/.nojekyll", "docs/index.html",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def public_files():
    """Allowlist source, resources, documentation and build inputs, not the workspace."""
    files = [ROOT / p for p in ROOT_FILES]
    for folder, extensions in (
        (APP, {".swift", ".json", ".png", ".txt"}),
        (PROJECT / "FCPCleanerTests", {".swift"}),
        (Path("docs"), {".md", ".png"}),
        (Path("scripts"), {".py", ".sh", ".swift"}),
    ):
        files.extend(p for p in (ROOT / folder).rglob("*") if p.is_file() and p.suffix in extensions)
    project_folder = ROOT / PROJECT / "FCP Cleaner.xcodeproj"
    files.append(project_folder / "project.pbxproj")
    files.append(project_folder / "project.xcworkspace/contents.xcworkspacedata")
    files.append(project_folder / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    files.extend((project_folder / "xcshareddata/xcschemes").glob("*.xcscheme"))
    files.append(ROOT / PROJECT / "FCP Cleaner.entitlements")
    files.append(ROOT / PROJECT / "Info.plist")
    files.extend((ROOT / PROJECT / "Config").glob("*.xcconfig"))
    return sorted(set(files))


def audit(files):
    from privacy_scan import scan_data, safe_label
    errors = []
    for p in files:
        if not p.is_file() or p.is_symlink() or any(parent.is_symlink() for parent in p.parents):
            errors.append(f"Missing file or symbolic link: {safe_label(p.relative_to(ROOT))}")
            continue
        data = p.read_bytes()
        # Scan only the exact source-archive allowlist, including untracked inputs.
        for finding in scan_data(str(p.relative_to(ROOT)), data):
            errors.append(f"Privacy gate: {safe_label(finding.path)}: {finding.rule} (value redacted)")
        if p.suffix in {".swift", ".py", ".sh"}:
            header = data.decode("utf-8").splitlines()[:5]
            if not any("SPDX-License-Identifier: GPL-3.0-or-later" in line for line in header):
                errors.append(f"Missing SPDX: {safe_label(p.relative_to(ROOT))}")
            if not any("Copyright (C)" in line for line in header):
                errors.append(f"Missing copyright: {safe_label(p.relative_to(ROOT))}")
        user_paths = re.findall(rb"/Users/([A-Za-z0-9._-]+)/", data) if p.suffix != ".png" else []
        if any(name not in {b"demo", b"test"} for name in user_paths):
            errors.append(f"Private user path: {safe_label(p.relative_to(ROOT))}")
        mounts = re.findall(rb"/" + rb"Volumes/([^/\n\"']+)", data) if p.suffix != ".png" else []
        fictional_mounts = {s.encode() for s in ("External SSD", "External HDD", "外接固态硬盘", "演示磁盘")}
        if any(name not in fictional_mounts and not name.startswith(b"Mock ") for name in mounts):
            errors.append(f"Volume path outside the fictional fixture names: {safe_label(p.relative_to(ROOT))}")
        if p.suffix != ".png" and re.search(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", data):
            errors.append(f"Private key: {safe_label(p.relative_to(ROOT))}")
    license_data = (ROOT / "LICENSE").read_bytes()
    if digest(license_data) != LICENSE_HASH:
        errors.append("LICENSE differs from the downloaded official GNU GPLv3 text")
    legal = ROOT / APP / "Resources/Legal"
    for bundled, original in (("LICENSE.txt", "LICENSE"), ("THIRD_PARTY_NOTICES.txt", "THIRD_PARTY_NOTICES.md")):
        if (legal / bundled).read_bytes() != (ROOT / original).read_bytes():
            errors.append(f"Bundled {bundled} differs from {original}")
    sparkle_license = legal / "Sparkle-LICENSE.txt"
    if not sparkle_license.is_file() or digest(sparkle_license.read_bytes()) != SPARKLE_LICENSE_HASH:
        errors.append(f"Sparkle-LICENSE.txt must contain the unmodified Sparkle {SPARKLE_VERSION} license")
    pbx = ROOT / PROJECT / "FCP Cleaner.xcodeproj/project.pbxproj"
    package_lock = pbx.parent / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    try:
        pins = json.loads(package_lock.read_text())["pins"]
        sparkle_pins = [pin for pin in pins if pin.get("identity") == "sparkle"]
        if (
            len(sparkle_pins) != 1
            or sparkle_pins[0].get("location") != "https://github.com/sparkle-project/Sparkle"
            or sparkle_pins[0].get("state") != {"revision": SPARKLE_REVISION, "version": SPARKLE_VERSION}
        ):
            errors.append(f"Package.resolved must pin the reviewed Sparkle {SPARKLE_VERSION} revision")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        errors.append("Missing or invalid Swift Package Manager dependency lockfile")
    settings = pbx.read_text()
    ids = set(re.findall(r"^\s*([A-Fa-f0-9]+) /\* .*? \*/ = \{", settings, re.M))
    scheme = pbx.parent / "xcshareddata/xcschemes/FCP Cleaner.xcscheme"
    for node in ET.parse(scheme).iter("BuildableReference"):
        if node.attrib["BlueprintIdentifier"] not in ids:
            errors.append("Shared scheme references a missing target")
    if "isa = PBXTargetDependency;" not in settings or "TestTargetID = " not in settings:
        errors.append("Tests must explicitly depend on their app host")
    if set(re.findall(r"MARKETING_VERSION = ([^;]+);", settings)) != {VERSION}:
        errors.append("Project version differs from source release version")
    # Keep these local inputs out of both git add and git archive.
    for name in ("inspection", "local-evidence", "大拍档垃圾清理技术分析.md"):
        if f"/{name}" not in (ROOT / ".gitignore").read_text() or f"/{name} export-ignore" not in (ROOT / ".gitattributes").read_text():
            errors.append(f"Missing repository/export exclusion: {safe_label(name)}")
    # Refuse an archive if tracked publishable content would be silently omitted.
    git_root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True, text=True)
    # Downloaded source archives have no .git; do not inspect an enclosing repository.
    tracked = []
    if git_root.returncode == 0 and Path(git_root.stdout.strip()).resolve() == ROOT:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    chosen = {str(p.relative_to(ROOT)) for p in files}
    for name in filter(None, tracked):
        if name not in chosen:
            errors.append(f"Tracked file outside the public allowlist: {safe_label(name)}")
    if errors:
        raise SystemExit("Release audit failed:\n- " + "\n- ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Audit only; do not create an archive")
    parser.add_argument("--output", type=Path, default=ROOT / f"build/releases/FCP-Cleaner-v{VERSION}-source.zip")
    args = parser.parse_args()
    files = public_files()
    audit(files)
    print(f"Release audit passed: {len(files)} public files; GPL-3.0-or-later; version {VERSION}.")
    if args.check:
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in files}
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for p in files:
            entry = zipfile.ZipInfo(f"FCP-Cleaner-{VERSION}/{p.relative_to(ROOT)}", (1980, 1, 1, 0, 0, 0))
            mode = 0o100755 if p.suffix == ".sh" or p.relative_to(ROOT) == Path(".githooks/pre-commit") else 0o100644
            entry.external_attr = mode << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, p.read_bytes())
    args.output.with_suffix(".manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    checksum = digest(args.output.read_bytes())
    args.output.with_suffix(".sha256").write_text(f"{checksum}  {args.output.name}\n")
    print(f"Created {args.output.name}; SHA-256 {checksum}")


if __name__ == "__main__":
    main()
