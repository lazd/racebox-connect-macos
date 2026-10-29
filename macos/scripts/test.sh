#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The standalone Command Line Tools omit XCTest; prefer Xcode for the test SDK.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        printf 'Native tests need Xcode 15.3 or later (XCTest is not in the Command Line Tools).\n' >&2
        exit 1
    fi
fi
swift test --package-path "$ROOT/macos" --scratch-path "$ROOT/macos/.build-tests"
