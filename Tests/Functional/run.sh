#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-functional.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/AudioService.swift" \
  "$ROOT/Sources/Aurora/Core/AudioObservation.swift" \
  "$ROOT/Sources/Aurora/Core/EnergyService.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayService.swift" \
  "$ROOT/Sources/Aurora/Core/PrivateSymbols.swift" \
  "$ROOT/Tests/Functional/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
