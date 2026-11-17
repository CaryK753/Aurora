#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/SystemProxyPreferences.swift" "$ROOT/Tests/SystemProxy/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
