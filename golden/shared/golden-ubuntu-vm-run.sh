#!/bin/bash
# golden-ubuntu-vm-run.sh - 启动 Ubuntu 24.04 定制阶段 VM(OVMF UEFI + cloud-init seed + slirp + SSH 转发)
#
# 用法: bash golden-ubuntu-vm-run.sh <cloud-img(qcow2)> [seed-iso]
# 说明:
#   - cloud 镜像首启时 cloud-init 自动扩根分区到盘大小,并按 seed 设 dutyc/123456(sudo NOPASSWD)+ ssh_pwauth
#   - QMP: /tmp/ubuntu-qmp.sock;SSH: 宿主 127.0.0.1:2222 -> VM 22
set -e

IMG=${1:?用法: golden-ubuntu-vm-run.sh <cloud-img> [seed-iso]}
SEED=${2:-/windows-c/test/ubuntu-seed.iso}
VARS=/var/tmp/ubuntu-OVMF_VARS.fd
[ -f "$IMG" ] || { echo "ERROR: 缺少 $IMG"; exit 1; }
[ -f "$SEED" ] || { echo "ERROR: 缺少 $SEED"; exit 1; }
[ -f "$VARS" ] || { cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS" 2>/dev/null || cp /usr/share/OVMF/OVMF_VARS.fd "$VARS"; }

# 扩容到 20G(cloud-init 首启自动 growpart)
qemu-img resize "$IMG" 20G 2>/dev/null || true

rm -f /tmp/ubuntu-qmp.sock
exec qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive file="$IMG",if=virtio \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -cdrom "$SEED" \
  -display none \
  -qmp unix:/tmp/ubuntu-qmp.sock,server=on,wait=off \
  -monitor none
