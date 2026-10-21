#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
"""Regression tests use synthetic credentials generated at runtime, never real secrets."""

import base64
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

import privacy_scan as scan


class PrivacyScanTests(unittest.TestCase):
    def rules(self, data, label="example.txt"):
        return {finding.rule for finding in scan.scan_data(label, data)}

    def private_path(self):
        return "/" + "Users/" + "privacy-fixture/" + "build/file.swift"

    def token(self):
        return "gh" + "p_" + hashlib.sha256(b"synthetic fixture only").hexdigest()

    def test_token_private_key_password_and_authenticated_url(self):
        examples = [
            (self.token(), "github-token"),
            ("-----BEGIN " + "OPENSSH PRIVATE KEY-----", "private-key"),
            ('password = "' + "synthetic-password-8824" + '"', "credential-assignment"),
            ("https" + "://fixture:synthetic-password" + "@" + "invalid.test/", "authenticated-url"),
        ]
        for value, rule in examples:
            with self.subTest(rule=rule):
                self.assertIn(rule, self.rules(value.encode()))

    def test_sparkle_raw_private_material_and_exact_public_key(self):
        seed = base64.b64encode(hashlib.sha256(b"not a real signing key").digest())
        expanded = base64.b64encode(hashlib.sha512(b"not a real expanded key").digest())
        self.assertIn("unclassified-key-material", self.rules(seed))
        self.assertIn("unclassified-key-material", self.rules(expanded))
        self.assertEqual(self.rules(scan.PUBLIC_ED_KEY.encode()), set())
        self.assertIn("unclassified-key-material", self.rules(b'SUPublicEDKey = "' + seed + b'"'))

    def test_paths_binary_utf16_both_endiannesses_and_alignments(self):
        for codec in ("utf-8", "utf-16-le", "utf-16-be"):
            for offset in (b"", b"x"):
                self.assertIn("personal-home-path", self.rules(offset + self.private_path().encode(codec)))
        self.assertEqual(self.rules(("/" + "Users/test/fixture").encode()), set())

    def test_private_email_and_public_fixture_email(self):
        private = "fixture-owner" + "@" + "privacy-test.test"
        self.assertIn("personal-email", self.rules(private.encode()))
        self.assertEqual(self.rules(b"maintainer@example.invalid"), set())
        noreply = "123456+fixture" + "@users.noreply.github.com"
        self.assertEqual(self.rules(noreply.encode()), set())

    def test_unquoted_credentials_and_sensitive_filenames_are_redacted(self):
        value = "synthetic-secret-value-123456"
        self.assertIn("credential-assignment", self.rules(("pass" + "word: " + value + "\n").encode()))
        label = self.token() + ".txt"
        self.assertIn("github-token-in-filename", self.rules(b"safe", label))
        self.assertNotIn(self.token(), scan.safe_label(label))

    def test_unicode_space_and_home_root_paths(self):
        for owner in ("合成用户", "Synthetic Owner"):
            for suffix in ("", "/build", "\x00"):
                with self.subTest(owner=owner, suffix=suffix):
                    value = "/" + "Users/" + owner + suffix
                    self.assertIn("personal-home-path", self.rules(value.encode()))

    def test_sensitive_filenames(self):
        for name in ("AuthKey.p8", "certificate.p12", "error.log", "run.trace", "Test.xcresult/result.json", ".env.local", ".secrets.env"):
            with self.subTest(name=name):
                self.assertIn("private-development-file", self.rules(b"{}", name))

    def test_index_uses_staged_bytes_ignores_worktree_and_untracked(self):
        with tempfile.TemporaryDirectory(prefix="fcp-index-test-") as work:
            root = Path(work)
            def git(*args):
                subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            file = root / "data.txt"
            file.write_text("clean\n")
            git("add", "data.txt")
            git("commit", "-qm", "Initial fixture")
            file.write_text(self.token())
            git("add", "data.txt")
            file.write_text("clean worktree\n")
            findings, count = scan.scan_index(root)
            self.assertEqual(count, 1)
            self.assertIn("github-token", {f.rule for f in findings})
            git("add", "data.txt")
            file.write_text(self.token())
            (root / "untracked.txt").write_text(self.token())
            findings, count = scan.scan_index(root)
            self.assertEqual(findings, [])
            self.assertEqual(count, 1)
            (root / ".gitignore").write_text("*.log\n")
            git("add", ".gitignore")
            (root / "result.log").write_text("fixture\n")
            git("add", "-f", "result.log")
            self.assertIn("private-development-file", {f.rule for f in scan.scan_index(root)[0]})

    def test_zip_directory_traversal_and_external_symlink(self):
        with tempfile.TemporaryDirectory(prefix="fcp-zip-test-") as work:
            archive = Path(work) / "fixture.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../escape/", b"")
                link = zipfile.ZipInfo("bundle/link")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(link, "/etc/passwd")
                output.writestr("bundle/.DS_Store", self.private_path().encode("utf-16-be"))
            rules = {f.rule for f in scan.scan_zip(archive, archive.name)}
            self.assertTrue({"unsafe-archive-entry", "external-archive-symlink", "personal-home-path"} <= rules)

    @unittest.skipUnless(sys.platform == "darwin", "macOS xattr integration")
    def test_xattrs_on_directory_root_and_file(self):
        with tempfile.TemporaryDirectory(prefix="fcp-xattr-test-", dir="/private/tmp") as work:
            root = Path(work)
            child = root / "fixture.txt"
            child.write_text("fixture")
            for path in (root, child):
                subprocess.run(["/usr/bin/xattr", "-w", "com.example.fcpPrivacyFixture", self.private_path(), str(path)], check=True, capture_output=True)
            findings = scan.scan_tree(root, release=True)
            self.assertEqual(len({f.path for f in findings if f.rule == "personal-home-path"}), 2)

    def test_redacted_output_never_contains_match(self):
        with tempfile.TemporaryDirectory(prefix="fcp-redaction-test-") as work:
            path = Path(work) / "fixture.txt"
            path.write_text(self.token() + "\n" + self.private_path())
            result = subprocess.run([sys.executable, str(Path(scan.__file__)), "--builtin-only", "tree", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(self.token(), result.stdout + result.stderr)
            self.assertNotIn(self.private_path(), result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "macOS disk-image integration")
    def test_release_directory_mounts_nested_dmg_and_checks_payload(self):
        with tempfile.TemporaryDirectory(prefix="fcp-dmg-test-", dir="/private/tmp") as work:
            root = Path(work)
            payload = root / "payload"
            payload.mkdir()
            (payload / "fixture.txt").write_text(self.private_path())
            releases = root / "releases" / "nested"
            releases.mkdir(parents=True)
            image = releases / "fixture.dmg"
            created = subprocess.run(["/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                                      "-volname", "FCPPrivacyFixture", "-srcfolder", str(payload), str(image)],
                                     capture_output=True)
            self.assertEqual(created.returncode, 0, "synthetic disk image creation failed")
            result = subprocess.run([sys.executable, str(Path(scan.__file__)), "--builtin-only", "release", str(root / "releases")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("personal-home-path", result.stdout)
            self.assertNotIn(self.private_path(), result.stdout + result.stderr)

    def test_missing_input_and_corrupt_archive_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="fcp-failure-test-") as work:
            archive = Path(work) / "fixture.zip"
            archive.write_text("not a zip")
            for path in (archive, Path(work) / "missing.txt"):
                result = subprocess.run([sys.executable, str(Path(scan.__file__)), "--builtin-only", "release", str(path)], capture_output=True)
                self.assertEqual(result.returncode, 1)

    def test_checksum_mismatch_and_missing_attachment(self):
        with tempfile.TemporaryDirectory(prefix="fcp-checksum-test-") as work:
            root = Path(work)
            archive = root / "fixture.zip"
            archive.write_bytes(b"fixture")
            checksums = root / "fixture.sha256"
            checksums.write_text("0" * 64 + "  fixture.zip\n")
            rules = {f.rule for f in scan.verify_metadata([archive], None, [checksums])}
            self.assertIn("attachment-checksum-mismatch", rules)

    @unittest.skipUnless(os.environ.get("GITLEAKS_BIN"), "set GITLEAKS_BIN for binary vendor-rule integration")
    def test_binary_nul_and_utf16_cannot_bypass_vendor_rules(self):
        original = list(scan.GITLEAKS_INPUTS)
        try:
            token = hashlib.sha256(b"synthetic binary vendor secret").hexdigest()
            for codec in ("utf-8", "utf-16-le", "utf-16-be"):
                scan.GITLEAKS_INPUTS[:] = [("wrapped.bin", b"\x00" + ('custom_secret="' + token + '"').encode(codec))]
                self.assertTrue(any(f.rule.startswith("gitleaks-") for f in scan.scan_gitleaks()))
        finally:
            scan.GITLEAKS_INPUTS[:] = original

    @unittest.skipUnless(os.environ.get("GITLEAKS_BIN"), "set GITLEAKS_BIN for vendor-rule integration")
    def test_gitleaks_generic_api_key_and_public_key(self):
        original = list(scan.GITLEAKS_INPUTS)
        try:
            scan.GITLEAKS_INPUTS.clear()
            generic = "api_key = \"" + hashlib.sha256(b"synthetic generic secret").hexdigest() + '"'
            scan.GITLEAKS_INPUTS.extend([("generic.py", generic.encode()), ("public.xcconfig", ("SPARKLE_PUBLIC_ED_KEY = " + scan.PUBLIC_ED_KEY).encode())])
            findings = scan.scan_gitleaks()
            self.assertTrue(any(f.path == "generic.py" and f.rule.startswith("gitleaks-") for f in findings))
            self.assertFalse(any(f.path == "public.xcconfig" for f in findings))
        finally:
            scan.GITLEAKS_INPUTS[:] = original


if __name__ == "__main__":
    unittest.main()
