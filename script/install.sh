#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/build/Aurora.app"
TARGET="/Applications/Aurora.app"
STAGING="$(mktemp -d /Applications/.aurora-install.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
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
