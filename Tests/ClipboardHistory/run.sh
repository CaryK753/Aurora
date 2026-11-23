#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$(mktemp -d)"
trap 'find "$dir" -mindepth 1 -maxdepth 1 -type f -delete; rmdir "$dir"' EXIT
cd "$root"
swiftc -O -swift-version 5 Sources/Aurora/Core/{BackgroundSnapshot,ClipboardService,ClipboardHistoryStore}.swift Sources/Aurora/Debug.swift \
    Tests/ClipboardHistory/{shims,main}.swift -lsqlite3 -o "$dir/clipboard-test"
"$dir/clipboard-test" "$dir"
