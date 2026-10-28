#!/bin/bash
# 编译打过 LE PHY / Data Length 补丁的 IntelBTPatcher.kext
# 只需要 Command Line Tools（不需要完整 Xcode）
#
# 用法: ./scripts/build.sh [SDK路径]
#   默认自动挑选本机最新的 /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO_DIR/.build}"
VER="2.5.1"

SDK="${1:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX1*.sdk 2>/dev/null | tail -1)}"
[ -d "$SDK" ] || { echo "!! 找不到 SDK，请显式传入：$0 /path/to/MacOSX13.sdk"; exit 1; }
echo "== SDK: $SDK"

mkdir -p "$WORK" && cd "$WORK"

# --- 依赖 ---
[ -d MacKernelSDK ] || git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git
[ -d Lilu ]         || git clone --depth 1 https://github.com/acidanthera/Lilu.git
if [ ! -d ibtf ]; then
  git clone --depth 1 https://github.com/OpenIntelWireless/IntelBluetoothFirmware.git ibtf
fi
cd ibtf
if ! git rev-parse --verify pr515 >/dev/null 2>&1; then
  git fetch origin pull/515/head:pr515 --depth 1
fi
git checkout -q pr515

# --- 用本仓库的源码覆盖（含移植修正）---
cp "$REPO_DIR/src/IntelBTPatcher.cpp" "$REPO_DIR/src/IntelBTPatcher.hpp" IntelBTPatcher/
cp "$REPO_DIR/src/kmod_info.cpp" .

# --- 编译 ---
CF=(-std=gnu++14 -mkernel -DKERNEL=1 -fapple-kext -fno-rtti -fno-exceptions
    -fno-threadsafe-statics -fno-common -nostdinc++ -mmacosx-version-min=10.12
    -DMODULE_VERSION="\"$VER\"" -DPRODUCT_NAME=IntelBTPatcher
    -I ../MacKernelSDK/Headers -F ../MacKernelSDK/Headers
    -I ../Lilu/Lilu -F ../Lilu/Lilu/Headers)

mkdir -p build
echo "== 编译 IntelBTPatcher.cpp"
clang++ "${CF[@]}" -c IntelBTPatcher/IntelBTPatcher.cpp -o build/IntelBTPatcher.o
echo "== 编译 plugin_start.cpp (缺它就没有 _IntelBTPatcher_kern_start)"
clang++ "${CF[@]}" -c ../Lilu/Lilu/Library/plugin_start.cpp -o build/plugin_start.o
echo "== 编译 kmod_info.cpp (缺它就没有 _kmod_info，OC 会静默丢弃)"
clang++ "${CF[@]}" -c kmod_info.cpp -o build/kmod_info.o

echo "== 链接"
ld -kext -arch x86_64 -static -L "$SDK/usr/lib" -lkmod -lkmodc++ \
   -o build/IntelBTPatcher build/IntelBTPatcher.o build/plugin_start.o build/kmod_info.o 2>&1 \
   | grep -v "built for newer macOS version" || true

# --- 组装 bundle ---
BUNDLE="$WORK/IntelBTPatcher.kext"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$REPO_DIR/src/Info.plist" "$BUNDLE/Contents/Info.plist"
cp build/IntelBTPatcher "$BUNDLE/Contents/MacOS/IntelBTPatcher"

# --- 自检 ---
echo "== 自检"
plutil -lint "$BUNDLE/Contents/Info.plist"
SYMS=$(nm "$BUNDLE/Contents/MacOS/IntelBTPatcher")
for sym in _kmod_info _IntelBTPatcher_kern_start _IntelBTPatcher_kern_stop; do
  grep -q " $sym\$" <<<"$SYMS" || { echo "!! 缺少符号 $sym"; exit 1; }
done
SIZE=$(stat -f%z "$BUNDLE/Contents/MacOS/IntelBTPatcher")
echo "   二进制大小: $SIZE 字节（约 44 KB 为正常；2x KB 说明漏了 plugin_start）"
shasum -a 256 "$BUNDLE/Contents/MacOS/IntelBTPatcher"
echo "== 完成: $BUNDLE"
echo "   下一步: ./scripts/install-efi.sh disk0s1"
