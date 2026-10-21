#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
"""Fail closed on sensitive staged content and release payloads; never print matches."""

import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import stat
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

PUBLIC_ED_KEY = "5dpdTSmSHWw0JCDqq9gOuBLNkXEidjNUGkTorlnszso="
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_FILE = 256 * 1024 * 1024
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024
GITLEAKS_INPUTS = []
ROOT = Path(__file__).resolve().parent.parent
PRIVATE_EXTENSIONS = {".p8", ".p12", ".pfx", ".key", ".pem", ".log", ".trace", ".crash", ".ips", ".xcactivitylog"}
PRIVATE_PARTS = {".git", ".secrets", "xcuserdata", "DerivedData", ".xcresult", ".xcarchive", "__MACOSX", "local-evidence", "inspection"}
EVIDENCE_PREFIXES = ("fcp-cleaner-promo/evidence/",)
# These are the existing synthetic fixtures, not the machine running this tool.
FIXTURE_USERS = {"demo", "test"}
FIXTURE_VOLUMES = {"External SSD", "External HDD", "外接固态硬盘", "演示磁盘"}
EMAIL = re.compile(r"(?<![\w.+-])[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![\w.-])")
HOME_PATH = re.compile(r"(?:/(?:Users|home)/([^/\r\n\x00\"'<>]+)(?=/|$|[\r\n\x00\"'<>])|[A-Za-z]:\\Users\\([^\\\r\n\x00\"'<>]+)(?=\\|$|[\r\n\x00\"'<>]))")
VOLUME_PATH = re.compile(r"/" + r"Volumes/([^/\r\n\x00\"']+)")
TEMP_PATH = re.compile(r"/(?:private/)?var/folders/[A-Za-z0-9_/-]+")
TOKEN_PATTERNS = {
    "github-token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,255}|github_pat_[A-Za-z0-9_]{40,255})\b"),
    "private-key": re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*(?:PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "api-token": re.compile(r"\b(?:AIza[0-9A-Za-z_-]{35}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b"),
    "authenticated-url": re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/@\"'<>:]+:[^\s/@\"'<>]+@"),
    "credential-url": re.compile(r"[?&](?:access_token|auth_token|api_key|apikey|password|secret|token)=[^\s&#\"'<>]{8,}", re.I),
}
SECRET_ASSIGNMENT = re.compile(
    r"\b(?:[A-Za-z0-9_]*(?:password|passwd|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?(?:ed[_-]?)?key|sparkle[_-]?(?:secret|private)[_-]?key)[A-Za-z0-9_]*)"
    r"[\"']?\s*[:=]\s*[\"']([^\"'\r\n]{4,})[\"']", re.I)
SECRET_UNQUOTED = re.compile(
    r"\b(?:password|passwd|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?(?:ed[_-]?)?key|sparkle[_-]?(?:secret|private)[_-]?key)"
    r"\s*[:=]\s*([A-Za-z0-9_+/=.!-]{4,})\s*(?:$|[;#])", re.I | re.M)
BASE64_KEY = re.compile(r"(?<![A-Za-z0-9+/])(?:[A-Za-z0-9+/]{43}=|[A-Za-z0-9+/]{86}==)(?![A-Za-z0-9+/=])")
PLACEHOLDER = re.compile(r"^(?:\$[({]|<|REDACTED|CHANGEME|YOUR_|example|placeholder|dummy|test-|not-a-|\\|\{)", re.I)


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    rule: str
    line: int = 0


def safe_label(value):
    value = str(value)
    for pattern in TOKEN_PATTERNS.values():
        value = pattern.sub("<redacted-credential>", value)
    value = BASE64_KEY.sub("<redacted-key-material>", value)
    value = TEMP_PATH.sub("<redacted-temporary-path>", value)
    value = EMAIL.sub("<redacted-email>", value)
    value = re.sub(r"[^/]+\.xcuserdatad", "<redacted-user>.xcuserdatad", value)
    return re.sub(r"(?:/(?:Users|home)/|[A-Za-z]:\\Users\\)[^/\\\s]+", "<redacted-home>", value)


def permitted_email(value):
    local, domain = value.rsplit("@", 1)
    domain = domain.lower()
    return (value == "noreply@github.com" or domain == "users.noreply.github.com" and bool(re.fullmatch(r"(?:\d+\+)?[A-Za-z0-9-]+", local))
            or any(domain == suffix or domain.endswith("." + suffix) for suffix in {"example.com", "example.org", "example.net", "example.invalid"})
            or domain.endswith(".invalid"))


def filename_findings(label, release=False):
    path = PurePosixPath(label)
    parts = set(path.parts)
    lower_name = path.name.lower()
    findings = []
    private = (path.suffix.lower() in PRIVATE_EXTENSIONS or bool(parts & PRIVATE_PARTS)
               or any(p.endswith((".xcresult", ".xcarchive", ".dSYM")) for p in path.parts)
               or lower_name in {".env", "id_rsa", "id_ed25519", "id_ecdsa", ".netrc", ".npmrc"}
               or lower_name.startswith((".env.", ".secrets.", "._", "codex-session-"))
               or label.startswith(EVIDENCE_PREFIXES)
               or (release and any(p in {".codex", ".agents", "node_modules"} for p in path.parts)))
    if private:
        findings.append(Finding(label, "private-development-file"))
    for rule, pattern in TOKEN_PATTERNS.items():
        if pattern.search(label):
            findings.append(Finding(label, rule + "-in-filename"))
    public_icon = ("Assets.xcassets" in path.parts and "AppIcon.appiconset" in path.parts
                   and re.fullmatch(r"icon_[0-9]+x[0-9]+@[23]x\.png", path.name))
    if not public_icon and any(not permitted_email(match.group()) for match in EMAIL.finditer(label)):
        findings.append(Finding(label, "personal-email-in-filename"))
    if any(match.group() != PUBLIC_ED_KEY for match in BASE64_KEY.finditer(label)):
        findings.append(Finding(label, "unclassified-key-material-in-filename"))
    for match in HOME_PATH.finditer(label):
        if (match.group(1) or match.group(2)) not in FIXTURE_USERS:
            findings.append(Finding(label, "personal-path-in-filename"))
    return findings


def public_values(label, data):
    """Whitelist values only in their actual public schema, never whole files."""
    values = {PUBLIC_ED_KEY}
    try:
        if PurePosixPath(label).name == "appcast.xml":
            if re.search(rb"<!\s*(?:DOCTYPE|ENTITY)\b", data, re.I):
                return values
            root = ET.fromstring(data)
            for enclosure in root.findall("./channel/item/enclosure"):
                value = enclosure.get(SPARKLE + "edSignature", "")
                if len(base64.b64decode(value, validate=True)) == 64:
                    values.add(value)
        elif PurePosixPath(label).suffix == ".json":
            info = json.loads(data)
            if isinstance(info, dict) and info.get("public_ed_key") == PUBLIC_ED_KEY:
                signature = info.get("ed_signature", "")
                if len(base64.b64decode(signature, validate=True)) == 64:
                    values.add(signature)
        elif label.endswith("_CodeSignature/CodeResources"):
            resources = plistlib.loads(data)
            for group in ("files", "files2"):
                for entry in resources.get(group, {}).values():
                    hashes = entry.values() if isinstance(entry, dict) else [entry]
                    for value in hashes:
                        if isinstance(value, bytes) and len(value) in {20, 32}:
                            values.add(base64.b64encode(value).decode())
    except (ValueError, TypeError, KeyError, ET.ParseError, plistlib.InvalidFileException):
        pass
    return values


def scan_data(label, data, release=False):
    findings = filename_findings(label, release)
    if len(data) > MAX_FILE:
        return findings + [Finding(label, "file-exceeds-scan-limit")]
    allowed = public_values(label, data)
    GITLEAKS_INPUTS.append((label, data))
    approved_license = (label.endswith("Sparkle-LICENSE.txt") and hashlib.sha256(data).hexdigest() == "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe")
    texts = [data.decode("utf-8", errors="replace")]
    # Finder records, binary plists and Windows strings may use either UTF-16 order.
    texts.extend(data[offset:].decode(encoding, errors="ignore")
                 for encoding in ("utf-16-le", "utf-16-be") for offset in (0, 1))
    for text in texts:
        text = re.sub(r"(?:icon_|mac_|icon)[A-Za-z0-9_-]*[0-9]+x[0-9]+@[23]x\.png", "<public-asset-filename>", text)
        if label.endswith("UpdateConfigurationTests.swift"):
            text = text.replace("https" + "://" + "user:password" + "@" + "updates.example.com/appcast.xml", "<invalid-url-test-fixture>")
        if label.endswith("prepare_release.py"):
            text = text.replace('rb"' + '/' + 'Users/([A-Za-z0-9._-]+)/"', "<path-regex>")
        for rule, pattern in TOKEN_PATTERNS.items():
            for match in pattern.finditer(text):
                findings.append(Finding(label, rule, text.count("\n", 0, match.start()) + 1))
        for match in HOME_PATH.finditer(text):
            if (match.group(1) or match.group(2)) not in FIXTURE_USERS:
                findings.append(Finding(label, "personal-home-path", text.count("\n", 0, match.start()) + 1))
        for match in VOLUME_PATH.finditer(text):
            value = match.group(1)
            if value not in FIXTURE_VOLUMES and not value.startswith("Mock "):
                findings.append(Finding(label, "personal-volume-path", text.count("\n", 0, match.start()) + 1))
        for match in TEMP_PATH.finditer(text):
            findings.append(Finding(label, "private-temporary-path", text.count("\n", 0, match.start()) + 1))
        for match in EMAIL.finditer(text):
            if not approved_license and not permitted_email(match.group()):
                findings.append(Finding(label, "personal-email", text.count("\n", 0, match.start()) + 1))
        for match in [*SECRET_ASSIGNMENT.finditer(text), *SECRET_UNQUOTED.finditer(text)]:
            value = match.group(1)
            if value not in allowed and not PLACEHOLDER.match(value) and not any(v in value for v in ("\\n", "\\r", "[^", "(?", '"', "'")):
                findings.append(Finding(label, "credential-assignment", text.count("\n", 0, match.start()) + 1))
        for match in BASE64_KEY.finditer(text):
            value = match.group()
            if value not in allowed:
                findings.append(Finding(label, "unclassified-key-material", text.count("\n", 0, match.start()) + 1))
    return sorted(set(findings))


def git(arguments, root):
    result = subprocess.run(["git", *arguments], cwd=root, capture_output=True)
    if result.returncode:
        raise RuntimeError("git-command-failed")
    return result.stdout


def scan_index(root):
    if git(["ls-files", "--unmerged", "-z"], root):
        return [Finding("<index>", "unmerged-index")], 0
    names = {name for name in git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z", "--"], root).split(b"\0") if name}
    findings = []
    count = 0
    for record in git(["ls-files", "--stage", "-z"], root).split(b"\0"):
        if not record:
            continue
        meta, name = record.split(b"\t", 1)
        if name not in names:
            continue
        mode, oid, stage = meta.split()
        label = name.decode("utf-8", errors="replace")
        if mode == b"160000":
            findings.append(Finding(label, "submodule-requires-independent-review"))
            continue
        data = git(["cat-file", "blob", oid.decode()], root)
        findings.extend(scan_data(label, data))
        count += 1
    return sorted(set(findings)), count


def scan_xattrs(path, label):
    findings = []
    try:
        if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
            values = [os.getxattr(path, name, follow_symlinks=False)
                      for name in os.listxattr(path, follow_symlinks=False)]
        elif sys.platform == "darwin":
            listed = subprocess.run(["/usr/bin/xattr", "-s", str(path)], capture_output=True)
            if listed.returncode:
                raise OSError("xattr-list-failed")
            values = []
            for name in listed.stdout.decode().splitlines():
                result = subprocess.run(["/usr/bin/xattr", "-s", "-px", name, str(path)], capture_output=True)
                if result.returncode:
                    raise OSError("xattr-read-failed")
                values.append(bytes.fromhex(result.stdout.decode()))
        else:
            raise OSError("xattr-api-unavailable")
        for value in values:
            findings.extend(scan_data(label + "::<xattr>", value, release=True))
    except (OSError, ValueError):
        findings.append(Finding(label, "extended-attribute-read-failed"))
    return findings


def scan_zip(path, label):
    findings = []
    with zipfile.ZipFile(path) as archive:
        total = 0
        links = {PurePosixPath(entry.filename) for entry in archive.infolist()
                 if stat.S_ISLNK(entry.external_attr >> 16)}
        seen = set()
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            child = label + "!/" + entry.filename
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                findings.append(Finding(child, "unsafe-archive-entry"))
                continue
            if name in seen:
                findings.append(Finding(child, "duplicate-archive-entry"))
            seen.add(name)
            if any(parent in links for parent in name.parents):
                findings.append(Finding(child, "archive-entry-through-symlink"))
            findings.extend(filename_findings(child, release=True))
            if entry.is_dir():
                continue
            total += entry.file_size
            if entry.file_size > MAX_FILE or total > MAX_ARCHIVE:
                findings.append(Finding(child, "archive-exceeds-scan-limit"))
                continue
            data = archive.read(entry)
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = data.decode("utf-8", errors="replace")
                resolved = posixpath.normpath(posixpath.join(str(name.parent), target))
                if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    findings.append(Finding(child, "external-archive-symlink"))
            findings.extend(scan_data(child, data, release=True))
            if entry.filename.lower().endswith(".zip"):
                findings.append(Finding(child, "nested-archive-requires-independent-review"))
    return findings


def scan_tree(path, release=False):
    findings = []
    paths = [path, *sorted(path.rglob("*"))] if path.is_dir() else [path]
    root = path if path.is_dir() else path.parent
    for child in paths:
        label = str(child.relative_to(root)) if path.is_dir() and child != root else child.name
        if release:
            findings.extend(scan_xattrs(child, label))
        if child.is_symlink():
            target = os.readlink(child)
            findings.extend(scan_data(label, target.encode(), release))
            if release and not (target == "/Applications" and child == root / "Applications"):
                try:
                    child.resolve().relative_to(root.resolve())
                except ValueError:
                    findings.append(Finding(label, "external-symlink"))
            continue
        if child.is_file():
            if child.stat().st_size > MAX_FILE:
                findings.append(Finding(label, "file-exceeds-scan-limit"))
                continue
            if release and child.suffix.lower() == ".dmg":
                # Parse the mounted filesystem, not compressed bytes as text.
                findings.extend(filename_findings(label, release=True))
                findings.extend(scan_dmg(child))
                continue
            findings.extend(scan_data(label, child.read_bytes(), release))
            if release:
                if child.suffix.lower() == ".zip":
                    findings.extend(scan_zip(child, label))
    return sorted(set(findings))


def scan_dmg(path):
    if sys.platform != "darwin":
        return [Finding(path.name, "dmg-requires-macos")]
    with tempfile.TemporaryDirectory(prefix="fcp-privacy-dmg-", dir="/private/tmp") as work:
        mount = Path(work) / "volume"
        mount.mkdir()
        result = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), "-plist", str(path.resolve())], capture_output=True)
        if result.returncode:
            return [Finding(path.name, "dmg-mount-failed")]
        try:
            return scan_tree(mount, release=True)
        finally:
            result = subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True)
            if result.returncode:
                raise RuntimeError("dmg-detach-failed")


def verify_metadata(paths, appcast, checksums):
    """Verify attachment digests and the update signature without reading a private key."""
    findings = []
    if not appcast and not checksums:
        return findings
    files = [p for p in paths if p.is_file()]
    for path in paths:
        if path.is_dir():
            files.extend(p for p in path.rglob("*") if p.is_file() and not p.is_symlink()
                         and not any(part.endswith((".app", ".framework")) for part in p.relative_to(path).parts))
    by_name = {}
    for path in files:
        if path.name in by_name and by_name[path.name].resolve() != path.resolve():
            findings.append(Finding(path.name, "ambiguous-attachment-name"))
        by_name[path.name] = path
    verified = set()
    for checksum in checksums:
        for line in checksum.read_text().splitlines():
            if not line.strip():
                continue
            match = re.fullmatch(r"([a-fA-F0-9]{64})\s+\*?(.+)", line)
            if not match:
                findings.append(Finding(checksum.name, "invalid-checksum-line"))
                continue
            name = PurePosixPath(match.group(2)).name
            attachment = by_name.get(name)
            if attachment is None or hashlib.sha256(attachment.read_bytes()).hexdigest() != match.group(1).lower():
                findings.append(Finding(name, "attachment-checksum-mismatch"))
            else:
                verified.add(name)
    if checksums:
        for path in files:
            if path.suffix.lower() in {".zip", ".dmg"} and path.name not in verified:
                findings.append(Finding(path.name, "attachment-checksum-missing"))
    if appcast:
        data = appcast.read_bytes()
        if re.search(rb"<!\s*(?:DOCTYPE|ENTITY)\b", data, re.I):
            return findings + [Finding(appcast.name, "unsafe-appcast-xml")]
        root = ET.fromstring(data)
        items = root.findall("./channel/item")
        if root.tag != "rss" or len(root.findall("channel")) != 1 or not items:
            return findings + [Finding(appcast.name, "invalid-appcast-structure")]
        for item in items:
            enclosures = item.findall("enclosure")
            if len(enclosures) != 1:
                findings.append(Finding(appcast.name, "invalid-appcast-enclosures"))
                continue
            enclosure = enclosures[0]
            url = enclosure.get("url", "")
            from urllib.parse import unquote, urlparse
            parsed = urlparse(url)
            name = PurePosixPath(unquote(parsed.path)).name
            attachment = by_name.get(name)
            if parsed.scheme != "https" or attachment is None or enclosure.get("length") != str(attachment.stat().st_size):
                findings.append(Finding(name or appcast.name, "appcast-attachment-mismatch"))
                continue
            signature = enclosure.get(SPARKLE + "edSignature", "")
            try:
                from prepare_update import verify_signature
                with tempfile.TemporaryDirectory(prefix="fcp-signature-check-", dir="/private/tmp") as work:
                    verify_signature(attachment, signature, PUBLIC_ED_KEY, Path(work))
            except (Exception, SystemExit):
                findings.append(Finding(name, "sparkle-signature-verification-failed"))
    return findings


def scan_history(root):
    """Scan all reachable objects and author/committer/tagger records without values."""
    findings = []
    records = git(["rev-list", "--objects", "--all"], root).splitlines()
    records.extend(git(["for-each-ref", "--format=%(objectname)"], root).splitlines())
    seen = set()
    count = 0
    for record in records:
        oid, _, name = record.partition(b" ")
        if oid in seen:
            continue
        seen.add(oid)
        kind = git(["cat-file", "-t", oid.decode()], root).strip()
        if kind not in {b"blob", b"commit", b"tag"}:
            continue
        label = name.decode(errors="replace") or "<" + kind.decode() + ":" + oid[:12].decode() + ">"
        data = git(["cat-file", kind.decode(), oid.decode()], root)
        findings.extend(scan_data(label, data))
        count += 1
    return sorted(set(findings)), count



def scan_gitleaks(binary=None, repo=None):
    """Run the default vendor rules against exact bytes already selected by this scan."""
    configured = subprocess.run(["git", "config", "--path", "--get", "privacy.gitleaksPath"],
                                cwd=repo or Path.cwd(), capture_output=True, text=True)
    local_binary = configured.stdout.strip() if configured.returncode == 0 else None
    executable = os.environ.get("GITLEAKS_BIN") or binary or local_binary or shutil.which("gitleaks")
    if not executable:
        return [Finding("<gitleaks>", "gitleaks-required-set-GITLEAKS_BIN")]
    findings = []
    with tempfile.TemporaryDirectory(prefix="fcp-gitleaks-", dir="/private/tmp") as work:
        folder = Path(work) / "input"
        folder.mkdir()
        labels = {}
        for index, (label, data) in enumerate(GITLEAKS_INPUTS):
            # Binary payload privacy is handled byte-for-byte above. Gitleaks handles
            # the textual credential formats; no repository-wide ignore is inherited.
            if len(data) > MAX_FILE:
                continue
            if b"\x00" in data:
                # A NUL or binary wrapper must not bypass vendor token detection.
                fragments = re.findall(rb"[\x20-\x7e\t]{4,}", data)
                for encoding in ("utf-16-le", "utf-16-be"):
                    for offset in (0, 1):
                        text = data[offset:].decode(encoding, errors="ignore")
                        fragments.extend(match.encode() for match in re.findall(r"[\x20-\x7e\t]{4,}", text))
                data = b"\n".join(fragments)
            name = f"input-{index:06d}.txt"
            (folder / name).write_bytes(data)
            labels[name] = label
        report = Path(work) / "redacted.json"
        result = subprocess.run([str(executable), "dir", str(folder), "--config", str(ROOT / ".gitleaks.toml"),
                                 "--redact=100", "--no-banner", "--no-color", "--ignore-gitleaks-allow",
                                 "--gitleaks-ignore-path", "/dev/null", "--report-format", "json",
                                 "--report-path", str(report)], capture_output=True)
        if result.returncode not in {0, 1} or not report.is_file():
            return [Finding("<gitleaks>", "gitleaks-scan-incomplete")]
        for entry in json.loads(report.read_text()):
            label = labels.get(Path(entry.get("File", "")).name, "<gitleaks>")
            findings.append(Finding(label, "gitleaks-" + entry.get("RuleID", "secret"), entry.get("StartLine", 0)))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gitleaks-bin", type=Path, help="Verified Gitleaks executable; otherwise GITLEAKS_BIN or PATH")
    parser.add_argument("--builtin-only", action="store_true", help="Only the byte/privacy layer; does not replace the complete release gate")
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("index", "history"):
        item = sub.add_parser(command)
        item.add_argument("--repo", type=Path, default=Path.cwd())
    for command in ("tree", "release"):
        item = sub.add_parser(command)
        item.add_argument("paths", nargs="+", type=Path)
        if command == "release":
            item.add_argument("--appcast", type=Path)
            item.add_argument("--checksums", type=Path, action="append", default=[])
    args = parser.parse_args()
    findings = []
    count = 0
    try:
        if args.command == "index":
            findings, count = scan_index(args.repo)
        elif args.command == "history":
            findings, count = scan_history(args.repo)
        else:
            for path in args.paths:
                if not path.exists():
                    findings.append(Finding(path.name, "input-missing"))
                    continue
                if args.command == "release" and path.suffix.lower() == ".dmg":
                    findings.extend(scan_dmg(path))
                else:
                    findings.extend(scan_tree(path, release=args.command == "release"))
                count += 1
            if args.command == "release":
                findings.extend(verify_metadata(args.paths, args.appcast, args.checksums))
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError):
        findings.append(Finding("<scan>", "scan-incomplete"))
    if not args.builtin_only:
        try:
            findings.extend(scan_gitleaks(args.gitleaks_bin, getattr(args, "repo", None)))
        except (OSError, ValueError):
            findings.append(Finding("<gitleaks>", "gitleaks-scan-incomplete"))
    findings = sorted(set(findings))
    for finding in findings:
        line = f":{finding.line}" if finding.line else ""
        print(f"BLOCK {safe_label(finding.path)}{line}: {finding.rule} (value redacted)")
    if findings:
        print(f"Privacy check failed: {len(findings)} finding(s); no matched values were printed.")
        return 1
    print(f"Privacy check passed: {args.command}; {count} input(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
