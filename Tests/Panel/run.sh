#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-panel.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/PanelDismissalPolicy.swift" "$ROOT/Tests/Panel/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
