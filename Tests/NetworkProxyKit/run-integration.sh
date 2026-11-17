#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
# 使用官方发布的校验和，测试只监听本机临时端口，不写系统代理。
CORE_PATH="${AURORA_PROXY_TEST_CORE:-$CHECK_DIR/mihomo}"
if [[ -z "${AURORA_PROXY_TEST_CORE:-}" ]]; then
python3 - "$CHECK_DIR" "$ROOT" <<'PY'
import gzip
import hashlib
import os
import platform
import sys
import urllib.request

directory = sys.argv[1]
import re
source = open(os.path.join(sys.argv[2], 'Sources/NetworkProxyKit/ProxyEngineRelease.swift')).read()
version = re.search(r'let version = "([^"]+)"', source).group(1)
arch = 'arm64' if platform.machine() == 'arm64' else 'amd64-compatible'
digest = re.search('"' + arch + r'": "([a-f0-9]+)"', source).group(1)
name = 'mihomo-darwin-' + arch + '-' + version + '.gz'
url = 'https://github.com/MetaCubeX/mihomo/releases/download/' + version + '/' + name
with urllib.request.urlopen(url, timeout=300) as response:
    archive = response.read(100 * 1024 * 1024)
assert hashlib.sha256(archive).hexdigest() == digest
path = os.path.join(directory, 'mihomo')
with open(path, 'wb') as output:
    output.write(gzip.decompress(archive))
os.chmod(path, 0o700)
print('Verified mihomo ' + version)
PY
fi
cd "$ROOT"
AURORA_PROXY_TEST_CORE="$CORE_PATH" AURORA_PROXY_TEST_APNIC=1 swift test --filter ProxyEngineIntegrationTests
