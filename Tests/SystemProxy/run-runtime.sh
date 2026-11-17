#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${AURORA_PROXY_TEST_CORE:?Set AURORA_PROXY_TEST_CORE to a verified mihomo binary}"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
cd "$ROOT"
swift build --target NetworkProxyKit >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  -I "$BIN_DIR" -I "$ROOT/.build/checkouts/Yams/Sources/CYaml/include" \
  "$ROOT/Sources/Aurora/Core/CommandRunner.swift" \
  "$ROOT/Sources/Aurora/Core/ProxyLocalProbe.swift" \
  "$ROOT/Sources/Aurora/Core/ProxyEngineRuntime.swift" \
  "$ROOT/Tests/SystemProxy/RuntimeCheck.swift" \
  "$BIN_DIR/NetworkProxyKit.o" "$BIN_DIR/Yams.o" "$BIN_DIR/CYaml.o" \
  -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$AURORA_PROXY_TEST_CORE"
