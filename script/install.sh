#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/build/Aurora.app"
TARGET="/Applications/Aurora.app"
STAGING="$(mktemp -d /Applications/.aurora-install.XXXXXX)"
# 收尾：正常情况直接删；删不动（受保护目录 / 批量删除被拦）就丢进废纸篓，
# 总之不要在 /Applications 里留下 .aurora-install.* 一堆旧副本。
cleanup() {
  [[ -d "$STAGING" ]] || return 0
  if rm -rf "$STAGING" 2>/dev/null; then return 0; fi
  local dest="$HOME/.Trash/aurora-install-$(date +%s)-$$"
  if mv "$STAGING" "$dest" 2>/dev/null; then
    echo "  （旧版本副本已移到废纸篓：$dest）"
  else
    echo "  ⚠️ 临时目录未清理：$STAGING"
  fi
}
trap cleanup EXIT
codesign --verify --deep --strict "$SOURCE"
ditto "$SOURCE" "$STAGING/Aurora.app"
codesign --verify --deep --strict "$STAGING/Aurora.app"
# 保留可回滚副本，避免旧 app 同时被当成第二个可运行副本。
if [[ -d "$TARGET" ]]; then
  ditto -c -k --keepParent "$TARGET" "$ROOT_DIR/build/Aurora-previous.zip"
fi
pkill -x Aurora >/dev/null 2>&1 || true
pkill -x AuroraFinder >/dev/null 2>&1 || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for APP in "$SOURCE" "$TARGET"; do
  if [[ -d "$APP" ]]; then
    /usr/bin/pluginkit -r "$APP/Contents/PlugIns/AuroraFinder.appex" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  fi
done
if [[ -d "$TARGET" ]]; then mv "$TARGET" "$STAGING/Previous.app"; fi
if ! mv "$STAGING/Aurora.app" "$TARGET"; then
  if [[ -d "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$TARGET"; fi
  exit 1
fi
"$LSREGISTER" -f "$TARGET"
/usr/bin/pluginkit -a "$TARGET/Contents/PlugIns/AuroraFinder.appex"
echo "✓ 已安装：$TARGET"
