#!/bin/bash
# DiskDoctor 打包脚本
#
# 产出：
#   dist/DiskDoctor.app        —— 图形界面应用（含 smartctl 引擎）
#   dist/diskdoctor            —— 命令行版本
#
# 依赖：Xcode Command Line Tools（swiftc）、Python 3（仅用于生成图标）
# smartmontools 引擎由 scripts/fetch_smartmontools.sh 自动下载编译，
# smartctl 被打包进 App bundle 的 Contents/Resources/，运行时自动定位。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/DiskDoctor"
VENDOR_DIR="$SCRIPT_DIR/vendor"
SMARTMONTOOLS_VERSION="${SMARTMONTOOLS_VERSION:-7.4}"
SMARTMONTOOLS_DIR="$VENDOR_DIR/smartmontools-$SMARTMONTOOLS_VERSION"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/DiskDoctor.app"

echo "==> 1/5 准备 smartmontools 引擎"
bash "$SCRIPT_DIR/scripts/fetch_smartmontools.sh" "$SMARTMONTOOLS_VERSION"
echo "    smartctl: $SMARTMONTOOLS_DIR/smartctl"

echo "==> 2/5 编译 Swift 工程（Release）"
cd "$PROJECT_DIR"
swift build --disable-sandbox -c release --product DiskDoctorApp
swift build --disable-sandbox -c release --product diskdoctor-cli

echo "==> 3/5 组装 .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Resources/smartmontools"

# 主可执行文件
cp "$PROJECT_DIR/.build/release/DiskDoctorApp" "$APP_BUNDLE/Contents/MacOS/DiskDoctor"

# smartctl 引擎 + 驱动数据库
cp "$SMARTMONTOOLS_DIR/smartctl" "$APP_BUNDLE/Contents/Resources/smartmontools/smartctl"
cp "$SMARTMONTOOLS_DIR/smartd.conf" "$APP_BUNDLE/Contents/Resources/smartmontools/" 2>/dev/null || true
if [ -f "$VENDOR_DIR/sm-prefix/share/smartmontools/smart_drivedb.h" ]; then
    cp "$VENDOR_DIR/sm-prefix/share/smartmontools/smart_drivedb.h" \
       "$APP_BUNDLE/Contents/Resources/smartmontools/"
fi

# Info.plist
#
# 注意：不要添加 CFBundleDisplayName。
# 实测在 macOS 15 上，只要 Info.plist 中存在 CFBundleDisplayName（无论值为中文还是英文），
# .app bundle 内运行时就无法创建可见窗口——进程存活、主线程事件循环正常，
# 但窗口服务器中查不到窗口。移除该键后一切正常。
# 中文名称通过 SwiftUI 的 WindowGroup("硬盘体检工具") 显示在窗口标题栏。
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DiskDoctor</string>
    <key>CFBundleExecutable</key>
    <string>DiskDoctor</string>
    <key>CFBundleIdentifier</key>
    <string>com.workbuddy.diskdoctor</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>DiskDoctor v1.0.0</string>
</dict>
</plist>
PLIST

# 图标（用系统内置图标生成）
ICON_FILE="$DIST_DIR/icon.icns"
if [ ! -f "$ICON_FILE" ]; then
    ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    # 从系统模板绘制一个简洁图标
    python3 "$SCRIPT_DIR/scripts/make_icon.py" "$ICONSET_DIR" 2>/dev/null || true
    if [ -d "$ICONSET_DIR" ] && [ -n "$(ls -A "$ICONSET_DIR" 2>/dev/null)" ]; then
        iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE" 2>/dev/null || true
    fi
fi
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    # 注意：此处只放图标文件，不写 CFBundleIconFile 键（该键在本机会影响窗口创建）
fi

echo "==> 4/5 签名（跳过：本机 ad-hoc 签名会导致窗口无法创建）"
# 说明：本机（macOS 15.8.1）上对 SwiftUI 应用做 ad-hoc 签名后，
# 进程虽能启动、主线程事件循环也正常，但窗口服务器中查不到任何窗口——
# 界面完全不显示。实测：
#   codesign --force --deep --sign - <app>   → 无窗口
#   codesign --force --sign - <可执行文件>    → 无窗口
#   完全不签名                              → 窗口正常
# 因此这里不做签名。本地构建、无 quarantine 属性的 app 可直接双击运行。
if codesign --verify --deep --strict "$APP_BUNDLE" > /dev/null 2>&1; then
    codesign --remove-signature "$APP_BUNDLE" 2>/dev/null || true
fi
rm -rf "$APP_BUNDLE/Contents/_CodeSignature" 2>/dev/null || true
echo "    已移除签名（保证窗口正常显示）"

echo "==> 5/5 复制命令行版本"
cp "$PROJECT_DIR/.build/release/diskdoctor-cli" "$DIST_DIR/diskdoctor"
chmod +x "$DIST_DIR/diskdoctor"

echo ""
echo "构建完成："
echo "  图形界面  $APP_BUNDLE"
echo "  命令行    $DIST_DIR/diskdoctor"
echo ""
echo "使用方式："
echo "  1) 图形界面：双击 $APP_BUNDLE"
echo "  2) 命令行：  $DIST_DIR/diskdoctor list"
echo ""
echo "提示：命令行版本需把 smartctl 加入 PATH，或直接使用 .app 内的图形界面版本："
echo "  export PATH=\"$APP_BUNDLE/Contents/Resources/smartmontools:\$PATH\""
echo "  $DIST_DIR/diskdoctor list"
