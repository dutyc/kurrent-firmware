#!/bin/bash
# golden-esp-verify.sh - 校验母盘 4K ESP 内容(512 逻辑扇区 + 分区偏移 loop,vfat 可正常解读)
# 用法: sudo bash golden-esp-verify.sh <raw-img> [内核版本]
# 说明: 内核 vfat 在"设备逻辑扇区 4096 的 loop"上解读 4K-BPB FAT 会得到空目录
#       (目录块号换算缺陷),必须用 512 逻辑扇区 + 字节偏移方式挂载验证。
set -euo pipefail

IMG=${1:?用法: golden-esp-verify.sh <raw-img> [内核版本]}
KVER=${2:-6.12.95+deb12-amd64}
MNT=/mnt/golden-vm
# p1 字节区间(4K GPT):offset 256*4096=1048576,size 512M=536870912
OFF=1048576
LIM=536870912

[ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行"; exit 1; }
VLOOP=""
trap 'umount "$MNT/efi" 2>/dev/null; [ -n "$VLOOP" ] && losetup -d "$VLOOP" 2>/dev/null; true' EXIT

VLOOP=$(losetup --find --show -o "$OFF" --sizelimit "$LIM" "$IMG")
sleep 1
mkdir -p "$MNT/efi"
mount -t vfat -o ro "$VLOOP" "$MNT/efi"

echo "=== ESP 文件清单 ==="
ls -la "$MNT/efi" "$MNT/efi/EFI/BOOT"
echo "=== grub.cfg ==="
cat "$MNT/efi/EFI/BOOT/grub.cfg"
echo "=== 校验完成 ==="
