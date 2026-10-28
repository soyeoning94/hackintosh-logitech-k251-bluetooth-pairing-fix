#!/bin/bash
# 把 IntelBTPatcher.kext 写入 OpenCore 的 EFI 分区（先全量备份 OC 目录）
#
# 用法: sudo ./scripts/install-efi.sh [EFI设备] [kext目录]
#   EFI设备  默认 disk0s1（用 `diskutil list` 确认哪个是 EFI）
#   kext目录 默认本仓库的 kext/IntelBTPatcher.kext
#
# 该脚本只做四件事：挂载 → 备份 → 替换 → 校验并卸载
set -euo pipefail

EFI_DEV="${1:-disk0s1}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_KEXT="${2:-$REPO_DIR/kext/IntelBTPatcher.kext}"
MNT="/Volumes/EFI_BTFIX"
BACKUP="$HOME/Desktop/OC-backup-$(date +%Y%m%d-%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "!! 需要 root：sudo $0 $*"; exit 1; }
[ -d "$SRC_KEXT" ] || { echo "!! 找不到源 kext: $SRC_KEXT"; exit 1; }

echo "== 1. 挂载 $EFI_DEV"
mkdir -p "$MNT"
diskutil mount -mountPoint "$MNT" "$EFI_DEV" >/dev/null || true
[ -d "$MNT/EFI/OC/Kexts" ] || { echo "!! $MNT/EFI/OC/Kexts 不存在，中止（未做任何修改）"; diskutil unmount "$MNT" >/dev/null 2>&1 || true; exit 1; }

echo "== 2. 备份 OC 目录到 $BACKUP"
mkdir -p "$BACKUP"
cp -R "$MNT/EFI/OC" "$BACKUP/OC"
echo "   已备份 $(du -sh "$BACKUP/OC" | cut -f1)"

OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext/Contents/Info.plist" 2>/dev/null || echo MISSING)
OLD_VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext/Contents/Info.plist" 2>/dev/null || echo "?")
echo "   当前安装: $OLD_ID $OLD_VER"
[ "$OLD_ID" = "com.zxystd.IntelBTPatcher" ] || { echo "!! 标识不符，中止（备份已保留）"; diskutil unmount "$MNT" >/dev/null 2>&1 || true; exit 1; }

echo "== 3. 替换"
rm -rf "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext"
cp -R "$SRC_KEXT" "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext"
xattr -cr "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext" 2>/dev/null || true

echo "== 4. 校验"
plutil -p "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext/Contents/Info.plist" \
  | grep -E "CFBundleVersion|SupportedPlatforms|MinimumSystem"
shasum -a 256 "$MNT/EFI/OC/Kexts/IntelBTPatcher.kext/Contents/MacOS/IntelBTPatcher" \
             "$SRC_KEXT/Contents/MacOS/IntelBTPatcher"

echo "== 5. 卸载"
sync
diskutil unmount "$MNT" >/dev/null 2>&1 || true
cat <<EOF

完成。请重启，然后：
  kmutil showloaded | grep IntelBTPatcher     # 应显示 2.5.1
  # 键盘长按配对键 3 秒 → 系统设置点连接 → 屏幕出现 6 位码 → 键盘敲入 + Enter
  # 若第一次失败（smpPairingCompleted status=4805），再点一次连接

回滚：把 $BACKUP/OC/Kexts/IntelBTPatcher.kext 拷回 EFI 同路径即可。
EOF
