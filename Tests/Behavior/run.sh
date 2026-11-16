#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-behavior.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos26.0" \
  "$ROOT/Sources/Aurora/Core/WallpaperModels.swift" \
  "$ROOT/Sources/Aurora/Core/WallpaperPlayback.swift" \
  "$ROOT/Sources/Aurora/Core/WallpaperRenderer.swift" \
  "$ROOT/Sources/Aurora/Core/WallpaperVideoView.swift" \
  "$ROOT/Sources/Aurora/Core/RecorderSource.swift" \
  "$ROOT/Sources/Aurora/Core/RecordingAudioMixer.swift" \
  "$ROOT/Sources/Aurora/Core/FinderElection.swift" \
  "$ROOT/Sources/Aurora/Core/FinderExtensionService.swift" \
  "$ROOT/Sources/Aurora/Core/DesktopService.swift" \
  "$ROOT/Sources/Aurora/Core/CommandRunner.swift" \
  "$ROOT/Sources/Aurora/Core/DisplayGamma.swift" \
  "$ROOT/Tests/Behavior/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
