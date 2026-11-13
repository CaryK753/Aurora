#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-functional.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/AudioService.swift" \
  "$ROOT/Sources/Aurora/Core/AudioObservation.swift" \
  "$ROOT/Sources/Aurora/Core/EnergyService.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayService.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayTuning.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayGamma.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayOSD.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayMediaKeys.swift" \
  "$ROOT/Sources/Aurora/TransparentHostingView.swift" \
  "$ROOT/Sources/Aurora/Core/PrivateSymbols.swift" \
  "$ROOT/Tests/Functional/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
