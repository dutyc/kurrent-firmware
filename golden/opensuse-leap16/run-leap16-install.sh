#!/bin/bash
# run-leap16-install.sh - openSUSE Leap 16.0 无人值守安装 VM（Agama + OVMF）
#
# 用法: bash golden/opensuse-leap16/run-leap16-install.sh [ISO]
# 默认 ISO: <repo>/.cache/isos/Leap-16.0-online-installer.iso
#
# Agama 自动安装：inst.auto=<profile>（JSON），inst.finish=poweroff。
# 目标盘为 4K 逻辑块 virtio-blk（XFS 扇区约束），脚本自动创建 10G 稀疏 raw。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=$ROOT/.cache
ISO=${1:-$CACHE/isos/Leap-16.0-online-installer.iso}
RAW=${RAW:-$CACHE/vm/leap16.raw}
VARS=$CACHE/vm/leap16-OVMF_VARS.fd
KDIR=$CACHE/vm/leap16-install
LOG=$CACHE/vm/leap16-install.serial
PROFILE_SRC=$ROOT/golden/opensuse-leap16/leap16-profile.json
KS_DIR=$CACHE/ks
PROFILE_RUN=$KS_DIR/leap16-profile.json
HTTP_PORT=${HTTP_PORT:-8000}
SSH_KEY=$CACHE/ssh/leap16

. "$ROOT/golden/shared/golden-install-vm.sh"

[ -f "$ISO" ] || { echo "ERROR: 缺少 ISO: $ISO" >&2; exit 1; }

mkdir -p "$CACHE/vm" "$KDIR" "$KS_DIR" "$CACHE/ssh"
install_vm_ssh_key "$SSH_KEY" golden-leap16
install_vm_extract_iso "$ISO" "$KDIR" \
    /boot/x86_64/loader/linux:linux \
    /boot/x86_64/loader/initrd:initrd

echo "==> 生成运行时 Agama profile（注入公钥）"
sed "s|__GOLDEN_SSH_PUBKEY__|$(cat "$SSH_KEY.pub")|" "$PROFILE_SRC" > "$PROFILE_RUN"

echo "==> 启动 profile HTTP 服务（:$HTTP_PORT，目录 $KS_DIR）"
install_vm_serve_http "$CACHE" "$KS_DIR" "$HTTP_PORT"
install_vm_prepare_target "$RAW" "$VARS"

rm -f "$LOG"
echo "==> 启动 Agama 安装 VM（串口日志 $LOG，完成后自动关机）"
timeout ${INSTALL_TIMEOUT:-3600} qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 3072 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$RAW",if=none,id=d0,format=raw,cache=unsafe \
    -device virtio-blk-pci,drive=d0,logical_block_size=4096,physical_block_size=4096 \
    -netdev user,id=n0,hostfwd=tcp::2226-:22 \
    -device virtio-net-pci,netdev=n0 \
    -cdrom "$ISO" \
    -kernel "$KDIR/linux" -initrd "$KDIR/initrd" \
    -append "console=ttyS0,115200 inst.auto=http://10.0.2.2:$HTTP_PORT/leap16-profile.json inst.finish=poweroff" \
    -serial file:"$LOG" -display none -monitor none

echo "==> 安装 VM 已退出；串口尾部："
tail -20 "$LOG"
