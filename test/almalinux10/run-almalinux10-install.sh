#!/bin/bash
# run-almalinux10-install.sh - AlmaLinux 10 无人值守安装 VM（kickstart + OVMF）
#
# 用法: bash test/almalinux10/run-almalinux10-install.sh [ISO]
# 默认 ISO: <repo>/.cache/isos/AlmaLinux-10.2-minimal.iso
#
# 前置: 4K 逻辑块 virtio-blk 目标盘（脚本自动创建 10G 稀疏 raw）。
# 安装完成后 VM 自动关机；串口日志与镜像都写在本仓 .cache/（gitignore）。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=$ROOT/.cache
ISO=${1:-$CACHE/isos/AlmaLinux-10.2-minimal.iso}
RAW=${RAW:-$CACHE/vm/alma10.raw}
VARS=$CACHE/vm/alma10-OVMF_VARS.fd
KDIR=$CACHE/vm/alma10-install
LOG=$CACHE/vm/alma10-install.serial
KS_SRC=$ROOT/test/almalinux10/almalinux10.ks.in
KS_DIR=$CACHE/ks
KS_RUN=$KS_DIR/alma10.ks
HTTP_PORT=${HTTP_PORT:-8000}
SSH_KEY=$CACHE/ssh/alma10

. "$ROOT/test/shared/golden-install-vm.sh"

[ -f "$ISO" ] || { echo "ERROR: 缺少 ISO: $ISO" >&2; exit 1; }

mkdir -p "$CACHE/vm" "$KDIR" "$KS_DIR" "$CACHE/ssh"
install_vm_ssh_key "$SSH_KEY" golden-alma10
install_vm_extract_iso "$ISO" "$KDIR" \
    /images/pxeboot/vmlinuz:vmlinuz \
    /images/pxeboot/initrd.img:initrd.img

echo "==> 生成运行时 kickstart（注入公钥）"
sed "s|__GOLDEN_SSH_PUBKEY__|$(cat "$SSH_KEY.pub")|" "$KS_SRC" > "$KS_RUN"

echo "==> 启动 kickstart HTTP 服务（:$HTTP_PORT，目录 $KS_DIR）"
install_vm_serve_http "$CACHE" "$KS_DIR" "$HTTP_PORT"
install_vm_prepare_target "$RAW" "$VARS"

rm -f "$LOG"
echo "==> 启动安装 VM（串口日志 $LOG，完成后自动关机）"
timeout ${INSTALL_TIMEOUT:-2400} qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 3072 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$RAW",if=none,id=d0,format=raw,cache=unsafe \
    -device virtio-blk-pci,drive=d0,logical_block_size=4096,physical_block_size=4096 \
    -netdev user,id=n0,hostfwd=tcp::2224-:22 \
    -device virtio-net-pci,netdev=n0 \
    -cdrom "$ISO" \
    -kernel "$KDIR/vmlinuz" -initrd "$KDIR/initrd.img" \
    -append "inst.ks=http://10.0.2.2:$HTTP_PORT/alma10.ks inst.text console=ttyS0,115200" \
    -serial file:"$LOG" -display none -monitor none

echo "==> 安装 VM 已退出；串口尾部："
tail -20 "$LOG"
