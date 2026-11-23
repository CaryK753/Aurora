#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR=$(mktemp -d)
trap 'unlink "$DIR/probe.o" 2>/dev/null || :; unlink "$DIR/check" 2>/dev/null || :; rmdir "$DIR"' EXIT
clang -O2 -c "$ROOT/Tests/Performance/rusage-probe.c" -o "$DIR/probe.o"
swiftc -O -swift-version 5 -import-objc-header "$ROOT/Tests/Performance/rusage-probe.h" \
  "$ROOT/Sources/Aurora/Core/SystemMonitor.swift" "$ROOT/Tests/Performance/main.swift" "$DIR/probe.o" -o "$DIR/check"
"$DIR/check"
