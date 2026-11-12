#!/usr/bin/env bash
# Run one QEMU round of the EFI-variable NVS backend verification:
#   round "setup":  embed script stores server-fingerprint / trust
#   round "verify": embed script reads them back (persistence check)
#
# The two rounds MUST share the same diag/OVMF_VARS.fd.  Delete that
# file before the "setup" round to start from a clean NVRAM.
#
# Usage: bash test/run-qemu-nvs.sh [setup|verify]   (default: verify)
#
# Prerequisites:
#   build the firmware with the matching EMBED and deploy it:
#     make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#       EMBED=test/nvs-setup.ipxe            # setup round
#     make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#       EMBED=test/nvs-verify.ipxe           # verify round
#     cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi \
#        diag/tmp/EFI/BOOT/BOOTX64.EFI
#
# Output: diag/qemu-nvs-<round>.log
# Run outside sandbox (requires /dev/kvm).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/diag
ROUND=${1:-verify}
LOG=$D/qemu-nvs-$ROUND.log
TMP=$D/tmp

[ "$ROUND" = setup ] || [ "$ROUND" = verify ] || {
        echo "usage: $0 [setup|verify]" >&2
        exit 1
}

mkdir -p "$TMP"
[ -e "$TMP/EFI/BOOT/BOOTX64.EFI" ] || {
        echo "ERROR: $TMP/EFI/BOOT/BOOTX64.EFI missing (see header)" >&2
        exit 1
}
if [ ! -e "$D/OVMF_VARS.fd" ]; then
        cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
fi
export TMPDIR=$D/tmpqemu
mkdir -p "$TMPDIR"
cd "$D"
exec timeout 120 qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 1024 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$D/OVMF_VARS.fd" \
  -drive file=fat:rw:"$TMP",format=raw,media=disk,cache=unsafe \
  -netdev user,id=net0 \
  -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
  -serial file:"$LOG" \
  -display none
