#!/bin/bash
# 获取并编译 smartmontools（DiskDoctor 的 SMART 读取引擎）
#
# 为什么需要它：macOS 没有系统自带的 SMART 工具，读取真实 SMART 数据必须走
# IOKit 通道（IOATASMARTLib / IONVMeSMARTInterface）。smartmontools 的 Darwin
# 后端正是基于这两个接口。本脚本从官方 SourceForge 下载源码并本地编译，
# 不依赖 Homebrew，也不要求用户预装任何东西。
#
# 用法：scripts/fetch_smartmontools.sh [版本号]   默认 7.4

set -euo pipefail

VERSION="${1:-7.4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/vendor"
SRC_DIR="$VENDOR_DIR/smartmontools-$VERSION"
TARBALL="$VENDOR_DIR/smartmontools-$VERSION.tar.gz"
PREFIX="$VENDOR_DIR/sm-prefix"

if [ -x "$SRC_DIR/smartctl" ]; then
    echo "smartctl 已存在：$SRC_DIR/smartctl"
    exit 0
fi

mkdir -p "$VENDOR_DIR"

# 下载：优先 SourceForge，失败时回退 GitHub codeload tarball
if [ ! -f "$TARBALL" ]; then
    echo "==> 下载 smartmontools $VERSION"
    if ! curl -sSL -m 300 -o "$TARBALL" \
        "https://sourceforge.net/projects/smartmontools/files/smartmontools-$VERSION.tar.gz/download"; then
        echo "    SourceForge 下载失败，尝试 GitHub 镜像"
        rm -f "$TARBALL"
        curl -sSL -m 300 -o "$TARBALL" \
            "https://codeload.github.com/smartmontools/smartmontools/tar.gz/refs/tags/v$VERSION"
    fi
    # 校验是有效压缩包
    if ! tar tzf "$TARBALL" > /dev/null 2>&1; then
        echo "❌ 下载的文件不是有效的 tar 压缩包，请检查网络后重试"
        rm -f "$TARBALL"
        exit 1
    fi
fi

echo "==> 解压"
cd "$VENDOR_DIR"
tar xzf "$TARBALL"

echo "==> 配置"
cd "$SRC_DIR"
./configure --prefix="$PREFIX" \
            --disable-dependency-tracking \
            --without-systemd \
            --without-cap-ng \
            --without-selinux > /tmp/smartmontools-configure.log 2>&1

echo "==> 编译（这会花几分钟）"
make -j"$(sysctl -n hw.ncpu)" > /tmp/smartmontools-build.log 2>&1

if [ ! -x "$SRC_DIR/smartctl" ]; then
    echo "❌ 编译失败，日志见 /tmp/smartmontools-build.log"
    tail -30 /tmp/smartmontools-build.log
    exit 1
fi

echo "✅ 完成：$SRC_DIR/smartctl"
