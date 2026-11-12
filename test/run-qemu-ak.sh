#!/usr/bin/env bash
# Run one QEMU round of the TPM attestation self-test:
#   round 1: fresh swtpm state -> akgen creates the key, akpub and quote work
#   round 2: same swtpm state -> akgen reuses the key, ak-name is unchanged
#
# The two rounds MUST share diag/ak/swtpm and diag/OVMF_VARS-ak.fd.
# Round 1 deletes both first, so it must always run before round 2.
#
# Usage: bash test/run-qemu-ak.sh <1|2> [--no-tpm]
#
#   --no-tpm       run without a TPM device: akgen/akpub/quote must fail
#                  without crashing and the script must still finish.
#   --clean-nvram  regenerate the OVMF variable store from OVMF_VARS
#                  before booting (the swtpm state is kept), so that an
#                  unchanged AK proves TPM NV persistence.
#
# Prerequisites:
#   build the firmware with test/ak-test.ipxe embedded and deploy it:
#     make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#       EMBED=test/ak-test.ipxe
#     cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi \
#        diag/tmp/EFI/BOOT/BOOTX64.EFI
#
#   swtpm: set SWTPM to the swtpm binary and, if it is a user-level
#   unpack, SWTPM_LIBDIR to the library directory.
#
# Output: diag/ak/round<round>[-notpm].log  (serial console)
# Run outside the sandbox (requires /dev/kvm).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/diag
AKD=$D/ak
STATE=$AKD/swtpm
VARS=$D/OVMF_VARS-ak.fd
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
SWTPM=${SWTPM:-swtpm}
SWTPM_LIBDIR=${SWTPM_LIBDIR:-}
ESP=$D/tmp
ROUND= MODE=--tpm CLEAN_NVRAM=0

while [ $# -gt 0 ]; do
    case "$1" in
    1|2|3) ROUND=$1; shift ;;
    --no-tpm) MODE=--no-tpm; shift ;;
    --clean-nvram) CLEAN_NVRAM=1; shift ;;
    *) echo "usage: $0 <1|2|3> [--no-tpm] [--clean-nvram]" >&2; exit 1 ;;
    esac
done
[ -n "$ROUND" ] || { echo "usage: $0 <1|2|3> [--no-tpm] [--clean-nvram]" >&2; exit 1; }

if [ "$MODE" = --no-tpm ]; then
    LOG=$AKD/round$ROUND-notpm.log
else
    LOG=$AKD/round$ROUND.log
fi

mkdir -p "$AKD"
[ -e "$ESP/EFI/BOOT/BOOTX64.EFI" ] || {
    echo "ERROR: $ESP/EFI/BOOT/BOOTX64.EFI missing (see header)" >&2
    exit 1
}

# Round 1 always starts from clean TPM and NVRAM state
if [ "$ROUND" = 1 ]; then
    rm -rf "$STATE"
fi
if [ "$ROUND" = 1 ] || [ "$CLEAN_NVRAM" = 1 ]; then
    rm -f "$VARS"
fi
if [ ! -e "$VARS" ]; then
    cp "$OVMF_VARS" "$VARS"
fi

rm -f "$LOG"
TPM_ARGS=()
SWTPM_PID=
cleanup() {
    if [ -n "$SWTPM_PID" ]; then
        kill "$SWTPM_PID" 2>/dev/null || true
        wait "$SWTPM_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ "$MODE" = --tpm ]; then
    mkdir -p "$STATE"
    echo "==> starting swtpm in $STATE"
    if [ -n "$SWTPM_LIBDIR" ]; then
        LD_LIBRARY_PATH=$SWTPM_LIBDIR "$SWTPM" socket \
            --tpm2 --tpmstate "dir=$STATE" \
            --ctrl "type=unixio,path=$STATE/swtpm.sock" \
            --flags not-need-init,startup-clear \
            >>"$AKD/swtpm.log" 2>&1 &
    else
        "$SWTPM" socket \
            --tpm2 --tpmstate "dir=$STATE" \
            --ctrl "type=unixio,path=$STATE/swtpm.sock" \
            --flags not-need-init,startup-clear \
            >>"$AKD/swtpm.log" 2>&1 &
    fi
    SWTPM_PID=$!
    for _ in $(seq 50); do
        [ -S "$STATE/swtpm.sock" ] && break
        sleep 0.1
    done
    [ -S "$STATE/swtpm.sock" ] || {
        echo "ERROR: swtpm socket did not appear" >&2
        exit 1
    }
    TPM_ARGS=(
        -chardev "socket,id=chrtpm,path=$STATE/swtpm.sock"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-tis,tpmdev=tpm0"
    )
fi

echo "==> QEMU round $ROUND ($MODE), serial $LOG"
export TMPDIR=$D/tmpqemu
mkdir -p "$TMPDIR"
set +e
timeout 120 qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 1024 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$VARS" \
  "${TPM_ARGS[@]}" \
  -drive file=fat:rw:"$ESP",format=raw,media=disk,cache=unsafe \
  -netdev user,id=net0 \
  -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
  -serial file:"$LOG" \
  -display none
rc=$?
set -e

echo "==> QEMU exit status $rc"
sed -n '/AK-TEST-BEGIN/,/AK-TEST-DONE/p' "$LOG" | tr -d '\r'
