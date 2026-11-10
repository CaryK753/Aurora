#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-macros.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/MacroEvents.swift" "$ROOT/Tests/Macros/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
