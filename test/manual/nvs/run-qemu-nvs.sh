#!/usr/bin/env bash
# Run one QEMU round of the EFI-variable NVS backend verification:
#   round "setup":  embed script stores server-fingerprint / trust
#   round "verify": embed script reads them back (persistence check)
#
# The two rounds MUST share the same diag/OVMF_VARS.fd.  Delete that
# file before the "setup" round to start from a clean NVRAM.
#
# Usage: bash test/manual/nvs/run-qemu-nvs.sh [setup|verify]   (default: verify)
#
# Prerequisites:
#   build the firmware with the matching EMBED and deploy it:
#     make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#       EMBED=test/manual/nvs/nvs-setup.ipxe            # setup round
#     make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#       EMBED=test/manual/nvs/nvs-verify.ipxe           # verify round
#     cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi \
#        diag/tmp/EFI/BOOT/BOOTX64.EFI
#
# Output: diag/qemu-nvs-<round>.log
# Run outside sandbox (requires /dev/kvm).
set -e

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
. "$ROOT/test/shared/qemu-lib.sh"

D=$DIAG
ROUND=${1:-verify}
LOG=$D/qemu-nvs-$ROUND.log
TMP=$D/tmp
VARS=$D/OVMF_VARS.fd

[ "$ROUND" = setup ] || [ "$ROUND" = verify ] || {
        echo "usage: $0 [setup|verify]" >&2
        exit 1
}

qemu_prepare "$TMP" "$VARS"
qemu_std_args "$VARS" 1024
qemu_fat_args "$TMP"
qemu_net_args 52:54:00:12:34:56

cd "$D"
exec timeout 120 qemu-system-x86_64 \
  "${QEMU_STD[@]}" \
  "${QEMU_FAT[@]}" \
  "${QEMU_NET[@]}" \
  -serial file:"$LOG" \
  -display none
