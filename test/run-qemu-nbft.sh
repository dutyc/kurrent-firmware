#!/usr/bin/env bash
# Run one QEMU round of the full NVMe/TCP SAN boot chain:
#   iPXE sanboot (NVMe/TCP) -> GRUB -> kernel -> initramfs NBFT consumer
#   (nbft_auto) -> nvme connect-all --nbft -> rootfs -> system boot
#
# The NBFT table is injected externally with -acpitable (the pre-iPXE
# phase; iPXE-side table generation is the follow-up implementation).
#
# Usage: bash test/run-qemu-nbft.sh [round]     (default round: "nbft")
#
# Prerequisites:
#   1. sudo bash test/nvmet-setup.sh          (target, AUTH=0)
#   2. bash test/make-debian-san-disk.sh      (2G SAN boot disk)
#   3. build the iPXE firmware and deploy it to the FAT drive:
#        make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#          EMBED=test/nvmeof-test.ipxe DEBUG=nvmetcp,tcp,efi_block:3
#        cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI
#   4. python3 test/gen-nbft-table.py         (diag/nbft-qemu.bin)
#
# Outputs: diag/qemu-<round>.log, diag/netdump-<round>.pcap
# Run outside sandbox (requires /dev/kvm).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/test/shared/qemu-lib.sh"

D=$DIAG
ROUND=${1:-nbft}
LOG=$D/qemu-$ROUND.log
PCAP=$D/netdump-$ROUND.pcap
TMP=$D/tmp
VARS=$D/OVMF_VARS.fd

# The MAC must match the HFI entry of the injected NBFT table
MAC=52:54:00:12:34:56

qemu_prepare "$TMP" "$VARS"
for f in "$D/nbft-qemu.bin" "$D/nvme-boot.img"; do
        [ -e "$f" ] || { echo "ERROR: $f missing (see header)" >&2; exit 1; }
done

# Serial backend: "file" records the console to $LOG (automation); set
# QEMU_SERIAL=unix to open diag/serial.sock for interactive debugging, e.g.
#   socat - UNIX-CONNECT:diag/serial.sock
SERIAL_ARGS=(-serial file:"$LOG")
if [ "$QEMU_SERIAL" = unix ]; then
	rm -f "$D/serial.sock"
	# NOTE: this QEMU (10.2) rejects -serial unix:..., use -chardev
	SERIAL_ARGS=(-chardev socket,id=charserial0,path="$D/serial.sock",server=on,wait=off -serial chardev:charserial0)
fi

qemu_std_args "$VARS" 1024
qemu_fat_args "$TMP"
qemu_net_args "$MAC" "$PCAP"

cd "$D"
exec timeout 300 qemu-system-x86_64 \
  "${QEMU_STD[@]}" \
  "${QEMU_FAT[@]}" \
  -acpitable file="$D/nbft-qemu.bin" \
  "${QEMU_NET[@]}" \
  "${SERIAL_ARGS[@]}" \
  -display none
