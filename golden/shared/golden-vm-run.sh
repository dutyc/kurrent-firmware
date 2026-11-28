#!/bin/bash
# golden-vm-run.sh - 启动母盘定制阶段 VM(OVMF UEFI + slirp + SSH 转发)
#
# 用法: bash golden-vm-run.sh <raw-img> [OVMF_VARS]
# 说明:
#   - 必须用 OVMF(UEFI)引导: UEFI 安装的盘无 MBR 引导代码,SeaBIOS 会卡死
#   - slirp user 网络 + hostfwd 2222->22: 宿主直连 VM 的 SSH(定制通道)
#   - QMP socket: /tmp/golden-qmp.sock(截图 golden-vm-sendkey.py 同源)
#   - 前台运行; 引导到 GDM/TTY 后即可进行母盘内定制
set -e

IMG=${1:?用法: golden-vm-run.sh <raw-img> [OVMF_VARS]}
VARS=${2:-/var/tmp/golden-OVMF_VARS.fd}
[ -f "$IMG" ] || { echo "ERROR: 缺少 $IMG"; exit 1; }
[ -f "$VARS" ] || { cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS" 2>/dev/null || cp /usr/share/OVMF/OVMF_VARS.fd "$VARS"; }

rm -f /tmp/golden-qmp.sock
exec qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive file="$IMG",format=raw,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -display none \
  -qmp unix:/tmp/golden-qmp.sock,server=on,wait=off \
  -monitor none
