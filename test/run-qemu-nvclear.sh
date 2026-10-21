#!/usr/bin/env bash
# nvclear acceptance: three QEMU/OVMF rounds on one OVMF_VARS.fd, with
# test/nvs-clear.ipxe embedded in the firmware.
#
#   round 1: store device-key / server-fingerprint / trust, read back
#   round 2: read back (round 1 persisted) -> nvclear -> read back (empty)
#   round 3: boots with none of the three present -> the clear reached
#            storage; a surviving setting would re-enter the clear branch
#
# Verdict: round 3 must show [PHASE1 SET] and must not show [PHASE2 BEFORE].
#
# Why this can fail: nvo_save() used to call nvs_write(..., 0) for a
# zero-length options block, and nvs_write() is a while(len) loop that
# performs no device write at all for a zero length -- so "delete the last
# option" saved nothing and the previous (non-empty) block stayed in the
# EFI variable, resurrecting those settings on the next boot.  Patch 0006
# makes nvo_save() issue a zero-length write in that case (which the EFI
# backend implements as a variable deletion).
#
# Output: diag/nvs-boot{1,2,3}.serial, diag/nvs-build.log
# Run outside the sandbox (requires /dev/kvm).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/diag
SRC=$ROOT/.cache/ipxe-upstream/src
ESP=$D/nvs-esp.img
VARS=$D/nvs-vars.fd

[ -d "$SRC" ] || { echo "ERROR: $SRC missing (run build/build.sh first)" >&2; exit 1; }
command -v mcopy >/dev/null && command -v mkfs.vfat >/dev/null || {
        echo "ERROR: mtools / dosfstools missing" >&2; exit 1
}

# Embed the test script (EMBED paths are relative to the iPXE source root)
cp "$ROOT/test/nvs-clear.ipxe" "$SRC/embed/nvs-clear.ipxe"
( cd "$SRC" && rm -f bin-x86_64-efi/ipxe.efi \
  && make bin-x86_64-efi/ipxe.efi EMBED=embed/nvs-clear.ipxe -j"$(nproc)" ) \
  >"$D/nvs-build.log" 2>&1

# FAT16 ESP, matching the other diag images
dd if=/dev/zero of="$ESP" bs=1M count=16 status=none
mkfs.vfat -F 16 -n NVSTEST "$ESP" >/dev/null
mmd -i "$ESP" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP" "$SRC/bin-x86_64-efi/ipxe.efi" ::/EFI/BOOT/BOOTX64.EFI

# Clean NVRAM, shared by all three rounds
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"

for n in 1 2 3; do
        timeout 45 qemu-system-x86_64 \
          -machine q35,accel=kvm -cpu host -m 2048 \
          -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
          -drive if=pflash,format=raw,file="$VARS" \
          -drive file="$ESP",format=raw,if=none,id=esp \
          -device ide-hd,drive=esp,bus=ide.0 \
          -serial file:"$D/nvs-boot$n.serial" \
          -boot order=c,menu=off -display none -monitor none 2>/dev/null || true
        echo "########## round $n ##########"
        sed -n '/NVS TEST BEGIN/,/NVS TEST END/p' "$D/nvs-boot$n.serial" | tr -d '\r'
done

echo
if grep -qa "PHASE2 BEFORE" "$D/nvs-boot3.serial"; then
        echo "FAIL: round 3 re-entered the clear branch -- a setting survived"
        exit 1
fi
grep -qa "PHASE1 SET" "$D/nvs-boot3.serial" || {
        echo "FAIL: round 3 log is not as expected"; exit 1
}
echo "PASS: all three settings were gone at the start of round 3"
