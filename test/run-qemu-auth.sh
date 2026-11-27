#!/usr/bin/env bash
# Run one QEMU round of NVMe/TCP validation against the local nvmet target.
#
# Usage: bash test/run-qemu-auth.sh [round]     (default round: "auth")
#
# - serial log and pcap are written to diag/ as qemu-<round>.log and
#   netdump-<round>.log (diag/ is gitignored: runtime artifacts stay local)
# - the FAT drive diag/tmp/ must contain the test firmware at
#   EFI/BOOT/BOOTX64.EFI, e.g. built with
#   EMBED=test/nvmeof-auth-test.ipxe DEBUG=nvmetcp,nvmetcp_auth:3
# - note: QEMU+OVMF provides no SMBIOS UUID to iPXE, so the host NQN
#   falls back to "nqn.2014-08.org.ipxe:ipxe" (see test/nvmet-setup.sh)
# - run outside sandbox (requires /dev/kvm)
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/test/shared/qemu-lib.sh"

D=$DIAG
ROUND=${1:-auth}
LOG=$D/qemu-$ROUND.log
PCAP=$D/netdump-$ROUND.pcap
TMP=$D/tmp
VARS=$D/OVMF_VARS.fd

qemu_prepare "$TMP" "$VARS"
qemu_std_args "$VARS" 1024
qemu_fat_args "$TMP"
qemu_net_args 52:54:00:12:34:56 "$PCAP"

cd "$D"
exec timeout 150 qemu-system-x86_64 \
  "${QEMU_STD[@]}" \
  "${QEMU_FAT[@]}" \
  "${QEMU_NET[@]}" \
  -serial file:"$LOG" \
  -display none
