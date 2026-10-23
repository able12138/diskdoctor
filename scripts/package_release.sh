#!/bin/bash
# 打包 Release 资产
#
# 产出（输出到 dist/release/）：
#   DiskDoctor-app.zip   图形界面版
#   diskdoctor           命令行版
#
# 关键：必须用 macOS 自带的 ditto 打包，不能用 zip 或 Python zipfile。
# ditto 会保留可执行权限位与资源分支；其他方式会导致解压后
# DiskDoctor 与 smartctl 丢失 +x 权限，表现为 "permission denied"。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_BUNDLE="$DIST_DIR/DiskDoctor.app"

if [ ! -d "$APP_BUNDLE" ] || [ ! -x "$DIST_DIR/diskdoctor" ]; then
    echo "❌ 产物不存在，请先运行 ./build.sh"
    exit 1
fi

mkdir -p "$RELEASE_DIR"
rm -f "$RELEASE_DIR/DiskDoctor-app.zip" "$RELEASE_DIR/diskdoctor"

echo "==> 打包 App bundle（ditto，保留权限位）"
cd "$DIST_DIR"
ditto -c -k --keepParent DiskDoctor.app "$RELEASE_DIR/DiskDoctor-app.zip"

echo "==> 复制命令行版"
cp "$DIST_DIR/diskdoctor" "$RELEASE_DIR/diskdoctor"
chmod +x "$RELEASE_DIR/diskdoctor"

echo "==> 校验"
# 解压到临时目录验证权限与可执行性
TMP_DIR="$(mktemp -d)"
ditto -x -k "$RELEASE_DIR/DiskDoctor-app.zip" "$TMP_DIR"

check() {
    if [ -x "$1" ]; then
        echo "  ✅ $2 可执行"
    else
        echo "  ❌ $2 缺少可执行权限"
        rm -rf "$TMP_DIR"
        exit 1
    fi
}

check "$TMP_DIR/DiskDoctor.app/Contents/MacOS/DiskDoctor" "主程序"
check "$TMP_DIR/DiskDoctor.app/Contents/Resources/smartmontools/smartctl" "smartctl 引擎"
rm -rf "$TMP_DIR"

echo ""
ls -lh "$RELEASE_DIR"
echo ""
echo "发布命令："
echo "  gh release create v<版本> \\"
echo "    $RELEASE_DIR/DiskDoctor-app.zip \\"
echo "    $RELEASE_DIR/diskdoctor \\"
echo "    --title \"DiskDoctor v<版本>\" --notes-file <说明文件>"
