#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-preferences.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/TrackpadOptions.swift" \
  "$ROOT/Sources/Aurora/Core/ImportParsing.swift" "$ROOT/Tests/Preferences/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
