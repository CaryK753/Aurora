#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
  run|--verify|--logs|--telemetry|--debug) ;;
  *) echo "usage: $0 [run|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac
cd "$ROOT_DIR"
pkill -x Aurora >/dev/null 2>&1 || true
# 复用项目完整打包流程，保留 Finder 扩展及固定签名。
bash ./build.sh debug
APP_BUNDLE="/Applications/Aurora.app"
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/Aurora"
fi
/usr/bin/open "$APP_BUNDLE"
case "$MODE" in
  --verify)
    sleep 3
    pgrep -x Aurora >/dev/null
    echo "✓ Aurora 已启动：$APP_BUNDLE"
    ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Aurora"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.cary.aurora"' ;;
esac
