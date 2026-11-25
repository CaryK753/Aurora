#!/bin/bash
# Aurora 构建脚本：编译 Swift 包并打包成 .app
#
# 常用环境变量：
#   AURORA_VERSION   版本号（默认取 CHANGELOG.md 首个版本，其次取最近的 git tag）
#   AURORA_BUILD     CFBundleVersion（默认取提交数）
#   AURORA_UNIVERSAL 1 = 同时编译 arm64 与 x86_64 并合并为通用二进制
#   AURORA_INSTALL   1 = 打包后安装到 /Applications（默认 1）
#   AURORA_SIGN_ID   指定签名证书（默认本机 Apple Development）
#   AURORA_NE_PROFILE  带 Network Extension 的描述文件。不传时主程序不签这项授权，避免被系统杀掉。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Aurora"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONFIG="${1:-release}"
MIN_MACOS="26.0"

VERSION="${AURORA_VERSION:-}"
if [[ -z "$VERSION" && -f CHANGELOG.md ]]; then
  VERSION="$(awk '/^## v[0-9]+\.[0-9]+\.[0-9]+$/ { print substr($2, 2); exit }' CHANGELOG.md)"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${AURORA_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# macOS 自带的 bash 3.2 在 set -u 下展开空数组会报错，这里用普通字符串
ARCH_ARGS=""
if [[ "${AURORA_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_ARGS="--arch arm64 --arch x86_64"
  echo "▸ 编译通用二进制 ($CONFIG) · v$VERSION ($BUILD_NUMBER)…"
else
  echo "▸ 编译 ($CONFIG) · v$VERSION ($BUILD_NUMBER)…"
fi

swift build -c "$CONFIG" --disable-sandbox $ARCH_ARGS

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path --disable-sandbox $ARCH_ARGS)"
BIN_PATH="$BIN_DIR/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "✗ 未找到可执行文件：$BIN_PATH"
  exit 1
fi

echo "▸ 组装 .app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/NetworkThirdPartyNotices.txt" "$APP_DIR/Contents/Resources/NetworkThirdPartyNotices.txt"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Aurora</string>
    <key>CFBundleIdentifier</key>
    <string>com.cary.aurora</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Aurora</string>
    <key>CFBundleDisplayName</key>
    <string>Aurora</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Aurora · 桌面控制台 · MIT License</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Aurora 需要捕获应用音频，以在本机调节各应用的输出音量。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Aurora 在你开启录屏麦克风时采集声音，音频仅保存到本机录像中。</string>
    <key>NSCameraUsageDescription</key>
    <string>Aurora 用相机权限显示画中画预览，并读取已信任的 USB iPhone 或 iPad 屏幕。录像保存在本机。</string>
    <key>NSSystemExtensionUsageDescription</key>
    <string>Aurora 用网络扩展在系统设置的 VPN 列表里提供规则、直连和全局代理。</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 「新功能」窗口的离线更新说明：按版本号从 CHANGELOG 里取对应段落
if [ -f "$ROOT/CHANGELOG.md" ]; then
  cp "$ROOT/CHANGELOG.md" "$APP_DIR/Contents/Resources/CHANGELOG.md"
fi

# 截图模块的 Apple 官方设备外壳（PNG + 屏幕矩形清单）
# 清单里列到的每一张 PNG 都必须进包：Bundle 的资源查找不递归子目录，漏一张那款外壳装机后就直接消失。
if [ -d "$ROOT/Resources/DeviceFrames" ]; then
  FRAMES_DIR="$APP_DIR/Contents/Resources/DeviceFrames"
  mkdir -p "$FRAMES_DIR"
  cp "$ROOT/Resources/DeviceFrames/"* "$FRAMES_DIR/"
  python3 - "$FRAMES_DIR" <<'PY'
import json, os, sys
root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "frames.json"), encoding="utf-8"))
missing = [entry["file"] for entry in manifest if not os.path.isfile(os.path.join(root, entry["file"]))]
extra = [name for name in os.listdir(root)
         if name.endswith(".png") and name not in {entry["file"] for entry in manifest}]
if missing:
    print("✗ 外壳清单里有 %d 张 PNG 没打进来：%s" % (len(missing), "、".join(missing)))
    sys.exit(1)
print("▸ 设备外壳 %d 款已打包" % len(manifest))
for name in extra:
    print("  提示：%s 不在清单里，装了也不会显示" % name)
PY
fi

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "▸ 编译 Finder 右键扩展…"
EXT_DIR="$APP_DIR/Contents/PlugIns/AuroraFinder.appex"
rm -rf "$APP_DIR/Contents/PlugIns"
mkdir -p "$EXT_DIR/Contents/MacOS"

build_extension() {  # $1 = 架构，$2 = 输出路径
  swiftc -O -module-name AuroraFinder \
    -target "$1-apple-macos${MIN_MACOS}" \
    -framework Cocoa -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$ROOT/Sources/AuroraFinder/FinderSync.swift" \
    -o "$2"
}

if [[ "${AURORA_UNIVERSAL:-0}" == "1" ]]; then
  TMP_EXT="$(mktemp -d)"
  build_extension arm64 "$TMP_EXT/arm64"
  build_extension x86_64 "$TMP_EXT/x86_64"
  lipo -create -output "$EXT_DIR/Contents/MacOS/AuroraFinder" "$TMP_EXT/arm64" "$TMP_EXT/x86_64"
  rm -rf "$TMP_EXT"
else
  build_extension "$(uname -m)" "$EXT_DIR/Contents/MacOS/AuroraFinder"
fi

cat > "$EXT_DIR/Contents/Info.plist" <<EXTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Aurora 右键</string>
    <key>CFBundleExecutable</key>
    <string>AuroraFinder</string>
    <key>CFBundleIdentifier</key>
    <string>com.cary.aurora.finder</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AuroraFinder</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict/>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key>
        <string>AuroraFinderExtension</string>
    </dict>
</dict>
</plist>
EXTPLIST

echo "▸ 编译网络扩展…"
TUNNEL_DIR="$APP_DIR/Contents/Library/SystemExtensions/AuroraTunnel.systemextension"
mkdir -p "$TUNNEL_DIR/Contents/MacOS"

build_tunnel() {  # $1 = 架构，$2 = 输出路径
  swiftc -O -module-name AuroraTunnel \
    -target "$1-apple-macos${MIN_MACOS}" \
    -framework NetworkExtension -framework Network \
    "$ROOT/Sources/AuroraTunnel/main.swift" \
    "$ROOT/Sources/AuroraTunnel/TunnelProvider.swift" \
    "$ROOT/Sources/AuroraTunnel/TCPRelay.swift" \
    "$ROOT/Sources/Aurora/Core/ProxyRuleEngine.swift" \
    -o "$2"
}

if [[ "${AURORA_UNIVERSAL:-0}" == "1" ]]; then
  TMP_TUNNEL="$(mktemp -d)"
  build_tunnel arm64 "$TMP_TUNNEL/arm64"
  build_tunnel x86_64 "$TMP_TUNNEL/x86_64"
  lipo -create -output "$TUNNEL_DIR/Contents/MacOS/AuroraTunnel" "$TMP_TUNNEL/arm64" "$TMP_TUNNEL/x86_64"
  rm -rf "$TMP_TUNNEL"
else
  build_tunnel "$(uname -m)" "$TUNNEL_DIR/Contents/MacOS/AuroraTunnel"
fi

cat > "$TUNNEL_DIR/Contents/Info.plist" <<TUNNELPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Aurora</string>
    <key>CFBundleExecutable</key>
    <string>AuroraTunnel</string>
    <key>CFBundleIdentifier</key>
    <string>com.cary.aurora.tunnel</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AuroraTunnel</string>
    <key>CFBundlePackageType</key>
    <string>SYSX</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NetworkExtension</key>
    <dict>
        <key>NEMachServiceName</key>
        <string>com.cary.aurora.tunnel</string>
        <key>NEProviderClasses</key>
        <dict>
            <key>com.apple.networkextension.app-proxy</key>
            <string>AuroraTunnelProvider</string>
        </dict>
    </dict>
</dict>
</plist>
TUNNELPLIST

echo "▸ 签名…"
# 用固定证书签名：TCC（辅助功能/屏幕录制/完全磁盘访问）按签名记录授权，
# ad-hoc 每次重建 cdhash 都变，会导致「已经在系统设置里勾选但仍然未授权」。
IDENTITY="${AURORA_SIGN_ID:-Apple Development: caryk1208@outlook.com (6BGNXNX5FT)}"
APP_ENTITLEMENTS="$ROOT/Resources/Aurora.entitlements"
if [[ -n "${AURORA_NE_PROFILE:-}" && -f "${AURORA_NE_PROFILE}" ]]; then
  cp "${AURORA_NE_PROFILE}" "$APP_DIR/Contents/embedded.provisionprofile"
  cp "${AURORA_NE_PROFILE}" "$TUNNEL_DIR/Contents/embedded.provisionprofile"
  APP_ENTITLEMENTS="$ROOT/Resources/AuroraWithNetwork.entitlements"
  echo "  使用 Network Extension 描述文件"
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  # 内层扩展先签，再签外层 App。
  # macOS 26 的 pkd 只接收沙盒化的 appex（不沙盒时 pluginkit -a 静默失败、-m 查不到），
  # 所以这里必须带 app-sandbox；沙盒里不能直接写盘/起 shell，落盘类动作委托主 App 执行。
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/AuroraTunnel.entitlements" \
    --sign "$IDENTITY" "$TUNNEL_DIR" 2>&1 | tail -1
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/AuroraFinder.entitlements" \
    --sign "$IDENTITY" "$EXT_DIR" 2>&1 | tail -1
  codesign --force --options runtime --timestamp=none \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP_DIR" 2>&1 | tail -2
  echo "  已用固定证书签名：$IDENTITY"
else
  # CI / 没有证书的机器：ad-hoc 签名，功能可用，但 TCC 授权在每次重建后需要重新勾选
  codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/Resources/AuroraTunnel.entitlements" "$TUNNEL_DIR"
  codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/Resources/AuroraFinder.entitlements" "$EXT_DIR"
  codesign --force --sign - --timestamp=none \
    --entitlements "$APP_ENTITLEMENTS" "$APP_DIR"
  echo "  ⚠️ 未找到固定证书，退回 ad-hoc（权限授权在重建后会失效）"
fi

echo "✓ 构建完成：$APP_DIR"
if [[ "${AURORA_INSTALL:-1}" == "1" ]]; then
  bash "$ROOT/script/install.sh"
fi
