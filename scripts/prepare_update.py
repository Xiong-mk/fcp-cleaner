#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
"""Prepare and verify a Sparkle ZIP and appcast for GitHub Releases / Pages."""

import argparse
import base64
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "build/SourcePackages/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "fcp-cleaner"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def fail(message):
    raise SystemExit(f"Update preparation failed: {message}")


def run(arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        fail(f"{Path(arguments[0]).name} exited with {result.returncode}: {detail}")
    return result.stdout.strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def decode_key(value, size, description):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail(f"{description} is not valid base64")
    if len(decoded) != size:
        fail(f"{description} must contain {size} bytes")
    return decoded


def feed_items(data):
    # An appcast needs no DTD or entities; reject these instead of accepting
    # extra XML features in a previously published feed.
    if re.search(rb"<!\s*(?:DOCTYPE|ENTITY)\b", data, re.IGNORECASE):
        fail("appcast must not contain a DTD or entity declarations")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        fail(f"invalid appcast XML: {error}")
    if root.tag != "rss" or len(root.findall("channel")) != 1:
        fail("appcast must contain one RSS channel")
    return root.findall("./channel/item")


def item_version(item):
    versions = {node.get(SPARKLE + "version") for node in item.findall("enclosure")}
    versions.add(item.findtext(SPARKLE + "version"))
    versions.discard(None)
    versions.discard("")
    if len(versions) != 1:
        fail("an appcast item has a missing or inconsistent build number")
    return versions.pop()


def fingerprint(node):
    # Compare XML meaning rather than namespace prefixes / indentation. The
    # content of description and release notes remains part of the comparison.
    content = node.text or ""
    if len(node) and not content.strip():
        content = ""
    return (node.tag, tuple(sorted(node.attrib.items())), content,
            tuple(fingerprint(child) for child in node))


def verify_signature(archive, signature, public_key, work):
    decode_key(signature, 64, "enclosure Ed25519 signature")
    source = work / "verify.swift"
    source.write_text("""import Foundation
import CryptoKit

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let signature = Data(base64Encoded: arguments[2]),
      let keyData = Data(base64Encoded: arguments[3]) else {
    fatalError("Invalid signature verification arguments")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
guard key.isValidSignature(signature, for: archive) else {
    fputs("Ed25519 signature verification failed\\n", stderr)
    exit(1)
}
print("Ed25519 signature verified")
""")
    run(["/usr/bin/swift", "-module-cache-path", work / "module-cache",
         source, archive, signature, public_key])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Final signed FCP Cleaner.app")
    parser.add_argument("--repository", required=True, help="GitHub repository as OWNER/REPO")
    parser.add_argument("--tag", required=True, help="Release tag, exactly v<CFBundleShortVersionString>")
    parser.add_argument("--output-dir", type=Path, help="Default: build/publish/TAG; existing outputs are refused")
    args = parser.parse_args()
    if sys.platform != "darwin":
        fail("this script requires macOS, Xcode / Swift, and the Sparkle tools")
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}", args.repository):
        fail("--repository must be OWNER/REPO")
    owner, repository = args.repository.split("/")
    if repository in {".", ".."} or not re.fullmatch(r"v[A-Za-z0-9][A-Za-z0-9_.+-]*", args.tag):
        fail("invalid repository name or release tag")
    app = args.app.resolve()
    info_path = app / "Contents/Info.plist"
    if not app.is_dir() or app.suffix != ".app" or not info_path.is_file():
        fail("--app must identify an existing .app bundle")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read the App Info.plist: {error}")
    required = ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier", "CFBundleExecutable", "SUPublicEDKey")
    if any(not isinstance(info.get(key), str) or not info[key] for key in required):
        fail("the App is missing a required version, identifier, executable, or Sparkle public key")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if args.tag != f"v{version}":
        fail(f"tag {args.tag} does not match App version {version}")
    if Path(info["CFBundleExecutable"]).name != info["CFBundleExecutable"]:
        fail("CFBundleExecutable must be a filename")
    feed_url = f"https://{owner}.github.io/{repository}/appcast.xml"
    if info.get("SUFeedURL") != feed_url:
        fail(f"the App SUFeedURL must be {feed_url}")
    public_key = info["SUPublicEDKey"]
    decode_key(public_key, 32, "App SUPublicEDKey")
    for name in ("generate_keys", "generate_appcast"):
        if not os.access(TOOLS / name, os.X_OK):
            fail(f"missing Sparkle tool {name}; resolve packages into build/SourcePackages first")
    if run([TOOLS / "generate_keys", "--account", ACCOUNT, "-p"]) != public_key:
        fail(f"the App public key does not match the Keychain public key for account {ACCOUNT}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = sorted(run(["/usr/bin/lipo", "-archs", executable]).split())
    if not architectures or not set(architectures).issubset({"arm64", "x86_64"}):
        fail(f"unsupported or missing App architectures: {architectures}")

    published_feed = ROOT / "docs/appcast.xml"
    original_feed = published_feed.read_bytes() if published_feed.exists() else None
    old_items = feed_items(original_feed) if original_feed is not None else []
    if any(item_version(item) == build for item in old_items):
        fail(f"build {build} already exists in docs/appcast.xml; increment CFBundleVersion")
    output = (args.output_dir or ROOT / "build/publish" / args.tag).resolve()
    updates = output / "updates"
    archive_name = f"FCP-Cleaner-{version}.zip"
    archive = updates / archive_name
    generated_feed = updates / "appcast.xml"
    metadata_path = output / f"FCP-Cleaner-{version}.json"
    checksum_path = output / f"FCP-Cleaner-{version}.sha256"
    if any(path.exists() for path in (updates, metadata_path, checksum_path)):
        fail("output already exists; choose a new --output-dir (no files were overwritten)")
    updates.mkdir(parents=True)
    if original_feed is not None:
        generated_feed.write_bytes(original_feed)
    print(f"Creating {archive_name} from App {version} ({build}); {', '.join(architectures)}")
    run(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, archive])
    archive_hash = sha256(archive)
    release_url = f"https://github.com/{args.repository}/releases/tag/{args.tag}"
    download_prefix = f"https://github.com/{args.repository}/releases/download/{quote(args.tag, safe='')}/"
    run([TOOLS / "generate_appcast", "--account", ACCOUNT,
         "--download-url-prefix", download_prefix, "--maximum-deltas", "0",
         "--maximum-versions", "0", "--link", release_url,
         "-o", generated_feed, updates])
    generated_data = generated_feed.read_bytes()
    new_items = feed_items(generated_data)
    old_entries = Counter(fingerprint(item) for item in old_items)
    new_entries = Counter(fingerprint(item) for item in new_items)
    if old_entries - new_entries:
        fail("the generated appcast removed or changed historical items; docs/appcast.xml was preserved")
    if len(new_items) != len(old_items) + 1:
        fail("the generated appcast must add exactly one item; docs/appcast.xml was preserved")
    current_items = [item for item in new_items if item_version(item) == build]
    if len(current_items) != 1:
        fail("the generated appcast must contain exactly one item for the App build")
    item = current_items[0]
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        fail("the new appcast item must contain exactly one full update enclosure")
    enclosure = enclosures[0]
    short_version = item.findtext(SPARKLE + "shortVersionString") or enclosure.get(SPARKLE + "shortVersionString")
    if short_version != version:
        fail("appcast display version differs from the App")
    expected_url = download_prefix + quote(archive_name, safe="")
    if enclosure.get("url") != expected_url or enclosure.get("length") != str(archive.stat().st_size):
        fail("appcast enclosure URL or byte length differs from the prepared ZIP")
    signature = enclosure.get(SPARKLE + "edSignature")
    with tempfile.TemporaryDirectory(prefix="fcp-update-verify-", dir=output) as temporary:
        work = Path(temporary)
        verify_signature(archive, signature, public_key, work)
        extracted = work / "extracted"
        run(["/usr/bin/ditto", "-x", "-k", archive, extracted])
        archived_app = extracted / app.name
        archived_info_path = archived_app / "Contents/Info.plist"
        if not archived_info_path.is_file() or plistlib.loads(archived_info_path.read_bytes()) != info:
            fail("the App Info.plist in the final ZIP differs from the verified App")
        archived_binary = archived_app / "Contents/MacOS" / info["CFBundleExecutable"]
        archived_architectures = sorted(run(["/usr/bin/lipo", "-archs", archived_binary]).split())
        if archived_architectures != architectures:
            fail("the App architectures in the final ZIP differ from the verified App")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", archived_app])
    if sha256(archive) != archive_hash:
        fail("the ZIP changed during generation or verification")
    # Avoid replacing a feed edited by another process while packaging ran.
    current_feed = published_feed.read_bytes() if published_feed.exists() else None
    if current_feed != original_feed:
        fail("docs/appcast.xml changed during preparation; its current contents were preserved")

    metadata = dict(version=version, build=build, bundle_id=info["CFBundleIdentifier"],
                    minimum_macos=info.get("LSMinimumSystemVersion"), architectures=architectures,
                    repository=args.repository, tag=args.tag, feed_url=feed_url,
                    release_url=release_url, archive=f"updates/{archive_name}",
                    download_url=expected_url, length=archive.stat().st_size,
                    sha256=archive_hash, public_ed_key=public_key, ed_signature=signature,
                    archive_app_verified=True, code_signature_verified=True,
                    ed25519_signature_verified=True,
                    historical_items_preserved=len(old_items),
                    appcast_sha256=hashlib.sha256(generated_data).hexdigest())
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    checksum_path.write_text(f"{archive_hash}  updates/{archive_name}\n"
                             f"{metadata['appcast_sha256']}  updates/appcast.xml\n")
    published_feed.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".appcast-", suffix=".xml", dir=published_feed.parent, delete=False) as temporary:
        temporary.write(generated_data)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.replace(published_feed)
    finally:
        temporary_path.unlink(missing_ok=True)
    print(f"Prepared {archive}; SHA-256 {archive_hash}")
    print(f"Verified Ed25519 signature; preserved {len(old_items)} historical items")
    print(f"Updated {published_feed}; upload the unchanged ZIP before publishing this feed")
    print(f"Metadata: {metadata_path}; checksums: {checksum_path}")


if __name__ == "__main__":
    main()
