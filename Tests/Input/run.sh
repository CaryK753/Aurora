#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-input.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/SnippetPasteboard.swift" "$ROOT/Sources/Aurora/Core/InputRuleDomain.swift" "$ROOT/Tests/Input/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
