#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d /tmp/aurora-permissions.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/Aurora/Core/PermissionSnapshot.swift" "$ROOT/Tests/Permissions/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
