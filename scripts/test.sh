#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Steve
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
validation_id="com.example.FCP-Cleaner.Validation-$(uuidgen)"
cd "$repo_root"
mkdir -p build
# A new host identity prevents automatic startup from loading real bookmark records.
# Integration tests create their own disposable fixtures in temporary directories.
xcodebuild -project "FCP Cleaner/FCP Cleaner.xcodeproj" \
  -scheme "FCP Cleaner" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/TestValidation \
  "FCPCLEANER_BUNDLE_IDENTIFIER=$validation_id" \
  SPARKLE_FEED_URL= \
  clean test "$@"
